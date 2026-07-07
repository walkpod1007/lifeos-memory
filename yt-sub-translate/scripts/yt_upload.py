#!/usr/bin/env python3
"""Upload a translated .srt as a YouTube caption track (or update video meta localizations).

Uses the OAuth token from yt_auth.py (~/.config/yt-sub-translate/token.json,
scope youtube.force-ssl).

CLI:
  # 上傳一條字幕軌
  python3 yt_upload.py upload_caption <video_id> <lang> <srt_path> [name]

  # 列出影片現有字幕軌
  python3 yt_upload.py list_captions <video_id>

  # 更新某語言的標題/描述在地化（保留其他語言）
  python3 yt_upload.py update_locale <video_id> <lang> <title_file> <desc_file>
"""
import os, sys, json

os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")
os.environ.setdefault("OAUTHLIB_IGNORE_SCOPE_CHANGE", "1")
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

TOKEN = os.path.expanduser("~/.config/yt-sub-translate/token.json")
SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]


def _yt():
    creds = Credentials.from_authorized_user_file(TOKEN, SCOPES)
    if not creds.valid and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return build("youtube", "v3", credentials=creds)


def list_captions(video_id):
    yt = _yt()
    items = yt.captions().list(part="snippet", videoId=video_id).execute()["items"]
    for c in items:
        s = c["snippet"]
        print(f"  [{s['language']}] name='{s.get('name','')}' kind={s.get('trackKind')} status={s.get('status')} id={c['id']}")
    return items


def upload_caption(video_id, lang, srt_path, name=""):
    yt = _yt()
    existing = {c["snippet"]["language"] for c in yt.captions().list(part="snippet", videoId=video_id).execute()["items"]}
    if lang in existing:
        print(f"  {lang}: 已存在字幕軌，跳過（如需取代請先 delete）")
        return None
    body = {"snippet": {"videoId": video_id, "language": lang, "name": name, "isDraft": False}}
    media = MediaFileUpload(srt_path, mimetype="application/octet-stream", resumable=False)
    r = yt.captions().insert(part="snippet", body=body, media_body=media).execute()
    print(f"  ✅ {lang}: track id={r['id']} status={r['snippet'].get('status')}")
    return r


def update_locale(video_id, lang, title_file, desc_file):
    """更新單一語言的 title/description 在地化，保留其餘語言。
    YouTube 標題上限 100 字元、描述上限 5000 字元——超過會被 API 拒。"""
    yt = _yt()
    it = yt.videos().list(part="snippet,localizations", id=video_id).execute()["items"][0]
    loc = dict(it.get("localizations", {}))
    title = open(title_file, encoding="utf-8").read().strip()
    desc = open(desc_file, encoding="utf-8").read()
    if len(title) > 100:
        raise ValueError(f"標題 {len(title)} 字元超過 100 上限，請先收短")
    loc[lang] = {"title": title, "description": desc}
    r = yt.videos().update(part="localizations", body={"id": video_id, "localizations": loc}).execute()
    print(f"  ✅ {lang} 在地化已更新。現有語言: {sorted(r.get('localizations', {}).keys())}")
    return r


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "list_captions":
        list_captions(sys.argv[2])
    elif cmd == "upload_caption":
        upload_caption(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else "")
    elif cmd == "update_locale":
        update_locale(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        print(f"未知指令: {cmd}")
        sys.exit(1)
