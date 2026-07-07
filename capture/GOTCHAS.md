# GOTCHAS.md — capture skill

> 格式：**錯誤描述** / **正確做法** / **觸發情境**
> 這些都是真實踩過的坑，改 skill 前先讀這裡。

---

## G1: IG 不能用 curl OG tags 取代 Browser Relay

**錯誤**：認為 curl 抓 OG tags 就夠了，繞過 Browser Relay 節省時間。
**正確**：curl OG tags 只拿到 caption + 第一張圖，IG 輪播圖片中大量內容在後續圖片的圖片文字裡，全部遺失。IG 必須走 Browser Relay。
**觸發情境**：擷取 Instagram 帖文 URL，特別是含多張圖片的輪播貼文。

---

## G2: 不要自作聰明修改設計決策

**錯誤**：看到「IG 走 Browser Relay」覺得多此一舉，直接改成 curl 方案。
**正確**：每個設計決策背後有原因。不理解意圖就別改，先讀 SKILL.md 和 GOTCHAS 了解為什麼，再問用戶確認。
**觸發情境**：覺得現有方案「太複雜」想簡化的時候。

---

## G3: Vault 圖片不能直接用於外部顯示

**錯誤**：把圖片存到 Vault 後用 vault URL 做預覽。
**正確**：Vault 有 Cloudflare Access 保護，外部讀不到。圖片存到 `00_Inbox/attachments/`，外部預覽用 og_image 原始 URL 或不顯示圖。
**觸發情境**：想在 Telegram 回覆中顯示擷取到的圖片。

---

## G4: 產出必須落地 Vault 才算完成

**錯誤**：任務完成了，但筆記只存在 session 記憶，沒有寫到 Vault。
**正確**：每次擷取完成後必須寫 Obsidian `00_Inbox/`。session 結束後未落地的產出會消失。交付前用 `ls` 確認檔案實際存在。
**觸發情境**：擷取長文章、社群貼文後，任務結案。

---

## G5: Threads / X / 非 IG 平台預設不需要 Browser Relay，但登入牆/留言要升級

**錯誤**：因為 IG 用 Browser Relay，就把所有平台都走 Browser Relay；或反過來，遇到 Threads 登入牆/想抓留言時還是死守純 HTTP 硬幹。
**正確**：Threads、PTT、知乎等預設用直接 HTTP 請求即可。但遇到兩種情況要升級：(1) og:title 回傳「Threads • Log in」登入牆，(2) 使用者要連留言一起讀（留言是 client-side GraphQL 動態載入，curl 永遠抓不到）。這兩種情況改用 `skills/capture/scripts/browser-relay-threads.mjs`（2026-06-25 前 Browser Relay 只是文件裡的策略名稱，從未真正實作；現在有真實程式碼）。
**觸發情境**：擷取非 IG 的社群媒體 URL；curl 回傳登入牆或使用者明確要求留言內容。

---

## G6: IG embed HTML 的 display_url 提取容易寫錯

**錯誤 1**：用簡單 regex `edge_sidecar_to_children.*display_url` 打不到資料。
**錯誤 2**：用 `grep -o 'display_url[^,]*'` + Python 切割——切割點不穩定，URL decode 後路徑被截斷（`cdninstagram.com/v/` 遺失）。
**正確**：用 Python `re.finditer(r'\\"display_url\\":\\"(https:.+?)(?=\\")', content)` 從整份 embed HTML 掃全部 display_url；再用 `.replace('\\\\\\/','/')` 還原路徑（Python repr 中 `\\\\\\/` = raw bytes `\\/`）；過濾 `cdninstagram` 去重。詳見 refs/platform-instagram.md Step 2C-2。
**觸發情境**：擷取 IG 輪播圖片清單。

---

## G7: PTT 八卦板等 18+ 看板必須帶 over18 cookie

**錯誤**：curl 直接抓 PTT 被重定向到年齡確認頁。
**正確**：加 `-H "Cookie: over18=1"` header。
**觸發情境**：抓 PTT 八卦板、表特板等成人版。

---

## G8: YouTube 走 youtube-grabber，不走 summarize（⚠️ 2026-07-03 發現該 skill 實際不存在）

**錯誤**：YouTube URL 用 summarize CLI 抓，品質差且無法進 NotebookLM。
**正確（原設計）**：YouTube 一律走 youtube-grabber skill（yt_notebook_pipeline.py），產出結構化摘要 + 可匯入 NotebookLM。
**⚠️ 現況（2026-07-03 確認）**：`~/.claude/skills/` 與 `life-os/skills/` 都找不到 youtube-grabber 這個 skill——文件指向的目標從未真正存在，或已被移除但沒同步改文件。line-note channel 遇到單篇 YouTube capture 時目前降級用 `yt-dlp` 直接抓標題/描述/字幕，比照一般 raw/ 存檔流程處理，不強求進 NotebookLM 管線。批量訂閱收割需求仍應找 yt-script 或補建 youtube-grabber。
**觸發情境**：偵測到 youtube.com 或 youtu.be URL。

