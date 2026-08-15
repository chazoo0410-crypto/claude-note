"""
Generate an article title illustration and save it as PNG.

Tries Gemini 2.5 Flash Image ("nanobanana") first. If that fails (quota,
billing, network, etc.), falls back to OpenAI gpt-image-1.

API keys are read from environment variables (GEMINI_API_KEY, OPENAI_API_KEY)
if set, otherwise from --gemini-key-file / --openai-key-file. The default
key file paths point at .secrets/, which is gitignored and local-only —
never commit real key values to the repository.

Usage:
  python generate_image.py --prompt "..." --out output/images/foo.png
"""

import argparse
import base64
import json
import os
import sys
import urllib.request
from urllib.error import HTTPError, URLError

GEMINI_ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    "gemini-2.5-flash-image:generateContent"
)
OPENAI_ENDPOINT = "https://api.openai.com/v1/images/generations"

# Fail fast instead of hanging a whole automated session when the network
# path to a provider is blocked (e.g. a sandboxed cloud environment's proxy).
GEMINI_TIMEOUT = 20
OPENAI_TIMEOUT = 30

# note.com's standard eyecatch/header image size.
DEFAULT_WIDTH = 1280
DEFAULT_HEIGHT = 670


def crop_to_size(image_bytes, target_width, target_height):
    try:
        from io import BytesIO

        from PIL import Image
    except ImportError:
        print(
            "warning: Pillow not installed, skipping resize/crop "
            f"(image will keep its original size, not {target_width}x{target_height})",
            file=sys.stderr,
        )
        return image_bytes

    img = Image.open(BytesIO(image_bytes)).convert("RGB")
    src_ratio = img.width / img.height
    target_ratio = target_width / target_height

    if src_ratio > target_ratio:
        scale = target_height / img.height
    else:
        scale = target_width / img.width
    scaled = img.resize(
        (max(1, round(img.width * scale)), max(1, round(img.height * scale))),
        Image.LANCZOS,
    )

    left = (scaled.width - target_width) // 2
    top = (scaled.height - target_height) // 2
    cropped = scaled.crop((left, top, left + target_width, top + target_height))

    out = BytesIO()
    cropped.save(out, format="PNG")
    return out.getvalue()


def read_key(env_name, key_file):
    key = os.environ.get(env_name)
    if key:
        return key
    if key_file and os.path.exists(key_file):
        with open(key_file, encoding="utf-8") as f:
            return f.read().strip()
    return None


def try_gemini(prompt, api_key):
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    req = urllib.request.Request(
        f"{GEMINI_ENDPOINT}?key={api_key}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=GEMINI_TIMEOUT) as resp:
        data = json.load(resp)
    parts = data["candidates"][0]["content"]["parts"]
    b64 = next((p["inlineData"]["data"] for p in parts if "inlineData" in p), None)
    if not b64:
        raise RuntimeError("Gemini response did not contain image data")
    return base64.b64decode(b64)


def try_openai(prompt, api_key):
    body = {"model": "gpt-image-1", "prompt": prompt, "size": "1536x1024", "n": 1}
    req = urllib.request.Request(
        OPENAI_ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=OPENAI_TIMEOUT) as resp:
        data = json.load(resp)
    b64 = data["data"][0]["b64_json"]
    return base64.b64decode(b64)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", required=True, help="Image prompt (English recommended)")
    parser.add_argument("--out", required=True, help="Output PNG path")
    parser.add_argument("--gemini-key-file", default=".secrets/gemini_api_key.txt")
    parser.add_argument("--openai-key-file", default=".secrets/openai_api_key.txt")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    args = parser.parse_args()

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    errors = []

    gemini_key = read_key("GEMINI_API_KEY", args.gemini_key_file)
    if gemini_key:
        try:
            image_bytes = try_gemini(args.prompt, gemini_key)
            image_bytes = crop_to_size(image_bytes, args.width, args.height)
            with open(args.out, "wb") as f:
                f.write(image_bytes)
            print(f"saved (gemini): {args.out} ({os.path.getsize(args.out)} bytes)")
            return
        except (URLError, HTTPError, RuntimeError, KeyError, IndexError, OSError) as e:
            detail = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
            errors.append(f"gemini: {detail}")
    else:
        errors.append("gemini: no API key found")

    openai_key = read_key("OPENAI_API_KEY", args.openai_key_file)
    if openai_key:
        try:
            image_bytes = try_openai(args.prompt, openai_key)
            image_bytes = crop_to_size(image_bytes, args.width, args.height)
            with open(args.out, "wb") as f:
                f.write(image_bytes)
            print(f"saved (openai fallback): {args.out} ({os.path.getsize(args.out)} bytes)")
            return
        except (URLError, HTTPError, RuntimeError, KeyError, IndexError, OSError) as e:
            detail = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
            errors.append(f"openai: {detail}")
    else:
        errors.append("openai: no API key found")

    print("error: image generation failed on all providers:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
