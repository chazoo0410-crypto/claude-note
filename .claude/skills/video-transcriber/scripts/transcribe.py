"""
Transcribe a local video/audio file into plain text.

Tries Gemini (multimodal, understands video/audio directly via the File API)
first. If that fails (quota, billing, network, unsupported state, etc.),
falls back to OpenAI Whisper (whisper-1), which only accepts a fixed set of
audio-friendly formats and files up to 25MB.

Long recordings: if ffmpeg is installed and the media is longer than
--split-minutes (default 30), the audio track is extracted, downmixed to
16kHz mono and split into chunks, which are transcribed one by one and
joined back together. Extracting audio also shrinks the payload enough that
the 25MB Whisper fallback becomes usable for sources that were far too big
as video. Without ffmpeg the file is sent whole, exactly as before.

This is a verbatim transcription tool: it does not summarize, translate, or
explain the content. If a --language is given, it is used as a hint for the
output language (Gemini) / detection language (Whisper); otherwise the
content is transcribed in whatever language it is spoken in.

API keys are read from environment variables (GEMINI_API_KEY, OPENAI_API_KEY)
if set, otherwise from --gemini-key-file / --openai-key-file. The default
key file paths point at .secrets/, which is gitignored and local-only —
never commit real key values to the repository.

Usage:
  python transcribe.py --input video.mp4 --out output/transcripts/foo.md
  python transcribe.py --input long_meeting.mp4 --split-minutes 20
  python transcribe.py --input clip.mp3 --language ja
"""

import argparse
import glob
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime
from urllib.error import HTTPError, URLError
import urllib.request

GEMINI_UPLOAD_ENDPOINT = "https://generativelanguage.googleapis.com/upload/v1beta/files"
GEMINI_FILES_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta"
OPENAI_TRANSCRIBE_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"

# Fail fast instead of hanging a whole automated session when the network
# path to a provider is blocked (e.g. a sandboxed cloud environment's proxy).
SHORT_TIMEOUT = 30
UPLOAD_TIMEOUT = 300
GENERATE_TIMEOUT = 300
WHISPER_TIMEOUT = 120

FILE_ACTIVE_MAX_WAIT = 180
FILE_ACTIVE_POLL_INTERVAL = 3

# Formats OpenAI's whisper-1 API accepts directly (no local audio extraction).
WHISPER_EXTS = {".flac", ".m4a", ".mp3", ".mp4", ".mpeg", ".mpga", ".oga", ".ogg", ".wav", ".webm"}
WHISPER_MAX_BYTES = 25 * 1024 * 1024

# Speech-friendly audio encodings, smallest first. Every one of these works
# with ffmpeg's segment muxer and is accepted by both providers; the list is
# tried in order so a build without libmp3lame/libopus still lands on wav.
AUDIO_CANDIDATES = [
    ("mp3", ["-c:a", "libmp3lame", "-b:a", "32k"]),
    ("ogg", ["-c:a", "libopus", "-b:a", "24k"]),
    ("wav", ["-c:a", "pcm_s16le"]),
]

MIME_OVERRIDES = {
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".m4v": "video/x-m4v",
    ".avi": "video/x-msvideo",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
    ".mp3": "audio/mpeg",
    ".wav": "audio/wav",
    ".m4a": "audio/mp4",
    ".ogg": "audio/ogg",
    ".oga": "audio/ogg",
    ".flac": "audio/flac",
    ".aac": "audio/aac",
}

API_ERRORS = (URLError, HTTPError, RuntimeError, KeyError, IndexError, OSError, TimeoutError)


def guess_mime(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in MIME_OVERRIDES:
        return MIME_OVERRIDES[ext]
    mime, _ = mimetypes.guess_type(path)
    return mime or "application/octet-stream"


def read_key(env_name, key_file):
    key = os.environ.get(env_name)
    if key:
        return key
    if key_file and os.path.exists(key_file):
        with open(key_file, encoding="utf-8") as f:
            return f.read().strip()
    return None


def describe_error(e):
    return e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)


