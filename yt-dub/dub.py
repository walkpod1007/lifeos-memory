#!/usr/bin/env python3
"""SRT → edge-tts → ffmpeg adelay → .m4a, optional YouTube upload"""

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


def parse_srt(path):
    content = Path(path).read_text(encoding="utf-8-sig")
    blocks = re.split(r"\n\n+", content.strip())
    entries = []
    for block in blocks:
        lines = block.strip().splitlines()
        ts_line = None
        text_lines = []
        for i, line in enumerate(lines):
            if "-->" in line:
                ts_line = line
                text_lines = lines[i + 1 :]
                break
        if not ts_line:
            continue
        m = re.match(r"(\d+):(\d+):(\d+)[,.](\d+)", ts_line)
        if not m:
            continue
        h, mn, s, ms = int(m[1]), int(m[2]), int(m[3]), int(m[4])
        start_ms = (h * 3600 + mn * 60 + s) * 1000 + ms
        text = " ".join(text_lines).strip()
        if text:
            entries.append((start_ms, text))
    return entries


async def _gen_clip(text, voice, path):
    try:
        import edge_tts
        await edge_tts.Communicate(text, voice).save(path)
        return True
    except Exception as e:
        print(f"  WARN tts: {text[:30]!r} → {e}", file=sys.stderr)
        return False


async def generate_clips(entries, voice, tmp_dir, batch=20):
    clips = []
    total = len(entries)
    for start in range(0, total, batch):
        chunk = entries[start : start + batch]
        paths = [(start + i, ms, f"{tmp_dir}/clip_{start+i:04d}.mp3") for i, (ms, _) in enumerate(chunk)]
        tasks = [_gen_clip(text, voice, p) for (_, _, p), (_, text) in zip(paths, chunk)]
        results = await asyncio.gather(*tasks)
        for (idx, ms, p), ok in zip(paths, results):
            if ok and os.path.exists(p):
                clips.append((ms, p))
        print(f"  TTS {min(start+batch, total)}/{total}", file=sys.stderr)
    return clips


def assemble(clips, out_path):
    inputs, filters, labels = [], [], []
    for i, (ms, p) in enumerate(clips):
        inputs += ["-i", p]
        filters.append(f"[{i}]adelay={ms}|{ms}[d{i}]")
        labels.append(f"[d{i}]")
    n = len(clips)
    fc = ";".join(filters) + f";{''.join(labels)}amix=inputs={n}:duration=longest[out]"
    cmd = ["ffmpeg", "-y"] + inputs + ["-filter_complex", fc, "-map", "[out]", "-c:a", "aac", "-b:a", "128k", out_path]
    print(f"  ffmpeg {n} clips → {out_path}", file=sys.stderr)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    print(f"  {os.path.getsize(out_path)/1024/1024:.1f}MB", file=sys.stderr)


def upload(m4a, video_id, token_path, lang, lang_name):
    with open(token_path) as f:
        td = json.load(f)
    data = urllib.parse.urlencode({
        "client_id": td["client_id"], "client_secret": td["client_secret"],
        "refresh_token": td["refresh_token"], "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req) as r:
        access_token = json.loads(r.read())["access_token"]

    snippet = {"videoId": video_id, "language": lang, "name": lang_name,
               "isDraft": False, "trackKind": "standard", "audioTrackType": "dubbed"}
    body = json.dumps({"snippet": snippet}).encode()
    size = os.path.getsize(m4a)
    req = urllib.request.Request(
        "https://www.googleapis.com/upload/youtube/v3/captions?uploadType=resumable&part=snippet&sync=false",
        data=body, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Upload-Content-Type", "audio/mp4")
    req.add_header("X-Upload-Content-Length", str(size))
    with urllib.request.urlopen(req) as r:
        location = r.headers["Location"]

    with open(m4a, "rb") as f:
        payload = f.read()
    req = urllib.request.Request(location, data=payload, method="PUT")
    req.add_header("Content-Type", "audio/mp4")
    req.add_header("Content-Length", str(size))
    with urllib.request.urlopen(req) as r:
        result = json.loads(r.read())
    print(f"  Uploaded caption ID: {result.get('id')}", file=sys.stderr)
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--srt", required=True)
    p.add_argument("--voice", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--upload", action="store_true")
    p.add_argument("--video-id")
    p.add_argument("--token")
    p.add_argument("--lang")
    p.add_argument("--lang-name")
    args = p.parse_args()

    entries = parse_srt(args.srt)
    print(f"SRT: {len(entries)} entries", file=sys.stderr)

    with tempfile.TemporaryDirectory() as tmp:
        clips = asyncio.run(generate_clips(entries, args.voice, tmp))
        assemble(clips, args.out)

    if args.upload:
        if not all([args.video_id, args.token, args.lang, args.lang_name]):
            print("ERROR: --upload needs --video-id --token --lang --lang-name", file=sys.stderr)
            sys.exit(1)
        upload(args.out, args.video_id, args.token, args.lang, args.lang_name)

    print("Done.", file=sys.stderr)


if __name__ == "__main__":
    main()
