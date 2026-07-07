#!/usr/bin/env python3
"""
upload_to_frame.py — Upload image to Samsung Frame TV art mode
Uses samsungtvws SamsungTVArt API over local network.

Usage:
    python3 upload_to_frame.py /path/to/poster-final.jpg

Requires SAMSUNG_TV_IP and SAMSUNG_TV_TOKEN in ~/.claude/.env
"""

import os
import sys
import subprocess
from pathlib import Path


def load_env():
    env_path = Path.home() / ".claude" / ".env"
    env = {}
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def main():
    if len(sys.argv) < 2:
        print("Usage: upload_to_frame.py <image_path>")
        sys.exit(1)

    image_path = sys.argv[1]
    if not Path(image_path).exists():
        print(f"Error: file not found: {image_path}")
        sys.exit(1)

    env = load_env()
    tv_ip = env.get("SAMSUNG_TV_IP")
    tv_token = env.get("SAMSUNG_TV_TOKEN")

    if not tv_ip:
        print("Error: SAMSUNG_TV_IP not set in ~/.claude/.env")
        sys.exit(1)

    import warnings
    warnings.filterwarnings("ignore")

    from samsungtvws.art import SamsungTVArt

    print(f"Connecting to Frame TV at {tv_ip}...")
    art_tv = SamsungTVArt(host=tv_ip, port=8002, token=tv_token or None)

    # Check if art mode is supported
    try:
        supported = art_tv.supported()
        print(f"Art mode supported: {supported}")
    except Exception as e:
        print(f"Warning: could not check art mode support: {e}")

    # Upload the image
    print(f"Uploading {image_path}...")
    with open(image_path, "rb") as f:
        image_data = f.read()

    try:
        file_type = "JPEG"
        result = art_tv.upload(image_data, file_type=file_type, matte="none")
        print(f"Upload result: {result}")

        # Set as current art
        if result:
            content_id = result if isinstance(result, str) else result.get("content_id", "")
            if content_id:
                art_tv.select_image(content_id, show=True)
                print(f"Set as current art: {content_id}")
            else:
                print("Upload done (content_id not returned, may need manual selection)")
        print("Done!")
    except Exception as e:
        print(f"Upload failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
