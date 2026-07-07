# Step 2C：Instagram 專用流程（輪播圖片 OCR）

IG 的內容大量藏在輪播圖片裡（資訊圖表、長文截圖、教學卡片），caption（og:description）只是摘要。必須抓圖片做 OCR 才能拿到完整內容。

**暫存目錄**：`/tmp/link-capture/ig/`（用完即清）

**Step 2C-1：curl OG tags 拿 caption + 第一張圖**

```bash
mkdir -p /tmp/link-capture/ig
curl -sL -A "Mozilla/5.0" "$URL" | python3 -c "
import sys, re, html, json
content = sys.stdin.read()
result = {}
for tag in ['og:title', 'og:description', 'og:image']:
    m = re.search(r'property=\"' + tag + r'\"[^>]*content=\"([^\"]+)\"', content)
    if not m:
        m = re.search(r'content=\"([^\"]+)\"[^>]*property=\"' + tag + r'\"', content)
    result[tag] = html.unescape(m.group(1)) if m else None
print(json.dumps(result, ensure_ascii=False))
"
```

**Step 2C-2：取得所有輪播圖片（順序保留）**

唯一正式路徑：IG embed endpoint + Python regex 提取 display_url（實測可靠）。

⚠️ **踩坑紀錄（2026-03-22）**：原本的 regex `edge_sidecar_to_children\\":\\{.*?edge_web_media_to_related_media` 在實際 embed HTML 中打不到，因為 escape 層數不同。改用 Python regex 兩階段處理才穩定。

⚠️ **踩坑紀錄（2026-05-02）**：`grep -o 'display_url[^,]*'` 方案不穩定——embed HTML 中 display_url 值後面不一定是逗號，grep 切割點會變，導致 URL decode 後路徑截斷（`cdninstagram.com/v/` 被切掉）。正確方案改用 Python `re.finditer` 直接從完整 HTML 掃全部 display_url，替換規則 `.replace('\\\\\\/','/')` 才能正確還原 `https://` 路徑。

```bash
# Step 1：抓 embed HTML 並存檔
curl -sL "https://www.instagram.com/p/${POST_ID}/embed/" -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  -o /tmp/link-capture/ig/embed.html

# Step 2：Python regex 提取並解碼所有 display_url（已驗證可工作）
python3 - <<'PYEOF' > /tmp/link-capture/ig/urls.txt
import re

with open('/tmp/link-capture/ig/embed.html', 'r', encoding='utf-8') as f:
    content = f.read()

seen = set()
urls = []
for m in re.finditer(r'\\"display_url\\":\\"(https:.+?)(?=\\")', content):
    raw = m.group(1)
    url = raw.replace('\\\\\\/','/')
    if url not in seen and 'cdninstagram' in url:
        seen.add(url)
        urls.append(url)

for u in urls:
    print(u)
PYEOF

# Step 3：統計張數
SLIDE_COUNT=$(wc -l < /tmp/link-capture/ig/urls.txt)
echo "slides=$SLIDE_COUNT"
```

**硬性驗收（必回報）**
- 執行後必回報：`slides=<數量>`。
- `slides >= 2` 才算成功。
- `slides <= 1` 必須明確標記 `fallback`，不得宣稱已完整抓取。
- 禁止在 Instagram 路由提及或建議 Browser Relay。

### 低階模型防呆版（照抄執行）

1. 從 URL 抽 `POST_ID`（格式：`/p/{POST_ID}/`）。
2. `curl` 抓 `https://www.instagram.com/p/{POST_ID}/embed/` 存到 `/tmp/link-capture/ig/embed.html`。
3. 用 Python `re.finditer(r'\\"display_url\\":\\"(https:.+?)(?=\\")', content)` 從整份 HTML 掃全部 display_url。
4. 用 `.replace('\\\\\\/','/')` 還原路徑，過濾 `cdninstagram` 去重，輸出到 `/tmp/link-capture/ig/urls.txt`。
5. 逐張下載成 `slide-01.jpg`、`slide-02.jpg`……（不要跳號）。
6. 逐張 OCR，最後合併 `caption + 所有 slide 文字`。
7. 若最終張數 `<= 1`，輸出警告：`封面圖 fallback，內容可能不完整`。

**Step 2C-3：下載所有圖片到暫存目錄**

