---
name: yt-sub-translate
description: >
  YouTube 字幕 + 影片資訊多語言翻譯。上傳 .srt/.vtt 字幕檔（或給 YouTube URL），
  翻成指定語言，自動產出各語言字幕檔，並可上傳回 YouTube 頻道。
  預設語言組合：韓文 (ko)、日文 (ja)、英文 (en)、泰文 (th)。
  觸發：YT 字幕翻譯、字幕翻成多國語言、yt-sub-translate、幫我翻字幕、翻成韓文日文英文泰文、
  翻 YouTube 字幕、subtitle translate、字幕上傳 YT、翻影片字幕。
  不觸發：下載字幕（用 yt-dlp 直接跑）、影片配音（用 yt-dub）、非字幕翻譯。
version: "1.0"
created: "2026-05-20"
---

# yt-sub-translate

YouTube 字幕與影片資訊的多語言翻譯 → 上傳 pipeline。

## 輸入形式

| 形式 | 說明 |
|------|------|
| 上傳字幕檔 | .srt / .vtt 直接丟進對話 |
| YouTube URL | 從頻道自動下載現有字幕（需 yt-dlp） |

## 標準輸出語言（可覆寫）

`ko`（韓文）、`ja`（日文）、`en`（英文）、`th`（泰文）

---

## 翻譯引擎鐵則（2026-07-03 使用者裁示）

**所有翻譯（字幕＋資訊欄、所有語言）一律派 sonnet 子代理直翻**（Agent tool, model: sonnet，工兵自己翻不呼叫外部 API/CLI）。原 `claude -p --model haiku` 批次管線（translate_all.py / translate_info.py）已退役：品質較差、且泰文穩定 120 秒超時。scripts/ 下的 python 只有 yt_auth.py 與 yt_upload.py（下載/上傳）仍在用。

## Pipeline

```
字幕來源（檔案 or yt-dlp）
  → 解析字幕格式（.srt / .vtt → 分段文字）
  → Claude API 批次翻譯（每語言獨立一輪）
  → 重新組裝為 .srt（保留時間戳）
  → [選] 翻譯影片資訊（title / description / tags）
  → [選] YouTube Data API v3 上傳字幕 + 更新影片資訊
```

---

## Step 0：前置準備

### 工具依賴

| 工具 | 用途 | 狀態 |
|------|------|------|
| `yt-dlp` | 下載 YT 字幕 | ✅ 已裝 |
| `googleapiclient` (Python) | YouTube Data API v3 上傳 | ✅ 已裝 |
| Claude API (`ANTHROPIC_API_KEY`) | 翻譯引擎 | ✅ 在 `~/.claude/.env` |

### YouTube API 授權（首次需要）

gws **不支援** YouTube API（gws 是 Google Workspace API）。  
YouTube Data API v3 需要單獨的 OAuth 2.0 user credentials。

**一次性設定：**
```bash
# 1. 確認 Cloud Console 已啟用 YouTube Data API v3
#    https://console.cloud.google.com/apis/library/youtube.googleapis.com
#    帳號：user@example.com

# 2. 下載 OAuth 2.0 client_secret.json（Desktop App 類型）
#    存放到：~/.config/yt-sub-translate/client_secret.json

# 3. 首次授權（會開瀏覽器）
python3 ~/life-os/skills/yt-sub-translate/scripts/yt_auth.py
# 授權後 token 存在 ~/.config/yt-sub-translate/token.json
# 之後自動 refresh，不需重複授權
```

---

## Step 1：取得字幕來源

### A：使用者上傳字幕檔
直接放到工作目錄：
```bash
WORK="/tmp/yt-sub-translate/<video-slug>"
mkdir -p "$WORK"
# 把使用者貼過來的 .srt 存到 $WORK/source.srt
```

