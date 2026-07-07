#!/usr/bin/env python3
"""YouTube 上傳器（yt-relay-translate 用）：videos.insert + captions.insert。

沿用 yt-sub-translate 的 OAuth token（~/.config/yt-sub-translate/token.json，
scope youtube.force-ssl，已含 upload 權限）。

CLI:
  # 上傳影片＋掛字幕
  python3 yt_relay_upload.py upload \
      --video <mp4> --title-file <txt> --desc-file <txt> \
      --privacy unlisted|public|private \
      [--caption <srt> --caption-lang zh-Hant] \
      [--category 27] [--out <result.json>] [--uploaded-id-file <path>]

  # 事後轉 privacy（過目後轉公開）
  python3 yt_relay_upload.py --update-privacy <video_id> unlisted|public|private

退出碼:
  0 = 上傳成功（含字幕掛載成功，或未要求字幕）
  2 = 描述欄缺溯源行，拒絕上傳（未呼叫任何 API）
  3 = 影片上傳成功但字幕未掛載成功（completed_no_captions，呼叫端需另行處理）
  1 = 其他失敗（找不到檔案/憑證問題/上傳重試耗盡等）
"""
import argparse
import json
import os
import re
import sys
import time

os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")
os.environ.setdefault("OAUTHLIB_IGNORE_SCOPE_CHANGE", "1")

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

TOKEN = os.path.expanduser(os.environ.get("YT_RELAY_TOKEN", "~/.config/yt-sub-translate/token.json"))  # 多帳號：env 指定其他頻道 token
SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]

MAX_TITLE = 100
MAX_DESC = 5000
VALID_PRIVACY = ("unlisted", "public", "private")
PROVENANCE_MARKER = "原始影片："
# F6（溯源收緊）：舊版只驗「description 裡任意位置有沒有出現這串字」——任何人只要在
# 描述裡隨便塞一次「原始影片：」四個字（不接 URL、甚至塞在中間段落）就能繞過。
# 收緊成「第一行必須是 `原始影片：http(s)://...` 開頭」，relay.sh 產生的 description
# 本來就是這個格式（見 relay.sh step5_upload 的 desc_file 組裝），不影響正常流程。
PROVENANCE_RE = re.compile(r'^原始影片：https?://')


