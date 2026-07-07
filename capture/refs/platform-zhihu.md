# Step 2H：知乎專用流程（curl 直抓 initialData JSON）

知乎專欄和問答的全文都藏在 HTML 的 `<script id="js-initialData" type="text/json">` 裡，一次 curl 即可取得，不需要 Browser Relay。

**Step 2H-1：curl 抓頁面**

```bash
curl -sL \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -H "Accept-Language: zh-TW,zh;q=0.9" \
  "$URL" -o /tmp/zhihu-capture.html
```

**Step 2H-2：解析 initialData JSON 取全文**

```bash
python3 -c "
import re, html as h, json
with open('/tmp/zhihu-capture.html','r') as f: content=f.read()

m = re.search(r'<script id=\"js-initialData\" type=\"text/json\">(.*?)</script>', content, re.DOTALL)
if m:
    data = json.loads(m.group(1))
    # 專欄文章
    articles = data.get('initialState',{}).get('entities',{}).get('articles',{})
    for aid, article in articles.items():
        title = article.get('title','')
        author = article.get('author',{}).get('name','')
        content_html = article.get('content','')
        text = re.sub(r'<[^>]+>', '', content_html)
        text = h.unescape(text)
        print(f'TITLE: {title}')
        print(f'AUTHOR: {author}')
        print('---CONTENT---')
        print(text)
        break
    else:
        # 問答回答
        answers = data.get('initialState',{}).get('entities',{}).get('answers',{})
        for aid, answer in answers.items():
            author = answer.get('author',{}).get('name','')
            content_html = answer.get('content','')
            text = re.sub(r'<[^>]+>', '', content_html)
            text = h.unescape(text)
            print(f'AUTHOR: {author}')
            print('---CONTENT---')
            print(text)
            break
else:
    print('NO_INITIAL_DATA')
"
```

⚠️ 注意事項：
- `initialState.entities.articles` 放專欄文章，`initialState.entities.answers` 放問答回答
- content 欄位是 HTML，需 strip tags + unescape
- 如果 `js-initialData` 不存在（極少見），降級到 OG tags 摘要
- 不需要登入，公開文章都能抓到全文

**Step 2H-3：清除暫存**
```bash
rm -f /tmp/zhihu-capture.html
```
