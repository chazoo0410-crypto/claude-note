"""
Transcribe a local video/audio file into plain text.

Tries Gemini (multimodal, understands video/audio directly via the File API)
first. If that fails (quota, billing, network, unsupported state, etc.),
falls back to OpenAI Whisper (whisper-1), which only accepts a fixed set of
audio-friendly formats and files up to 25MB.

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
  python transcribe.py --input clip.mp3 --language ja
"""

import argparse
import json
import mimetypes
import os
import sys
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to the source video/audio file")
    parser.add_argument("--out", help="Output text file path; if omitted, prints to stdout")
    parser.add_argument("--language", default="", help="Output/detection language hint, e.g. ja, en (optional)")
    parser.add_argument("--gemini-model", default="gemini-2.5-flash")
    parser.add_argument("--gemini-key-file", default=".secrets/gemini_api_key.txt")
    parser.add_argument("--openai-key-file", default=".secrets/openai_api_key.txt")
    parser.add_argument(
        "--no-header", action="store_true", help="Do not prepend a metadata comment header to --out"
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    mime = guess_mime(args.input)
    size = os.path.getsize(args.input)
    errors = []
    transcript = None
    provider_label = None

    gemini_key = read_key("GEMINI_API_KEY", args.gemini_key_file)
    if gemini_key:
        try:
            transcript = transcribe_with_gemini(args.input, mime, gemini_key, args.gemini_model, args.language)
            provider_label = f"gemini ({args.gemini_model})"
        except (URLError, HTTPError, RuntimeError, KeyError, IndexError, OSError, TimeoutError) as e:
            detail = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
            errors.append(f"gemini: {detail}")
    else:
        errors.append("gemini: no API key found")

    if transcript is None:
        openai_key = read_key("OPENAI_API_KEY", args.openai_key_file)
        ext = os.path.splitext(args.input)[1].lower()
        if not openai_key:
            errors.append("openai: no API key found")
        elif ext not in WHISPER_EXTS:
            errors.append(f"openai: unsupported extension for Whisper API: {ext}")
        elif size > WHISPER_MAX_BYTES:
            errors.append(f"openai: file too large for Whisper API (25MB limit, got {size} bytes)")
        else:
            try:
                transcript = transcribe_with_whisper(args.input, openai_key, args.language, mime)
                provider_label = "openai (whisper-1)"
            except (URLError, HTTPError, RuntimeError, KeyError, IndexError, OSError, TimeoutError) as e:
                detail = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
                errors.append(f"openai: {detail}")

    if transcript is None:
        print("error: transcription failed on all providers:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    if args.out:
        out_dir = os.path.dirname(args.out)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        content = transcript
        if not args.no_header:
            generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
            header = (
                "<!--\n"
                f"generated_at: {generated_at}\n"
                f"source: {args.input}\n"
                f"provider: {provider_label}\n"
                "-->\n\n"
            )
            content = header + transcript
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"saved ({provider_label}): {args.out} ({len(transcript)} chars)")
    else:
        print(f"# provider: {provider_label}\n")
        print(transcript)


if __name__ == "__main__":
    main()