```bash
# urls.txt 輸出已在 Step 2 解碼，直接下載（加 Referer header 才能拿到圖）
mkdir -p /tmp/link-capture/ig

IDX=1
while read IMG_URL; do
  curl -sL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
    -H "Referer: https://www.instagram.com/" \
    "$IMG_URL" -o "/tmp/link-capture/ig/slide-$(printf '%02d' $IDX).jpg"
  IDX=$((IDX+1))
done < /tmp/link-capture/ig/urls.txt

echo "Downloaded $((IDX-1)) slides"
```

**Step 2C-4：OCR 每張圖片**

用 `image` 工具逐張分析，prompt：
> 「這是 Instagram 貼文的第 N 張圖片。提取圖片中所有文字內容，保持原始排版。如果是純照片無文字，描述圖片內容。」

**Step 2C-5：彙整**

將 caption（og:description）+ 每張圖片的 OCR 文字合併為完整原文，送到 Step 4 生成摘要。

**Step 2C-6：清除暫存**

```bash
rm -rf /tmp/link-capture/ig/
```

⚠️ 注意事項：
- OG tags 的圖片 URL 有時效性（CDN token 會過期），要即時下載不要存 URL
- 輪播圖片順序很重要（教學類貼文是有邏輯順序的），按 slide 編號排列
- Reel 類型（影片）→ caption 只是起點，**影片本體可透過 Step 2C-Video 路徑轉錄**（見下方）

---

## Step 2C-Video：IG Reel 影片音軌轉錄（2026-06-30 新增）

**前提**：本機需有 `ffmpeg` + `whisper`（`pip install openai-whisper`）。

**觸發時機**：caption 內容量不足，或使用者明確要求解析影片內容。

```bash
SHORTCODE="DZz6dEthzYW"  # 從 URL 取得
TMPDIR="/tmp/link-capture/ig"
mkdir -p "$TMPDIR"

# Step 1：抓 embed HTML
curl -sL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  "https://www.instagram.com/reel/${SHORTCODE}/embed/" \
  -o "$TMPDIR/embed.html"

# Step 2：提取並清理 video URL（關鍵：用 re.sub(r'\\+/', '/') 處理多層 backslash）
python3 - << 'PYEOF'
import sys, re

with open('/tmp/link-capture/ig/embed.html', 'rb') as f:
    content = f.read().decode('utf-8', errors='replace')

m = re.search(r'video_url\\":\\"(https.+?)(?=\\")', content)
if not m:
    print("NOT_FOUND", file=sys.stderr); sys.exit(1)

url_clean = re.sub(r'\\+/', '/', m.group(1))
with open('/tmp/link-capture/ig/video_url.txt', 'w') as f:
    f.write(url_clean)
print(url_clean[:80] + '...')
PYEOF

# Step 3：下載影片
VIDEO_URL=$(cat "$TMPDIR/video_url.txt")
curl -sL --max-time 60 -A "Mozilla/5.0" -o "$TMPDIR/reel.mp4" "$VIDEO_URL"

# Step 4：抽音軌
ffmpeg -i "$TMPDIR/reel.mp4" -ac 1 -ar 16000 "$TMPDIR/reel.wav" -y -loglevel error

# Step 5：Whisper 轉錄
whisper "$TMPDIR/reel.wav" --model tiny --language zh --output_format txt --output_dir "$TMPDIR"
cat "$TMPDIR/reel.txt"
```

**已知限制**：
- `whisper tiny` 對台語/口語混雜有誤字，建議用 `base` model（約 15-20 分鐘）
- IG CDN token 有效期短，embed HTML 要即抓即用
- 某些 Reel 的 embed 頁不含 `video_url`（受帳號隱私設定影響），此時退回 caption only

**實測驗證（2026-06-30）**：@wearekobros 鼎泰豐 Reel、@cn__ie 蛤蠣湯 Reel 均成功提取。

---

## Step 2C-Frame：IG Reel 截幀 OCR（字卡型影片，2026-06-30 新增）

**適用時機**：影片主要資訊在**畫面文字字卡**（清單、步驟、數字標注），而非口述。
典型特徵：出現「1. XXX」「2. XXX」編號字卡，或資訊圖表式 Reel。