---

## G9: Reddit MCP 需要先安裝設定

**錯誤**：呼叫 Reddit MCP 工具但沒有安裝。
**正確**：Reddit MCP（mcp-reddit）需先安裝並在 .mcp.json 設定。安裝前降級用 web_fetch 抓 Reddit 頁面。
**觸發情境**：擷取 reddit.com URL 時。

---

## G11: IG Reel 影片下載失敗時，background LINE session 無法用瀏覽器登入態繞過

**錯誤**：以為只要用 `browser_cookie3` 讀瀏覽器 cookie 掛上登入態，就能繞過 embed HTML 缺 video_url 的限制。
**正確**：某些 IG Reel（帳號限制 embed 下載，或內容被標為需登入）embed HTML 完全沒有 `video_url` 欄位，直接開 reel 頁面也是純登入牆空殼（client-side render，curl 抓不到內容）。嘗試用瀏覽器登入態繞過時會撞兩個環境限制，不是可重試修好的錯誤：
1. Safari：`browser_cookie3.safari()` 只能讀到 5 個輔助 cookie（csrftoken/datr/ig_did/ig_nrcb/mid），沒有 `sessionid`——這代表 Safari 對 IG 的登入 session token 這台環境讀不到（不確定是沒登入還是 ITP 擋第三方讀取）。
2. Chrome：`browser_cookie3.chrome()` 會拋 `Unable to get key for cookie decryption`——Chrome cookie 在硬碟上是加密的，解密金鑰要跟 macOS Keychain 要，Keychain 授權需要跳出 GUI 視窗讓人按「允許」。background LINE session 沒有畫面，這個授權請求會直接被拒絕，不會重試就通。
`yt-dlp`（含 `--cookies-from-browser safari`）在這種情況下會回報 `Instagram sent an empty media response`，同樣印證是帳號/內容端的登入限制，不是擷取邏輯寫錯。
**正確做法**：這類貼文標記 ⚠️待確認存 raw/（不要因為抓不到就整個放棄存檔），如實跟使用者說明卡在哪個環節。真的要解，只能：(a) 請使用者在有畫面互動的 session（如 termi）跑一次同樣抓取，讓 Keychain 授權視窗能被按允許；或 (b) 使用者自己從瀏覽器開發者工具複製 `sessionid` cookie 值，手動傳給 capture 使用。
**觸發情境**：IG Reel embed HTML 抓不到 `video_url`，且直接開 reel 頁面回傳登入牆（`<title>Instagram</title>` 空殼，找不到任何 `.mp4` 字串）。

**2026-07-06 更新（縮圖限定的繞道）**：上述限制專指「抓完整影片」。若只需要一張代表縮圖（例如食譜卡配圖），`/embed/captioned/` 端點本身現在也常回登入牆空殼，但改打 `https://www.instagram.com/p/<shortcode>/media/?size=l`（`/p/` 而非 `/reel/`，即使原始網址是 `/reel/{shortcode}/` 也一樣代入）會直接回 200 JPEG，不需登入態、不需 cookie。實測對本條 G11 原本記錄的「完全登入牆」案例（miamirecipes 絞肉包麵條）也成功取到縮圖。此繞道**只能拿縮圖，拿不到影片本體或 caption**，抓完整影片/文字仍照本條 G11 原流程判斷。
**觸發情境**：只需要 IG Reel 的代表縮圖（如食譜卡配圖、Vault 附件），且 embed endpoint 回登入牆時。

---

## G10: 自動建立的 wiki entity 卡必須加 stub: true