### B：從 YouTube URL 下載
```bash
VIDEO_ID="影片ID或完整URL"
WORK="/tmp/yt-sub-translate/$VIDEO_ID"
mkdir -p "$WORK"

# 下載現有字幕（中文優先，沒有就抓自動字幕）
yt-dlp \
  --skip-download \
  --write-subs --write-auto-subs \
  --sub-lang "zh-TW,zh,zh-Hans" \
  --sub-format srt \
  -o "$WORK/source" \
  "$VIDEO_ID"

# 如果抓不到 zh-TW，降級用 zh 或 auto
ls "$WORK"/source*.srt 2>/dev/null || \
  yt-dlp --skip-download --write-auto-subs --sub-lang "zh" \
         --sub-format srt -o "$WORK/source" "$VIDEO_ID"
```

---

## Step 2：解析 .srt 字幕

```python
# scripts/parse_srt.py
import re, sys

def parse_srt(path):
    """回傳 [(index, timecode, text), ...]"""
    blocks = re.split(r'\n\n+', open(path).read().strip())
    result = []
    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:
            continue
        idx = lines[0].strip()
        tc  = lines[1].strip()
        txt = ' '.join(lines[2:]).strip()
        result.append((idx, tc, txt))
    return result

def write_srt(segments, path):
    with open(path, 'w') as f:
        for idx, tc, txt in segments:
            f.write(f"{idx}\n{tc}\n{txt}\n\n")

if __name__ == "__main__":
    segs = parse_srt(sys.argv[1])
    for s in segs:
        print(s)
```

---

## Step 3：翻譯字幕

```python
# （邏輯示意；實檔為 scripts/translate_all.py，CLI 用法：translate_all.py <source.srt> <lang1> [lang2] ...）
import anthropic, json, sys

LANG_NAMES = {
    "ko": "韓文（Korean）",
    "ja": "日文（Japanese）",
    "en": "英文（English）",
    "th": "泰文（Thai）",
    "zh-TW": "繁體中文（Traditional Chinese）",
}

def translate_batch(texts: list[str], target_lang: str) -> list[str]:
    client = anthropic.Anthropic()
    lang_name = LANG_NAMES.get(target_lang, target_lang)
    prompt = f"""以下是字幕文字清單（JSON 陣列）。
請將每一條翻譯為{lang_name}，保持簡潔（字幕限制），回傳相同長度的 JSON 陣列。
只回傳 JSON，不加說明。

{json.dumps(texts, ensure_ascii=False)}"""

    resp = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}]
    )
    return json.loads(resp.content[0].text)

def translate_srt(segments, target_lang):
    texts = [txt for _, _, txt in segments]
    # 批次送（每批 80 條，避免 token 過大）
    translated = []
    for i in range(0, len(texts), 80):
        batch = texts[i:i+80]
        translated.extend(translate_batch(batch, target_lang))
    return [(idx, tc, tr) for (idx, tc, _), tr in zip(segments, translated)]
```

---

## Step 4：翻譯影片資訊（title / description / tags）

```python
# scripts/translate_info.py
import anthropic, json

def translate_video_info(title: str, description: str, tags: list[str], target_lang: str) -> dict:
    client = anthropic.Anthropic()
    lang_name = {"ko": "韓文", "ja": "日文", "en": "英文", "th": "泰文"}.get(target_lang, target_lang)

    prompt = f"""請將以下 YouTube 影片資訊翻譯為{lang_name}。
保留原意，description 保持段落結構，tags 翻成對應語言常見搜尋關鍵字（每個 ≤ 30 字元）。
回傳 JSON，格式：{{"title": "...", "description": "...", "tags": [...]}}

title: {title}
description: {description}
tags: {json.dumps(tags, ensure_ascii=False)}"""

    resp = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=2048,
        messages=[{"role": "user", "content": prompt}]
    )
    return json.loads(resp.content[0].text)
```

---

## Step 5：上傳字幕回 YouTube

