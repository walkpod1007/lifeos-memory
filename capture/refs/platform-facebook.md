# Step 2E：Facebook 專用流程（curl + Sec-Fetch headers）

FB 需要瀏覽器等級的 headers 才會回傳完整 HTML（否則回 Error 頁）。但拿到 HTML 後，全文和分享連結都在裡面。

**Step 2E-1：解析 share URL（如有 redirect）**

FB 短連結（`/share/p/xxx`）會 302 到完整 URL：

```bash
FULL_URL=$(curl -sI -L "$URL" 2>&1 | grep -i '^location:' | tail -1 | awk '{print $2}' | tr -d '\r')
[ -z "$FULL_URL" ] && FULL_URL="$URL"
```

**Step 2E-2：curl 抓頁面（必須帶完整 headers）**

```bash
curl -sL \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
  -H "Accept-Language: zh-TW,zh;q=0.9,en;q=0.8" \
  -H "Sec-Fetch-Dest: document" \
  -H "Sec-Fetch-Mode: navigate" \
  -H "Sec-Fetch-Site: none" \
  "$FULL_URL" -o /tmp/fb-capture.html
```

⚠️ 少了 `Sec-Fetch-*` headers 就只會拿到 1.5KB 的 Error 頁。這是 FB 跟 Threads 最大的差別。

**Step 2E-3：解析貼文全文**

全文在 HTML 的 `"text":"..."` 欄位（出現多次，內容相同，取最長的）：

```bash
python3 -c "
import re, json
with open('/tmp/fb-capture.html','r') as f: content=f.read()
matches = re.findall(r'\"text\":\"((?:[^\"\\\\\\\\]|\\\\\\\\.)*)\"', content)
longest = max((m for m in matches if len(m) > 100), key=len, default=None)
if longest:
    text = longest.encode('utf-8').decode('unicode_escape', errors='replace')
    print(text)
"
```

**Step 2E-4：解析分享連結（如貼文附帶外部連結）**

```bash
python3 -c "
import re, json
with open('/tmp/fb-capture.html','r') as f: content=f.read()
m = re.search(r'\"web_link\":\{[^}]*\"url\":\"([^\"]+)\"', content)
if m:
    url = m.group(1).replace(r'\/', '/')
    print(f'shared_url: {url}')
"
```

**Step 2E-5：解析作者與 OG metadata**

```bash
python3 -c "
import re, html as h
with open('/tmp/fb-capture.html','r') as f: content=f.read()
for tag in ['og:title','og:description','og:image']:
    m = re.search(r'property=\"' + tag + r'\" content=\"([^\"]+)\"', content)
    if m: print(f'{tag}: {h.unescape(m.group(1))}')
"
```

⚠️ FB 限制：
- `og:image` 可能不出現（附件/圖片走 GraphQL 動態載入）
- `attachments` 欄位通常是空陣列，PDF 等附件拿不到下載連結
- 文字全文 + 分享的外部連結可以拿到，圖片/附件拿不到
- 如果需要圖片，降級到 Browser Relay

**Step 2E-6：清除暫存**
```bash
rm -f /tmp/fb-capture.html
```