**與音軌路徑的選擇**：
| 情境 | 路徑 |
|------|------|
| 資訊在字卡（清單/編號/標題） | Step 2C-Frame（截圖 OCR） |
| 資訊在口述（教學/說明/數字） | Step 2C-Video（Whisper 音軌） |
| 兩者都有 | 兩條都跑，合併結果 |

```bash
SHORTCODE="DZz6dEthzYW"  # 從 URL 取得
TMPDIR="/tmp/link-capture/ig"
mkdir -p "$TMPDIR/frames"

# Step 1-3：同 Step 2C-Video（抓 embed HTML → 提取 video URL → 下載 MP4）

# Step 4：截幀（2 秒一幀 = 0.5fps，標準設定）
ffmpeg -i "$TMPDIR/reel.mp4" \
  -vf "fps=0.5,scale=720:-1" \
  "$TMPDIR/frames/frame_%03d.jpg" \
  -loglevel error

FRAME_COUNT=$(ls "$TMPDIR/frames/frame_"*.jpg 2>/dev/null | wc -l)
echo "截幀完成：${FRAME_COUNT} 張"

# Step 5：Claude vision OCR（逐批讀取，用 Read tool）
# 建議策略：先跳採樣（每 5 張讀一張）定位字卡段，再密集讀該段
# 例：先讀 frame_001、006、011、016、021、026、031、036
# 找到字卡出現的時間段後，針對那段每張都讀
```

**截幀策略（節省 token）**：
1. **跳採樣定位**：先每 5 幀讀一張，找到字卡出現的時間段
2. **密集讀目標段**：字卡段每張都讀，其他段略過
3. **全讀（保守）**：影片 ≤ 2 分鐘（≤ 60 幀）時可直接全讀

**實測驗證（2026-06-30）**：@wearekobros 鼎泰豐 Reel（78秒/39幀），成功 OCR 出 5 道冷門必吃清單字卡，準確度 100%（音軌轉錄完全不可靠，字卡是唯一可信來源）。

---

## Step 2C-Thumb：Reel 縮圖限定 fallback（登入牆時只需一張圖，2026-07-06 新增）

**適用時機**：不需要影片本體或 caption，只需要**一張代表縮圖**（例如食譜卡配圖、Vault 附件），但 `/embed/captioned/` 回登入牆空殼、`video_url`／`display_url` 都抓不到。

```bash
SHORTCODE="DZJkjvMviOb"  # 從 URL 取得，即使原始網址是 /reel/{shortcode}/ 也代入下面的 /p/ 端點
TMPDIR="/tmp/link-capture/ig"
mkdir -p "$TMPDIR"
curl -sL --max-time 30 -A "Mozilla/5.0" \
  "https://www.instagram.com/p/${SHORTCODE}/media/?size=l" \
  -o "$TMPDIR/thumb.jpg"
```

- 不需要登入態、不需要 cookie，直接回 200 JPEG。
- `size=l` 為大圖；也可用 `size=m`／`size=t` 取得中／縮圖尺寸。
- **限制**：只能拿到縮圖，拿不到影片本體、caption、留言。要抓完整影片或文字仍照本檔 Step 2C-Video、或 `refs/platform-threads.md` Step 2D-7（Threads 同類登入牆情境）的流程判斷，這支端點不能取代那些。
- 快取的 `og_image`／`display_url` CDN 網址有簽章時效，過期會 403；遇到 403 時先用這支端點重新現抓，不要沿用 frontmatter 裡的舊網址。

**實測驗證（2026-07-06）**：line-recipe 專案批次補圖時，對 25 則既有 IG Reel raw/ 卡片重新抓縮圖，包含一則先前記錄為完全登入牆擋死（見 GOTCHAS.md G11，miamirecipes 絞肉包麵條 Reel）的貼文，此端點同樣成功取到縮圖。

---

## Step 2C-Alt：Playwright 輪播（優先於 embed 方案）

**何時用**：embed 方案只能拿到第一張全尺寸圖，後續 slides 只有 240px 縮圖（`HoverCardPhotos`）；需要完整輪播圖片時改用此方案。

**關鍵發現（2026-06-28）**：Instagram 頁面載入後會彈出登入 popup，**只要 popup 在，Next 按鈕就不會 render**。必須先關掉 popup，輪播才能正常操作。

