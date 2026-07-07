#!/usr/bin/env python3
"""Translate YouTube video info fields (title, description, tags) via claude CLI."""
import json, sys, os, subprocess, re

LANG_NAMES = {
    "ko": "韓文（Korean）",
    "ja": "日文（Japanese）",
    "en": "英文（English）",
    "th": "泰文（Thai）",
    "zh-TW": "繁體中文（Traditional Chinese）",
}

CLAUDE_BIN = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

def translate_info(title: str, description: str, tags: list[str], target_lang: str) -> dict:
    lang_name = LANG_NAMES.get(target_lang, target_lang)
    prompt = (
        f"請將以下 YouTube 影片資訊翻譯為{lang_name}。\n"
        f"保留原意，description 保持段落結構，"
        f"tags 翻成對應語言常見搜尋關鍵字（每個 ≤ 30 字元）。\n"
        f"回傳 JSON，格式：{{\"title\": \"...\", \"description\": \"...\", \"tags\": [...]}}\n"
        f"只回傳 JSON，不加說明、不加 markdown。\n\n"
        f"title: {title}\n"
        f"description: {description}\n"
        f"tags: {json.dumps(tags, ensure_ascii=False)}"
    )
    result = subprocess.run(
        [CLAUDE_BIN, "-p", prompt, "--print", "--model", "claude-haiku-4-5-20251001"],
        capture_output=True, text=True, timeout=120
    )
    raw = result.stdout.strip()
    if raw.startswith("```"):
        raw = re.sub(r'^```[a-z]*\n?', '', raw)
        raw = re.sub(r'\n?```$', '', raw)
    return json.loads(raw)

def get_video_info(video_id: str) -> dict:
    """Fetch video title/description/tags via YouTube API."""
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build

    TOKEN_PATH = os.path.expanduser("~/.config/yt-sub-translate/token.json")
    creds = Credentials.from_authorized_user_file(TOKEN_PATH)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        with open(TOKEN_PATH, "w") as f:
            f.write(creds.to_json())

    yt = build("youtube", "v3", credentials=creds)
    resp = yt.videos().list(part="snippet", id=video_id).execute()
    if not resp.get("items"):
        raise ValueError(f"Video not found: {video_id}")
    snippet = resp["items"][0]["snippet"]
    return {
        "title": snippet.get("title", ""),
        "description": snippet.get("description", ""),
        "tags": snippet.get("tags", []),
    }

def update_video_localization(video_id: str, lang: str, title: str, description: str):
    """Upload translated title/description as YouTube localization."""
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build

    TOKEN_PATH = os.path.expanduser("~/.config/yt-sub-translate/token.json")
    creds = Credentials.from_authorized_user_file(TOKEN_PATH)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        with open(TOKEN_PATH, "w") as f:
            f.write(creds.to_json())

    yt = build("youtube", "v3", credentials=creds)
    resp = yt.videos().list(part="localizations,snippet", id=video_id).execute()
    item = resp["items"][0]
    locs = item.get("localizations", {})
    locs[lang] = {"title": title, "description": description}

    yt.videos().update(
        part="localizations",
        body={"id": video_id, "localizations": locs}
    ).execute()
    print(f"✅ 影片資訊更新：{lang}")

def main():
    if len(sys.argv) < 3:
        print("用法：translate_info.py <video_id_or_json> <lang1> [lang2] ...")
        print("  video_id: 從 YouTube 抓 title/description/tags（需授權）")
        print("  或傳 JSON 路徑：{\"title\": ..., \"description\": ..., \"tags\": [...]}")
        sys.exit(1)

    source = sys.argv[1]
    langs = sys.argv[2:]

    # 判斷是 video ID 還是 JSON 檔
    if os.path.exists(source):
        info = json.load(open(source, encoding="utf-8"))
    elif len(source) == 11:
        print(f"從 YouTube 抓取影片資訊：{source}")
        info = get_video_info(source)
    else:
        print("無法識別來源，請傳 video_id（11碼）或 JSON 檔路徑")
        sys.exit(1)

    print(f"原始標題：{info['title']}")
    results = {}

    for lang in langs:
        print(f"\n翻譯 → {lang}")
        translated = translate_info(
            info["title"], info["description"], info.get("tags", []), lang
        )
        results[lang] = translated
        print(f"  標題：{translated['title']}")

    # 輸出 JSON
    out_path = "/tmp/yt-sub-translate/info_translations.json"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n✅ 翻譯結果存到：{out_path}")

if __name__ == "__main__":
    main()
