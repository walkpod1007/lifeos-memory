# Step 2G：Dcard 專用流程（openclaw browser，Cloudflare 擋 curl）

Dcard 有 Cloudflare JS Challenge，curl 完全無法穿透。用 `openclaw browser` 開真實 Chrome 繞過。

**不需要 Browser Relay 擴充套件**——`openclaw browser` 自己管理的 Chrome 就夠（公開貼文不需登入）。

**Step 2G-1：開啟頁面**

```bash
openclaw browser open "$URL"
```

等 3 秒讓頁面載入完成。

**Step 2G-2：用 evaluate 抓取 DOM 內容**

```bash
sleep 3
openclaw browser evaluate --fn "() => {
  const title = document.querySelector('h1')?.textContent || '';
  const meta = document.querySelector('meta[property=\"og:description\"]')?.content || '';
  const article = document.querySelector('article')?.textContent || '';
  const author = document.querySelector('[class*=Author]')?.textContent || '';
  const time = document.querySelector('time')?.getAttribute('datetime') || '';
  const comments = Array.from(document.querySelectorAll('[class*=comment]')).slice(0,10).map(c => c.textContent).join('\\n---\\n');
  return JSON.stringify({title, meta, article: article.substring(0, 5000), author, time, comments: comments.substring(0, 2000)});
}"
```

⚠️ `snapshot` 指令在 Relay 模式下不可用（會報 `Not allowed`），只能用 `evaluate`。

**Step 2G-3：關閉分頁**

```bash
openclaw browser close <tab_id>
```

tab_id 從 Step 2G-1 的輸出取得。

⚠️ Dcard 注意事項：
- Cloudflare 有時會彈驗證頁，evaluate 拿到的可能是驗證頁內容——檢查 title 是否含「Cloudflare」
- 如果被擋，等 5 秒重試一次（Cloudflare 通過後會設 cookie）
- 留言區可能需要滾動才能載入更多，首次只能抓到前幾則