**錯誤**：capture pipeline 建立 wiki/entities/ 卡時，直接把第三方描述複製進內文，沒有 stub: true。
**正確**：自動建立的 entity 卡一律加 `stub: true`，只存錨點層（來源連結 + 基本識別資訊），不補描述，不做 WebSearch。stub 只有在使用者主動表達觀點後才移除（由 wiki-note.sh 處理）。
**觸發情境**：任何 wiki ingest pipeline 自動建立 entities/ 或 concepts/ 卡時。
- [0.5] IG 平台直接登入爬蟲會被擋，但透過 embed endpoint 可成功擷取內容；capture skill 的平台特定路徑文件應明列登入 vs embed 兩種方案，避免重複踩坑。 (2026-04-28, 1 hit)
- [0.5] capture skill 處理 Instagram Reel（`/reel/{ID}/`）時，直接 curl 抓 og tags，`og:title`/`og:description`（caption）經常回傳 None——這是常見情況不是錯誤，不必重試或換 UA。仍可拿到 `og:image`（縮圖）和 `og:url`（含作者帳號，從 twitter:title 取）。 Fallback：下載縮圖用 Read 工具看疊字；解析度不夠時用 PIL crop+resize 放大招牌/門牌/菜單區域再讀一次。讀到店名地址 → 走餐廳輕量路由；疊字只有行銷話術讀不出店名 → 標記 ⚠️待確認 存 00_Inbox，原文記錄疊字+帳號供使用者補店名。 本次 batch（6則 IG Reel）僅縮圖判讀，命中率低（~360x640 解析度，招牌字 crop 後仍模糊），全數落 ⚠️待確認。建議 refs/platform-instagram.md 補一段「Step 2D：Reel caption 取不到時 fallback」說明此流程與預期命中率，避免下次誤以為抓取失敗而重試或誤判平台被封鎖。 (2026-06-11, 1 hit)
- [0.5] WebFetch 對 note.com（及其他動態載入/可能有付費牆的部落格平台，如 ameblo、hatena）讀取失敗時，不是回報「抓不到」或回傳空白，而是用小模型對殘缺內容腦補出一份看起來言之鑿鑿、細節豐富的完整分析——連專有名詞都會被「合理替換」（例如把日文卡名「メガカイリューex」誤讀成形似的「Mega大力鱷ex」），並編造具體數據（賽事排名、陣容、戰績）來填補空缺。輸出本身找不到破綻，使用者要靠對領域內容的熟悉度才抓得出錯。 修正/驗證方法：對這類網域不要只信 WebFetch 的摘要，改用 `curl -sL "https://r.jina.ai/<原始URL>"` 直接走 Jina Reader proxy 取得乾淨 markdown 全文（note.com 多數文章其實免登入也能透過 jina 取得完整正文，不一定真的有付費牆），再用全文核對 WebFetch 給的關鍵專有名詞/數字是否一致。`~/.claude/skills/notebooklm/paywall_fetch.py` 已有同樣的 jina fallback（L1 層），但那份文件的重點是「如何繞過付費牆」，沒有點出「WebFetch 在這類站台會自信幻覺而非報錯」這個更通用的風險——遇到日文部落格/動態頁面的具體事實陳述（人名、卡名、排名、數字），預設先用 jina/curl 交叉驗證再採信。 (2026-06-11, 1 hit)
- [0.5] IG 貼文中食譜圖片（尤其是步驟說明圖）的文字擷取常不完整。杏鮑菇炸法食譜本次擷取即缺漏部分步驟說明，需要回看原始貼文才能補齊——這是圖內文字辨識的邊界問題，與既有「caption 常回空值」不同維度。 (2026-07-02, 1 hit)
- [0.5] Threads 貼文隱藏展開區域（「閱讀全文」）既有 browser-relay 不自動點擊，需 Playwright 一次性變體補完 (2026-07-02, 1 hit)


## G12: 取材遞增流程（三階梯，逐級升級不要跳級硬幹）

**原則**：抓不到資料時按成本由低到高逐級升，別一開始就開重武器、也別在低階硬耗。
1. **第一階｜基礎**：WebFetch / `curl` / `curl https://r.jina.ai/<url>`（jina 對付動態頁腦補）——最快最省，多數站這關就過
2. **第二階｜進階瀏覽器（headless）**：`chrome-autobot` persistent profile（真指紋，過一般 reCAPTCHA）headless 模式——第一階被登入牆/JS render 擋時升這階
3. **第三階｜有頭瀏覽器遙控（headed + 人協）**：headless 被 **Cloudflare 主動挑戰（「Just a moment」）** 硬擋時，改 `headless:false` 在家機螢幕開視窗、輪詢等內容出現；跳挑戰就靠使用者在螢幕點一下（通用控制），過關後腳本自動抓
- **判級訊號**：body 出現「安全驗證/Just a moment/Verify you are human」＝Cloudflare 主動挑戰＝直接跳第三階（第一二階必敗別浪費）；純登入牆＝第二階；一般文章＝第一階
- 實例：2026-07-04 PhoneArena（X3 評測）三階梯實走，前兩階全被 Cloudflare 擋，第三階有頭+人協過關。使用者提出此遞增流程原則。

## G13: LINE Mac 聊天內容是 macOS 可及性黑盒（別想用 AX 自動化匯出）

**錯誤**：以為給了輔助使用權限就能用 AppleScript/System Events 點 LINE 的「儲存聊天」或直接讀訊息。
**正確**：2026-07-04 實測（權限已授、osascript 不再 -1719）——LINE 自繪 UI，可及性樹只暴露視窗 chrome 按鈕＋輸入框＋選單列；**「選項/儲存聊天」按鈕無名定位不到、歷史訊息氣泡完全不在 AX 樹裡**。選單列也無匯出項。全自動 UI 化死路。**LINE 對話備份只能半自動**：使用者手動「儲存聊天」匯出 txt→腳本接手搬檔/去重/分域。
**觸發情境**：想自動化 LINE Mac 桌面版的聊天匯出/讀取。