def _yt():
    if not os.path.exists(TOKEN):
        print(f"❌ 找不到 OAuth token: {TOKEN}（先跑 yt-sub-translate/scripts/yt_auth.py 授權）", file=sys.stderr)
        sys.exit(1)
    creds = Credentials.from_authorized_user_file(TOKEN, SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            print("❌ token 無效且無法自動刷新，請重新授權", file=sys.stderr)
            sys.exit(1)
    return build("youtube", "v3", credentials=creds)


def _read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def upload(args):
    if not os.path.exists(args.video):
        print(f"❌ 找不到影片檔: {args.video}", file=sys.stderr)
        sys.exit(1)
    if args.privacy not in VALID_PRIVACY:
        print(f"❌ --privacy 必須是 unlisted|public|private，收到: {args.privacy}", file=sys.stderr)
        sys.exit(1)

    # F9（helper 補鎖）：videos.insert 這條直接上傳路徑本身也要拒絕 privacy=public，
    # 不能只倚賴 relay.sh 的 CLI 層擋（那層擋得掉，但這支腳本也可能被其他呼叫端直接
    # 叫用，邊界要自己守）。轉公開走 --update-privacy 子命令，那是使用者過目後的正道，
    # 不受這條限制。
    if args.privacy == "public":
        print(
            "❌ videos.insert 不接受 privacy=public：初次上傳一律 unlisted/private 過目，"
            "要轉公開請於上傳完成後跑: python3 yt_relay_upload.py --update-privacy <video_id> public",
            file=sys.stderr,
        )
        sys.exit(2)

    title = _read_text(args.title_file).strip() if os.path.exists(args.title_file) else ""
    if not title:
        title = os.path.splitext(os.path.basename(args.video))[0]
    if len(title) > MAX_TITLE:
        print(f"⚠️ 標題 {len(title)} 字元超過 YouTube 上限 {MAX_TITLE}，自動截斷")
        title = title[:MAX_TITLE]

    description = _read_text(args.desc_file) if os.path.exists(args.desc_file) else ""
    if len(description) > MAX_DESC:
        print(f"⚠️ 描述 {len(description)} 字元超過 YouTube 上限 {MAX_DESC}，自動截斷")
        description = description[:MAX_DESC]

    # F6（CRITICAL 邊界，已收緊）：上傳前強制描述欄「第一行」必須是
    # `原始影片：http(s)://...` 開頭，不再只檢查字串是否「出現在描述某處」。
    # 不倚賴呼叫端（relay.sh）一定會生成正確描述——邊界自己也要守。
    first_line = description.splitlines()[0] if description.strip() else ""
    if not PROVENANCE_RE.match(first_line):
        print(
            f"❌ 描述欄第一行缺少合法溯源行（需為「{PROVENANCE_MARKER}http(s)://...」開頭，"
            f"實際第一行: {first_line!r}），拒絕上傳。 desc-file={args.desc_file}",
            file=sys.stderr,
        )
        sys.exit(2)

    yt = _yt()
    body = {
        "snippet": {
            "title": title,
            "description": description,
            "categoryId": str(args.category),
        },
        "status": {
            "privacyStatus": args.privacy,
            "selfDeclaredMadeForKids": False,
        },
    }
    media = MediaFileUpload(args.video, chunksize=-1, resumable=True, mimetype="video/mp4")
    request = yt.videos().insert(part="snippet,status", body=body, media_body=media)

    response = None
    retry = 0
    while response is None:
        try:
            _status, response = request.next_chunk()
        except Exception as e:
            retry += 1
            if retry > 5:
                print(f"❌ 上傳重試 5 次仍失敗: {e}", file=sys.stderr)
                sys.exit(1)
            wait = min(2 ** retry, 30)
            print(f"⚠️ 上傳中斷（{e}），{wait}s 後重試（第 {retry} 次）")
            time.sleep(wait)

    video_id = response["id"]
    print(f"✅ 影片上傳完成: id={video_id} privacy={args.privacy}")

    # F8（HIGH）：videos.insert 回應一落地立刻寫 uploaded_id 獨立檔案，
    # 先於任何後續步驟（含 captions.insert）——即使字幕段之後才失敗/程序被中斷，
    # 呼叫端也已經有 uploaded_id 可用於「轉公開」等後續動作，不會遺失。
    if args.uploaded_id_file:
        with open(args.uploaded_id_file, "w", encoding="utf-8") as f:
            f.write(video_id)

    caption_id = None
    caption_failed = False
    if args.caption:
        if not os.path.exists(args.caption):
            print(f"⚠️ 找不到字幕檔 {args.caption}，跳過 captions.insert", file=sys.stderr)
            caption_failed = True
        else:
            try:
                cap_body = {
                    "snippet": {
                        "videoId": video_id,
                        "language": args.caption_lang,
                        "name": "繁體中文",
                        "isDraft": False,
                    }
                }
                cap_media = MediaFileUpload(args.caption, mimetype="application/octet-stream", resumable=False)
                cap = yt.captions().insert(part="snippet", body=cap_body, media_body=cap_media).execute()
                caption_id = cap["id"]
                print(f"✅ 字幕掛載完成: track id={caption_id} lang={args.caption_lang}")
            except Exception as e:
                print(f"⚠️ captions.insert 失敗: {e}", file=sys.stderr)
                caption_failed = True

    result = {
        "video_id": video_id,
        "video_url": f"https://youtu.be/{video_id}",
        "privacy": args.privacy,
        "caption_id": caption_id,
        "caption_failed": caption_failed,
        "title": title,
    }
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
    print(json.dumps(result, ensure_ascii=False))

    # F7（HIGH）：字幕沒掛上不算「completed」——影片已上傳但字幕失敗/缺檔時，
    # 用專屬 exit code 3 回報，呼叫端（relay.sh）要落地成
    # status=completed_no_captions，不能標成一般 completed。
    if caption_failed:
        sys.exit(3)
    return result


def update_privacy(video_id, status):
    if status not in VALID_PRIVACY:
        print(f"❌ status 必須是 unlisted|public|private，收到: {status}", file=sys.stderr)
        sys.exit(1)
    yt = _yt()
    r = yt.videos().update(
        part="status",
        body={"id": video_id, "status": {"privacyStatus": status}},
    ).execute()
    print(f"✅ {video_id} 已轉為 {r['status']['privacyStatus']}")


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--update-privacy", nargs=2, metavar=("VIDEO_ID", "STATUS"))
    sub = parser.add_subparsers(dest="cmd")

    p_upload = sub.add_parser("upload")
    p_upload.add_argument("--video", required=True)
    p_upload.add_argument("--title-file", required=True)
    p_upload.add_argument("--desc-file", required=True)
    p_upload.add_argument("--privacy", default="unlisted")
    p_upload.add_argument("--caption", default="")
    p_upload.add_argument("--caption-lang", default="zh-Hant")
    p_upload.add_argument("--category", default="27")
    p_upload.add_argument("--out", default="")
    p_upload.add_argument("--uploaded-id-file", default="")

    args = parser.parse_args()

    if args.update_privacy:
        update_privacy(args.update_privacy[0], args.update_privacy[1])
        return

    if args.cmd == "upload":
        upload(args)
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
