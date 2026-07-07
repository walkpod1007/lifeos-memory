# Platform Detection & Capture Reference

## URL Patterns

### Social Media
- **Threads**: `threads.com/@{user}/post/{id}` or `threads.net`
- **X/Twitter**: `twitter.com/{user}/status/{id}` or `x.com/{user}/status/{id}`
- **Instagram**: `instagram.com/p/{id}` or `instagram.com/reel/{id}`
- **Facebook**: `facebook.com/{user}/posts/{id}` or `fb.com` or `facebook.com/share`
- **Dcard**: `dcard.tw/f/{forum}/p/{id}`
- **PTT**: `ptt.cc/bbs/{board}/{article}.html`

### Content Sites (non-exhaustive, fallback to generic)
- News: any URL not matching social patterns
- Blog: medium.com, substack.com, blogger.com, wordpress.com, etc.

## Capture Strategy Matrix

| Platform | Primary | Fallback | Login Required | Comments Available |
|----------|---------|----------|----------------|-------------------|
| Threads | Relay | - | Partial (more with login) | Yes, threaded |
| X | Relay | - | Yes for full thread | Yes, threaded |
| Instagram | Relay | - | Yes for comments | Limited |
| Facebook | Relay | - | Yes | Yes |
| Dcard | Relay | - | No | Yes, paginated |
| PTT | JSON API | Relay | No | Yes, in article body |
| News/Blog | web_fetch | Relay | Usually no | Varies |

## PTT JSON API

Base URL: `https://www.ptt.cc/bbs/{board}/{article}.json`

Example:
- Web URL: `https://www.ptt.cc/bbs/Gossiping/M.1709000000.A.123.html`
- JSON URL: `https://www.ptt.cc/bbs/Gossiping/M.1709000000.A.123.json`

Note: May require `over18=1` cookie for certain boards (Gossiping, Sex, etc.)

## Snapshot Parsing Tips

### Threads
- Main post: look for first content block after author avatar
- Comments: subsequent blocks with author + timestamp + content
- Interactions: buttons with "讚", "回覆", "轉發", "分享" + counts

### Dcard
- Main post: `article` element with heading + body text
- Comments: `comment content` elements with author school/name + text
- Interactions: like/comment counts in article header

### X/Twitter
- Main tweet: first tweet block in timeline
- Replies: subsequent tweet blocks
- Interactions: retweet, like, reply, bookmark counts

### Facebook
- Highly variable DOM, rely on text content extraction
- Look for post body text, author name, timestamp
- Comments may require scrolling/clicking "View more"

### Instagram
- Caption: text below image/reel
- Comments: may need login to view
- Interactions: like count, comment count