```python
import asyncio, os, re, subprocess
from playwright.async_api import async_playwright
import browser_cookie3

async def capture_carousel(post_url, out_dir):
    jar = browser_cookie3.safari(domain_name='.instagram.com')
    cookies = [{'name': c.name, 'value': c.value,
                'domain': c.domain or '.instagram.com', 'path': c.path or '/'}
               for c in jar]

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(
            user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            viewport={'width': 1280, 'height': 900}
        )
        if cookies:
            await context.add_cookies(cookies)

        seen_ids = {}
        def handle_response(response):
            url = response.url
            if 't51.82787-15' in url and '.jpg' in url:
                m = re.search(r'/(\d+_\d+_\d+)_n\.jpg', url)
                if m:
                    mid = m.group(1)
                    if mid not in seen_ids or len(url) > len(seen_ids.get(mid, '')):
                        seen_ids[mid] = url

        page = await context.new_page()
        page.on('response', handle_response)

        await page.goto(post_url, wait_until='domcontentloaded', timeout=25000)
        await page.wait_for_timeout(3000)

        # ⚠️ 必須先關 login popup，否則 Next 按鈕不會出現
        await page.keyboard.press('Escape')
        await page.wait_for_timeout(1000)
        for selector in ['[aria-label="Close"]', 'button[aria-label="關閉"]', 'button._a9--']:
            btn = await page.query_selector(selector)
            if btn:
                await btn.click()
                await page.wait_for_timeout(1000)
                break

        # 點 Next 走完輪播
        for i in range(20):
            for next_sel in ['button[aria-label="Next"]', 'button[aria-label="下一張"]']:
                next_btn = await page.query_selector(next_sel)
                if next_btn:
                    await next_btn.click()
                    await page.wait_for_timeout(1500)
                    break
            else:
                break  # 沒有 Next 按鈕代表到底了

        # 下載所有攔截到的圖片
        os.makedirs(out_dir, exist_ok=True)
        for idx, (mid, url) in enumerate(seen_ids.items()):
            outfile = f'{out_dir}/slide-{idx+1:02d}.jpg'
            subprocess.run(['curl', '-s', '-L', '-A', 'Mozilla/5.0', url, '-o', outfile],
                           capture_output=True)

        await browser.close()
        return list(seen_ids.values())

asyncio.run(capture_carousel('https://www.instagram.com/p/POST_ID/', '/tmp/ig-slides'))
```

**驗收門檻**：
- `slides >= 2` 才算成功
- 圖片 size > 50KB 才算全尺寸（< 50KB 是縮圖或無關預載圖）
- Instagram 可能預載其他貼文的圖片混入結果，按 size 過濾後選大圖

**注意**：Safari cookie 只有 5 個 IG cookies，不含 `sessionid`，等同未登入。但關掉 popup 後不需要登入也能瀏覽輪播。

---

## Changelog
- 2026-03-22 v1: 棄用 regex `edge_sidecar_to_children\\":\\{.*?`，改用 `grep -o 'display_url[^,]*'` + Python 解碼。原因：三模型（Flash、MiniMax、Sonnet）都打不到，escape 層數不同。
- 2026-03-22 v1: embed HTML 先存檔再處理，方便 debug。
- 2026-03-22 v1: 強制回報 `slides=<數量>`，驗收門檻 `>= 2`，避免宣稱成功但只抓到封面圖。
- 2026-03-22 v2: 修正 URL 解碼錯誤。原寫法 `.replace("\\/", "/")` 少一層，實際 raw bytes 是 `\\/`，須用 `.replace("\\\\/", "/")` 才能正確還原成 `https://`。下載指令移除多餘的 `sed` 中轉步驟，改為 Step 2 直接輸出乾淨 URL。補上 `-H "Referer: https://www.instagram.com/"` header，缺少時 CDN 回 0 bytes。
- 2026-05-02 v3: 棄用 `grep -o 'display_url[^,]*'` 方案。根本問題：embed HTML 中 display_url 後面的分隔符不是固定逗號，grep 截斷點不穩，導致 URL 被截掉域名後段（`cdninstagram.com/v/` 遺失）。改用 Python `re.finditer(r'\\"display_url\\":\\"(https:.+?)(?=\\")', content)` 從整份 HTML 掃描，搭配 `.replace('\\\\\\/','/')` 還原路徑（這才是正確的 Python 層面 replace 寫法），過濾 `cdninstagram` 去重輸出。實測 6 張 slides 全數正確提取。
