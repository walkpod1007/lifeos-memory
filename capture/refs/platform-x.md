# Step 2A：X/Twitter 四層降級

針對 X/Twitter 連結（twitter.com, x.com），依序嘗試：

**Step 2A-0：xurl read（優先路徑）**

從 URL 提取 post ID 並用 xurl CLI 抓取：

```bash
# t.co 縮網址先解析
RESOLVED=$(curl -sLo /dev/null -w '%{url_effective}' "$URL")

# 提取 post ID
POST_ID=$(echo "$RESOLVED" | grep -oP '(?<=status/)\d+')

# 用 xurl 抓取
xurl read $POST_ID --json
```

成功（exit 0 + 有 text）→ 映射到 OG metadata，跳到 Step 3。失敗 → 降級到 Step 2A-1。

映射規則：
| xurl 欄位 | 對應 OG 欄位 | 說明 |
|-----------|-------------|------|
| author.name | title | 推文作者顯示名稱 |
| text | description | 推文全文 |
| author.username | author | 加 `@` 前綴 |
| media[0].url | image | 第一張媒體圖片 |
| metrics | frontmatter 額外欄位 | likes / replies / retweets / quotes |

**Step 2A-1：curl OG tags**

```bash
curl -sL -A "Mozilla/5.0" "URL" | python3 -c "
import sys, re, html
content = sys.stdin.read()
result = {}
for tag in ['og:title', 'og:description', 'og:image', 'og:site_name']:
    m = re.search(rf'property=\"{tag}\"[^>]*content=\"([^\"]+)\"', content)
    if not m:
        m = re.search(rf'content=\"([^\"]+)\"[^>]*property=\"{tag}\"', content)
    result[tag] = html.unescape(m.group(1)) if m else None
import json; print(json.dumps(result, ensure_ascii=False))
"
```

**Step 2A-2：web_fetch 嘗試抓全文**

OG tags 也抓不到時，用 web_fetch 嘗試取得頁面內容。

**Step 2A-3：Browser Relay（最後手段）**

所有自動化手段皆失敗時，透過 Browser Relay 取得內容。