def format_timestamp(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"


def build_prompt(language):
    if language:
        return (
            f"この音声/動画の内容を、話されている通りに一字一句書き起こしてください。"
            f"出力言語は{language}にしてください。要約・意訳・説明を加えず、"
            "書き起こしのテキストのみを出力してください。読みやすい自然な段落・改行に整えてください。"
        )
    return (
        "この音声/動画の内容を、話されている言語のまま一字一句書き起こしてください。"
        "要約・翻訳・説明を加えず、書き起こしのテキストのみを出力してください。"
        "読みやすい自然な段落・改行に整えてください。"
    )


# --------------------------------------------------------------------------
# Optional ffmpeg-backed preprocessing
# --------------------------------------------------------------------------


def probe_duration_seconds(path):
    """Media duration in seconds, or None if it cannot be determined."""
    ffprobe = shutil.which("ffprobe")
    if ffprobe:
        cmd = [
            ffprobe,
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            path,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                return float(result.stdout.strip())
        except (OSError, subprocess.SubprocessError, ValueError):
            pass

    # Some installs ship ffmpeg without ffprobe; ffmpeg itself reports the
    # duration on stderr when asked to open a file with no output target.
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        result = subprocess.run([ffmpeg, "-i", path], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"Duration:\s*(\d+):(\d\d):(\d\d(?:\.\d+)?)", result.stderr)
    if not match:
        return None
    hours, minutes, seconds = match.groups()
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def run_ffmpeg(args, timeout):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)
    return result.returncode == 0, result.stderr.strip()


def extract_audio(path, out_dir, timeout):
    """Extract a single compressed speech-quality audio file. None on failure."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    for ext, codec_args in AUDIO_CANDIDATES:
        out_path = os.path.join(out_dir, f"audio.{ext}")
        args = [ffmpeg, "-v", "error", "-y", "-i", path, "-vn", "-ac", "1", "-ar", "16000"]
        args += codec_args + [out_path]
        ok, _ = run_ffmpeg(args, timeout)
        if ok and os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            return out_path
        if os.path.exists(out_path):
            os.remove(out_path)
    return None


def split_audio(path, out_dir, chunk_seconds, timeout):
    """Extract audio and cut it into chunk_seconds pieces. None on failure."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    for ext, codec_args in AUDIO_CANDIDATES:
        pattern = os.path.join(out_dir, f"part_%04d.{ext}")
        args = [ffmpeg, "-v", "error", "-y", "-i", path, "-vn", "-ac", "1", "-ar", "16000"]
        args += codec_args
        args += [
            "-f", "segment",
            "-segment_time", str(int(chunk_seconds)),
            "-reset_timestamps", "1",
            pattern,
        ]
        ok, _ = run_ffmpeg(args, timeout)
        parts = sorted(glob.glob(os.path.join(out_dir, f"part_*.{ext}")))
        if ok and parts:
            return parts
        for leftover in parts:
            os.remove(leftover)
    return None


# --------------------------------------------------------------------------
# Providers
# --------------------------------------------------------------------------


def gemini_upload(path, mime, api_key):
    size = os.path.getsize(path)
    display_name = os.path.basename(path)
    start_req = urllib.request.Request(
        f"{GEMINI_UPLOAD_ENDPOINT}?key={api_key}",
        data=json.dumps({"file": {"display_name": display_name}}).encode("utf-8"),
        method="POST",
        headers={
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(size),
            "X-Goog-Upload-Header-Content-Type": mime,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(start_req, timeout=SHORT_TIMEOUT) as resp:
        upload_url = resp.headers.get("x-goog-upload-url")
    if not upload_url:
        raise RuntimeError("no upload URL returned by Gemini File API")

    with open(path, "rb") as f:
        file_bytes = f.read()

    upload_req = urllib.request.Request(
        upload_url,
        data=file_bytes,
        method="POST",
        headers={
            "Content-Length": str(size),
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
        },
    )
    with urllib.request.urlopen(upload_req, timeout=UPLOAD_TIMEOUT) as resp:
        info = json.load(resp)
    return info["file"]


def gemini_wait_active(file_name, api_key):
    url = f"{GEMINI_FILES_ENDPOINT}/{file_name}?key={api_key}"
    waited = 0
    while waited < FILE_ACTIVE_MAX_WAIT:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=SHORT_TIMEOUT) as resp:
            data = json.load(resp)
        state = data.get("state")
        if state == "ACTIVE":
            return data
        if state == "FAILED":
            raise RuntimeError(f"Gemini file processing failed: {data}")
        time.sleep(FILE_ACTIVE_POLL_INTERVAL)
        waited += FILE_ACTIVE_POLL_INTERVAL
    raise RuntimeError("timed out waiting for Gemini file to become ACTIVE")


def gemini_generate_transcript(file_info, api_key, model, language):
    body = {
        "contents": [
            {
                "parts": [
                    {"file_data": {"mime_type": file_info["mimeType"], "file_uri": file_info["uri"]}},
                    {"text": build_prompt(language)},
                ]
            }
        ]
    }
    req = urllib.request.Request(
        f"{GEMINI_FILES_ENDPOINT}/models/{model}:generateContent?key={api_key}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=GENERATE_TIMEOUT) as resp:
        data = json.load(resp)
    parts = data["candidates"][0]["content"]["parts"]
    texts = [p["text"] for p in parts if "text" in p]
    if not texts:
        raise RuntimeError("Gemini response did not contain transcript text")
    return "\n".join(texts).strip()


def gemini_delete_file(file_name, api_key):
    try:
        req = urllib.request.Request(f"{GEMINI_FILES_ENDPOINT}/{file_name}?key={api_key}", method="DELETE")
        urllib.request.urlopen(req, timeout=15)
    except Exception:
        pass  # best-effort cleanup, never fails the transcription


def transcribe_with_gemini(path, mime, api_key, model, language):
    file_info = gemini_upload(path, mime, api_key)
    try:
        file_info = gemini_wait_active(file_info["name"], api_key)
        return gemini_generate_transcript(file_info, api_key, model, language)
    finally:
        gemini_delete_file(file_info["name"], api_key)


def build_multipart(fields, file_path, file_mime):
    boundary = "ClaudeNoteBoundary" + uuid.uuid4().hex
    chunks = []
    for name, value in fields.items():
        chunks.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8")
        )
    filename = os.path.basename(file_path)
    with open(file_path, "rb") as f:
        file_bytes = f.read()
    header = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {file_mime}\r\n\r\n"
    ).encode("utf-8")
    footer = f"\r\n--{boundary}--\r\n".encode("utf-8")
    body = b"".join(chunks) + header + file_bytes + footer
    return body, boundary


def transcribe_with_whisper(path, api_key, language, mime):
    fields = {"model": "whisper-1"}
    if language:
        fields["language"] = language
    body, boundary = build_multipart(fields, path, mime)
    req = urllib.request.Request(
        OPENAI_TRANSCRIBE_ENDPOINT,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    with urllib.request.urlopen(req, timeout=WHISPER_TIMEOUT) as resp:
        data = json.load(resp)
    text = data.get("text")
    if not text:
        raise RuntimeError("OpenAI response did not contain transcript text")
    return text.strip()


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


def transcribe_one(path, args, gemini_key, openai_key, tmp_dir, allow_audio_shrink):
    """Transcribe one file, Gemini first then Whisper.

    Returns (text, provider_label, errors); text is None when both failed.
    """
    errors = []
    mime = guess_mime(path)

    if gemini_key:
        try:
            text = transcribe_with_gemini(path, mime, gemini_key, args.gemini_model, args.language)
            return text, f"gemini ({args.gemini_model})", errors
        except API_ERRORS as e:
            errors.append(f"gemini: {describe_error(e)}")
    else:
        errors.append("gemini: no API key found")

    if not openai_key:
        errors.append("openai: no API key found")
        return None, None, errors

    ext = os.path.splitext(path)[1].lower()
    size = os.path.getsize(path)

    # A video that Whisper would reject outright — wrong container, or simply
    # too big — often fits comfortably once the audio track is pulled out.
    if allow_audio_shrink and (ext not in WHISPER_EXTS or size > WHISPER_MAX_BYTES):
        shrunk = extract_audio(path, tmp_dir, args.ffmpeg_timeout)
        if shrunk:
            path, ext, mime, size = shrunk, os.path.splitext(shrunk)[1].lower(), guess_mime(shrunk), os.path.getsize(shrunk)

    if ext not in WHISPER_EXTS:
        errors.append(f"openai: unsupported extension for Whisper API: {ext}")
    elif size > WHISPER_MAX_BYTES:
        errors.append(f"openai: file too large for Whisper API (25MB limit, got {size} bytes)")
    else:
        try:
            return transcribe_with_whisper(path, openai_key, args.language, mime), "openai (whisper-1)", errors
        except API_ERRORS as e:
            errors.append(f"openai: {describe_error(e)}")
    return None, None, errors


def transcribe_chunks(parts, chunk_seconds, args, gemini_key, openai_key, tmp_dir):
    """Transcribe each chunk in order. Returns (text, providers, failures)."""
    texts = []
    providers = []
    failures = []
    for index, part in enumerate(parts):
        offset = format_timestamp(index * chunk_seconds)
        text, label, errors = transcribe_one(
            part, args, gemini_key, openai_key, tmp_dir, allow_audio_shrink=False
        )
        if text is None:
            reason = "; ".join(errors)
            failures.append(f"chunk {index + 1}/{len(parts)} ({offset}): {reason}")
            texts.append(f"[!! {offset} からのチャンクの文字起こしに失敗しました: {reason} !!]")
            print(f"  chunk {index + 1}/{len(parts)} FAILED ({offset})", file=sys.stderr)
            continue
        providers.append(label)
        texts.append(text if args.no_chunk_markers else f"[{offset}]\n\n{text}")
        print(f"  chunk {index + 1}/{len(parts)} ok ({offset}, {label}, {len(text)} chars)", file=sys.stderr)
    return "\n\n".join(texts), providers, failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to the source video/audio file")
    parser.add_argument("--out", help="Output text file path; if omitted, prints to stdout")
    parser.add_argument("--language", default="", help="Output/detection language hint, e.g. ja, en (optional)")
    parser.add_argument("--gemini-model", default="gemini-2.5-flash")
    parser.add_argument("--gemini-key-file", default=".secrets/gemini_api_key.txt")
    parser.add_argument("--openai-key-file", default=".secrets/openai_api_key.txt")
    parser.add_argument(
        "--split-minutes",
        type=float,
        default=30,
        help="Split media longer than this into chunks (needs ffmpeg). 0 disables splitting.",
    )
    parser.add_argument(
        "--force-split",
        action="store_true",
        help="Split even when the duration cannot be probed (ffprobe missing)",
    )
    parser.add_argument(
        "--no-chunk-markers", action="store_true", help="Do not insert [HH:MM:SS] markers between chunks"
    )
    parser.add_argument(
        "--ffmpeg-timeout", type=int, default=1800, help="Timeout in seconds for each ffmpeg run"
    )
    parser.add_argument(
        "--no-header", action="store_true", help="Do not prepend a metadata comment header to --out"
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    gemini_key = read_key("GEMINI_API_KEY", args.gemini_key_file)
    openai_key = read_key("OPENAI_API_KEY", args.openai_key_file)

    duration = probe_duration_seconds(args.input)
    chunk_seconds = args.split_minutes * 60
    tmp_dir = tempfile.mkdtemp(prefix="transcribe_")

    try:
        parts = None
        if chunk_seconds > 0 and (
            (duration is not None and duration > chunk_seconds) or (duration is None and args.force_split)
        ):
            if not shutil.which("ffmpeg"):
                print(
                    "warning: media is longer than --split-minutes but ffmpeg was not found; "
                    "sending the whole file in one request instead",
                    file=sys.stderr,
                )
            else:
                length = format_timestamp(duration) if duration else "unknown"
                print(f"splitting audio ({length}) into {args.split_minutes:g}-minute chunks...", file=sys.stderr)
                parts = split_audio(args.input, tmp_dir, chunk_seconds, args.ffmpeg_timeout)
                if not parts:
                    print(
                        "warning: ffmpeg could not split the audio; sending the whole file instead",
                        file=sys.stderr,
                    )

        failures = []
        if parts:
            transcript, providers, failures = transcribe_chunks(
                parts, chunk_seconds, args, gemini_key, openai_key, tmp_dir
            )
            if not providers:
                print("error: transcription failed on every chunk:", file=sys.stderr)
                for failure in failures:
                    print(f"  - {failure}", file=sys.stderr)
                sys.exit(1)
            provider_label = ", ".join(sorted(set(providers)))
            chunk_note = f"{len(parts)} chunks x {args.split_minutes:g}min"
        else:
            transcript, provider_label, errors = transcribe_one(
                args.input, args, gemini_key, openai_key, tmp_dir, allow_audio_shrink=True
            )
            if transcript is None:
                print("error: transcription failed on all providers:", file=sys.stderr)
                for e in errors:
                    print(f"  - {e}", file=sys.stderr)
                sys.exit(1)
            chunk_note = None
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    if args.out:
        out_dir = os.path.dirname(args.out)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        content = transcript
        if not args.no_header:
            header_lines = [
                "<!--",
                f"generated_at: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
                f"source: {args.input}",
                f"provider: {provider_label}",
            ]
            if duration:
                header_lines.append(f"duration: {format_timestamp(duration)}")
            if chunk_note:
                header_lines.append(f"chunks: {chunk_note}")
            if failures:
                header_lines.append(f"partial: yes ({len(failures)} chunk(s) failed)")
            header_lines += ["-->", "", ""]
            content = "\n".join(header_lines) + transcript
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(content)
        state = "saved (partial)" if failures else "saved"
        print(f"{state} ({provider_label}): {args.out} ({len(transcript)} chars)")
    else:
        print(f"# provider: {provider_label}\n")
        print(transcript)

    if failures:
        print(f"warning: {len(failures)} chunk(s) failed and are marked inline:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
