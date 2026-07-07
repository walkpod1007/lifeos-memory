# Reddit 擷取流程

## 安裝 Reddit MCP（一次性設定）

```bash
# 安裝 mcp-reddit
npm install -g mcp-reddit

# 在 Life-OS .mcp.json 加入：
# {
#   "mcpServers": {
#     "reddit": {
#       "command": "mcp-reddit",
#       "env": {
#         "REDDIT_CLIENT_ID": "...",
#         "REDDIT_CLIENT_SECRET": "...",
#         "REDDIT_USERNAME": "...",
#         "REDDIT_PASSWORD": "..."
#       }
#     }
#   }
# }
```

Reddit API 申請：https://www.reddit.com/prefs/apps（選 script 類型）

## URL 模式

| 模式 | 類型 |
|------|------|
| reddit.com/r/{sub}/comments/{id}/ | 貼文 + 留言 |
| reddit.com/r/{sub}/ | Subreddit 首頁 |
| redd.it/{id} | 短網址（先解析） |

## 擷取流程（MCP 已設定）

```
# 從 URL 取得 post ID
POST_ID=$(echo "$URL" | grep -oP '(?<=comments/)[a-z0-9]+')

# 用 MCP 工具抓貼文
→ mcp-reddit: get_post(post_id)
→ mcp-reddit: get_comments(post_id, limit=20, sort="top")
```

## 降級方案（MCP 未設定）

```bash
# Reddit JSON API（不需登入，公開帖）
curl -sL -A "Mozilla/5.0" "https://www.reddit.com/r/{sub}/comments/{id}/.json" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
post = data[0]['data']['children'][0]['data']
print('TITLE:', post['title'])
print('AUTHOR:', post['author'])
print('SCORE:', post['score'])
print('TEXT:', post.get('selftext', '（連結貼文）')[:500])
# Top comments
comments = data[1]['data']['children'][:5]
for c in comments:
    cd = c.get('data', {})
    if cd.get('body'):
        print(f'COMMENT [{cd.get(\"score\",0)}]: {cd[\"body\"][:200]}')
"
```

## 注意

- Reddit JSON API 有 Rate Limit，大量請求會被擋
- 部分 subreddit 需要登入才能看內容（NSFW 或私人社群）
- 貼文刪除後 JSON API 仍返回 `[deleted]`，無法還原
