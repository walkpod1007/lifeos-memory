# Step 2F：PTT 專用流程（curl 直抓，最穩定）

PTT 是所有平台中結構最乾淨的——純 HTML，沒有 JS render，沒有 Cloudflare。

**Step 2F-1：curl 抓頁面**

```bash
curl -sL "https://www.ptt.cc/bbs/{board}/{article}.html" \
  -H "Cookie: over18=1" \
  -H "User-Agent: Mozilla/5.0" \
  -o /tmp/ptt-capture.html
```

⚠️ `Cookie: over18=1` 必須帶，否則八卦板等 18+ 看板會被擋。

**Step 2F-2：解析全部欄位**

```bash
python3 -c "
import re, html as h
with open('/tmp/ptt-capture.html','r') as f: content=f.read()

# Metadata (author, board, title, date)
meta = re.findall(r'<span class=\"article-meta-value\">([^<]+)</span>', content)
if len(meta) >= 4:
    print(f'AUTHOR: {meta[0]}')
    print(f'BOARD: {meta[1]}')
    print(f'TITLE: {meta[2]}')
    print(f'DATE: {meta[3]}')

# Main content: between metaline and signature
m = re.search(r'<div id=\"main-content\"[^>]*>(.*?)(?:<span class=\"f2\">※|--\n)', content, re.DOTALL)
if m:
    text = re.sub(r'<[^>]+>', '', m.group(1))
    text = h.unescape(text).strip()
    # Skip metaline header rows (first ~8 lines)
    lines = text.split('\n')
    body_start = 0
    for i, line in enumerate(lines):
        if line.strip() == '' and i > 3:
            body_start = i
            break
    body = '\n'.join(lines[body_start:]).strip()
    print(f'BODY: {body}')

# Push comments (推/噓/→)
pushes = re.findall(r'<div class=\"push\"><span class=\"([^\"]+)\">([^<]*)</span><span class=\"[^\"]+\">([^<]*)</span><span class=\"[^\"]+\">([^<]*)</span>', content)
for push_class, tag, userid_content, ipdatetime in pushes:
    # userid is in push-userid, content in push-content
    pass
# Simpler: count pushes
push_count = content.count('<div class=\"push\">')
print(f'COMMENT_COUNT: {push_count}')
"
```

更簡潔的推文解析（取前 10 則留言精華）：

```bash
python3 -c "
import re, html as h
with open('/tmp/ptt-capture.html','r') as f: content=f.read()
pushes = re.findall(r'<span class=\"push-tag\">([^<]*)</span><span class=\"push-userid\">([^<]*)</span><span class=\"push-content\">([^<]*)</span>', content)
for tag, user, text in pushes[:10]:
    print(f'{tag.strip()} {user.strip()}{h.unescape(text.strip())}')
"
```

**Step 2F-3：清除暫存**
```bash
rm -f /tmp/ptt-capture.html
```

⚠️ PTT 注意事項：
- 推文格式：`推`（正面）、`噓`（負面）、`→`（補充），都在 `push-tag` 裡
- 作者 ID 可能帶暱稱，格式 `username (暱稱)`
- 文章末尾有 `--\n※ 發信站:` 分隔線，以此截斷正文
- 圖片通常是 imgur 連結貼在正文裡，不在 HTML 結構中