```python
# （邏輯示意；實檔函式為 _yt()/list_captions/upload_caption(video_id,lang,srt_path,name)/update_locale）
import json, os
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.http import MediaFileUpload

TOKEN_PATH = os.path.expanduser("~/.config/yt-sub-translate/token.json")

def get_youtube_client():
    creds = Credentials.from_authorized_user_file(TOKEN_PATH)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        with open(TOKEN_PATH, "w") as f:
            f.write(creds.to_json())
    return build("youtube", "v3", credentials=creds)

def upload_caption(video_id: str, lang: str, name: str, srt_path: str):
    yt = get_youtube_client()
    yt.captions().insert(
        part="snippet",
        body={
            "snippet": {
                "videoId": video_id,
                "language": lang,
                "name": name,
                "isDraft": False,
            }
        },
        media_body=MediaFileUpload(srt_path, mimetype="application/octet-stream")
    ).execute()
    print(f"✅ 字幕上傳完成：{lang}")

def update_video_localization(video_id: str, lang: str, title: str, description: str):
    yt = get_youtube_client()
    # 先取現有 localizations
    resp = yt.videos().list(part="localizations,snippet", id=video_id).execute()
    item = resp["items"][0]
    locs = item.get("localizations", {})
    locs[lang] = {"title": title, "description": description}

    yt.videos().update(
        part="localizations",
        body={"id": video_id, "localizations": locs}
    ).execute()
    print(f"✅ 影片資訊更新完成：{lang}")
```

---

## Step 6：一鍵執行腳本

```bash
# scripts/run.sh
#!/bin/bash
set -e

VIDEO_ID="${1:?需要 VIDEO_ID}"
LANGS="${2:-ko ja en th}"
WORK="/tmp/yt-sub-translate/$VIDEO_ID"

mkdir -p "$WORK"
cd "$WORK"

# 1. 下載字幕（或使用已有的 source.srt）
if [ ! -f source.srt ]; then
  yt-dlp --skip-download --write-subs --write-auto-subs \
         --sub-lang "zh-TW,zh" --sub-format srt \
         -o "source" "https://youtube.com/watch?v=$VIDEO_ID"
  # 找到的字幕改名為 source.srt
  find . -name "source.*.srt" | head -1 | xargs -I{} mv {} source.srt 2>/dev/null || true
fi

# 2. 翻譯 + 上傳各語言
for LANG in $LANGS; do
  echo "翻譯：$LANG"
  # 實際腳本是 translate_all.py（一次多語）：translate_all.py source.srt ko ja en th
  python3 ~/life-os/skills/yt-sub-translate/scripts/translate_all.py source.srt "$LANG"

  echo "上傳：$LANG"
  python3 ~/life-os/skills/yt-sub-translate/scripts/yt_upload.py \
    upload_caption "$VIDEO_ID" "$LANG" "${LANG}.srt"
done

echo "全部完成：$VIDEO_ID → $LANGS"
```

---

## 使用方式

### Case A：使用者上傳字幕檔

```bash
# 把上傳的檔案存成 /tmp/yt-sub-translate/<slug>/source.srt
# 執行翻譯（不上傳，只輸出）
python3 ~/life-os/skills/yt-sub-translate/scripts/translate_all.py \
  /path/to/source.srt ko ja en th
```

### Case B：從 YouTube URL 翻 + 上傳

```bash
bash ~/life-os/skills/yt-sub-translate/scripts/run.sh <VIDEO_ID> "ko ja en th"
```

### Case C：只翻影片資訊

```python
from scripts.translate_info import translate_video_info
for lang in ["ko", "ja", "en", "th"]:
    result = translate_video_info(title, description, tags, lang)
    print(lang, result)
```

---

## Gotchas

- gws **不支援** YouTube API，必須用 `googleapiclient` + 獨立 OAuth credentials
- YouTube Data API v3 需要 OAuth user credentials（不是 service account）——頻道的字幕/資訊修改需要頻道擁有者授權
- 字幕上傳需要頻道已開啟「社群貢獻」或是頻道所有者上傳
- Haiku 翻譯成本低（~$0.001/影片字幕），但泰文品質有時不穩，可改用 Sonnet
- `.srt` 時間戳格式：`00:00:01,000 --> 00:00:03,000`（逗號不是點）
- 一次批次 ≤ 80 條，避免 Haiku 4K token 輸出截斷
- 字幕檔大小：YT 限制單一字幕檔 ≤ 1MB
- 翻譯後 tags 需 ≤ 500 字元總長（YouTube 限制）
- 影片 localization 上傳後 24 小時內 YT 才會完全同步顯示

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
