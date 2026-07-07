---
name: capture
description: 萬能 URL 捕捉手，存文摘/建 wiki entity/觸發後續行動。觸發：存起來、記下來、capture、幫我存、收藏這個（link-capture 已併入）
---

# Capture — 萬能 URL 捕捉手

## CONFIG（依個人設定調整）

> ⚠️ 2026-07-03 校正：原本這裡寫死兩個不存在的桶子清單，但實際 Google Tasks 帳號早已改用主題式清單＋gog skill 的「Emoji 動詞 名詞 #標籤1 #標籤2」命名慣例，沒有同步更新過。以下改成依內容類型對應到正確清單，清單 ID 與命名慣例權威來源是 `~/.claude/skills/gog/SKILL.md`，本檔只放對照表，不重複維護 ID——ID 若對不上以 gog SKILL.md 為準。

```
VAULT_PATH = "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
```

**Tasks 清單對照**（依作品子類型選清單，用 gog skill 的 Emoji 動詞 名詞 #標籤1 #標籤2 命名）：

| 內容子類型 | 清單 |
|-----------|------|
| 書籍/書單（含學習類的「書單」子分類） | 📚 讀書清單 |
| 電影/影集/動畫 | 觀影清單 |
| Podcast | Podcast 清單 |
| 音樂/歌單/專輯 | 🎧 待聽清單 |
| 純購買連結（`購買`類型） | 購物清單 |
| 漫畫/遊戲/其他無專屬清單的作品子類 | 待辦事項（主），標題帶清楚類型字樣（例：`📖 看 XX漫畫 #生活 #娛樂`） |

各清單加入前都要先搜尋是否已有同名項目，有則 skip（沿用原本去重機制），標題格式依 gog SKILL.md 的命名慣例，不是自由格式。

## Overview

URL 進來 → 判斷平台 → 擷取 → **分類內容類型** → 存 Vault → wiki ingest（含 entity 條目）→ **觸發後續行動** → 一行回報。

讀 GOTCHAS.md 再動手，很多坑已經踩過了。

## MCP 依賴（weibo + exa）

capture 需要 `mcp-server-weibo` 跟 `exa` MCP。設定檔位置：`skills/capture/capture-mcp.json`。dispatch 時應以 `--strict-mcp-config --mcp-config skills/capture/capture-mcp.json` 載入，避免繼承主 session 的無關 MCP（憲法 #49）。

**注意**：目前 capture 走 Agent tool 派子代理（繼承主 session MCP），要啟用 strict-mcp-config 需改成 shell spawn `claude --strict-mcp-config --mcp-config skills/capture/capture-mcp.json -p <prompt>` 的 RemoteTrigger 模式。此改造屬架構層，待 channel parity / 派工模型決議。

## Step 1：平台識別（不變）

| URL Pattern | 平台 | 策略文件 |
|-------------|------|---------|
| threads.com, threads.net | Threads | refs/platform-threads.md |
| twitter.com, x.com | X/Twitter | refs/platform-x.md |
| instagram.com/p/, /reel/ | Instagram | refs/platform-instagram.md |
| facebook.com, fb.com | Facebook | refs/platform-facebook.md |
| dcard.tw | Dcard | refs/platform-dcard.md |
| ptt.cc | PTT | refs/platform-ptt.md |
| zhihu.com | 知乎 | refs/platform-zhihu.md |
| reddit.com, redd.it | Reddit | refs/platform-reddit.md |
| youtube.com, youtu.be | YouTube | → youtube-grabber skill |
| .mp3, anchor, spotify podcast | Podcast | → podcast-grabber skill |
| note.com | 日本 note | refs/platform-note.md |
| 其他 | 通用文章/PDF | summarize CLI |

## Step 1.5：內容類型分類（Content Classifier）

在擷取內容後（Step 2 完成後），根據內容判斷類型。**允許雙標籤**（多種類型並存）。

### 設計原則（2026-06-28）

**LLM 驅動，類型表是活文件**：這張表是「錨定分類範例」，不是窮舉規則。判斷由 LLM 根據內容語義執行，不是 if/else 比對。遇到現有類型對不上的內容 → 就地新增一行到此表，附判斷理由，讓分類系統隨時間累積自己的模式。

**分類自動存，不問使用者**：每個類型都有預設存法。只有「純廣告/無實質內容」才標記輕量存或略過，不問。

### 已知類型（錨定範例）

| 類型 | 判斷條件示例 | 存法 | 後續路由 |
|------|------------|------|---------|
| `知識` | 文章本身是洞見/論述/教學 | raw/ | wiki/concepts/ stub |
| `作品` | 介紹/推薦另一個作品（漫畫/書/電影/音樂/遊戲） | raw/ | wiki/entities/[創作者+作品] + Tasks |
| `片單` | 策展型電影/書單/歌單（≥3 部作品列表） | raw/ | wiki/entities/ 各作品 + 清單 playbook |
| `食譜` | 含食材＋做法步驟（或明確指向食譜的影片） | raw/ | wiki/美食/食譜清單.md（輕量路由） |
| `工具` | 介紹軟體/服務/產品功能 | raw/ | wiki/entities/[工具名] |
| `購買` | 純購買連結（無實質評論） | raw/ | Google Tasks 加入購物清單（跳過 wiki stub） |
| `活動` | 演講/展覽/課程/表演報名 | raw/ | Google Calendar |
| `餐廳` | 有店名 + 地點 + 評價/菜色 | 輕量 | wiki/美食/餐廳清單.md（見文末路由） |
| `學習` | 分享書單/文學作者介紹/女性主義論述/心理學理論(如依附)/自由書寫方法等學習向內容 | 輕量 | wiki/學習/學習清單.md（依子分類 section，見文末路由） |
| `AV推薦` | 分享日本AV番號/女優/類型標籤等成人向推薦清單 | 輕量 | wiki/影視/AV片單.md（見文末路由） |
| `課程消費警示` | 具名指控某線上課程/機構延遲交付、退費糾紛、刪言封鎖等消費爭議實例 | raw/（**不跳過** Step 4/4.5/post-processing，走法同知識類，供YT腳本引用原文） | wiki/concepts/ stub（若對應概念頁存在則併入）+ 額外 append wiki/學習/線上課程負評清單.md（見 Step 4.6，這是唯一「raw/正常流程+額外清單append」的混合型，跟餐廳/學習/AV推薦那種完全跳過raw/的輕量路由不同） |
| `設計參考` | 視覺風格/排版/配色/創意方向 | raw/ | wiki/concepts/[風格類型] |
| `洞見` | 一句話非顯而易見的理解、帶「原來是這樣」質地 | 70_Insights/ | 直接建 Insight 卡（含原話） |
| `廣告` | 主體是商品推銷，無實質知識/創作內容 | 略過或 00_Inbox/ | 不建 wiki stub |
| `迷因` | 純截圖/梗/無結構文字 | 00_Inbox/ | 不建 wiki stub |

> **遇到新類型**：在此表末尾新增一行，格式同上。附一句判斷理由。不需要等使用者確認。

### 分類優先序（衝突時由上到下比對，命中即定）

1. 貼文主體是報名/售價/CTA（叫你去買/去報名，非單純分享心得）→ `活動`/`購買`/`廣告`
2. 貼文是日本AV番號/女優/類型標籤推薦清單 → `AV推薦`（優先於下列 `片單`/`作品`）
3. 貼文具名指控某線上課程/機構的消費爭議（延遲交付/退費糾紛/刪言封鎖等）→ `課程消費警示`（優先於下列 `知識`——雖然本質也是論述，但有專屬清單要進）
4. 貼文是書單（不限則數）/文學作者介紹/女性主義論述/心理學理論/自由書寫 → `學習`（優先於下列 `片單`，書單一律歸學習不歸片單）
5. 貼文列出 ≥3 部電影/影集/動畫/歌單等**非書籍**作品名單 → `片單`
6. 貼文介紹單一作品 → `作品`
7. 貼文本身是論述/教學（非介紹別的作品） → `知識`

雙標籤僅限「同一貼文同時符合不同層面」（例：知識+工具），不可用雙標籤迴避上述優先序判斷。

### 食譜輕量路由

> 名稱雖是「輕量路由」，跟後面「餐廳/學習/AV推薦」那種**跳過 raw/** 的路由不同——`食譜` 仍走正常 raw/ 存檔（Step 4/4.5），這裡只是額外幾步專屬處理，不是替代主流程。

偵測到 `食譜` 類型時：
1. 擷取食材清單＋做法步驟
2. 存 raw/（完整食材/做法格式）
3. Append 一行到 `wiki/美食/食譜清單.md` 分類 table
4. **附一張代表菜色照**（不分平台，覆寫「圖片處理原則」預設不下載）：
   - IG Reel 且拿不到影片/caption（登入牆）→ 走 `refs/platform-instagram.md` Step 2C-Thumb（`/p/<shortcode>/media/?size=l`）取縮圖
   - 其他平台／文章 → 抓 `og:image` 下載即可
   - 下載到 `00_Inbox/attachments/YYYY-MM-DD-<菜名>.jpg`，raw/ frontmatter 補 `photo:` + `photo_source:` 欄位，內文 frontmatter 後補 `![[00_Inbox/attachments/檔名]]` 嵌入 + `(照片來源：URL)` 一行
   - 來源完全抓不到圖（如登入牆連縮圖都無）→ 不捏造替代圖，如實在回報中標記缺圖，不因此中斷整體存檔流程
5. 回覆格式：`🍳 [菜名] 已存食譜（食材 N 項，照片 ✓/⚠️缺圖）`

### 片單輕量路由

偵測到 `片單` 類型時：
1. 擷取完整片單（用 Playwright 輪播方案讀完所有圖卡）
2. 存 raw/（表格格式：片名、年份、地區、導演）
3. 各作品建 wiki/entities/ stub（批次，不一一確認）
4. 回覆格式：`🎬 [N 部片單名] 已存（完整 N 部）`

**分類規則**：
- 「文章本身是內容」→ `知識`；「文章在介紹另一個作品」→ `作品`；「列出 ≥3 部作品名單」→ `片單`
- 雙標籤允許（例：知識+工具），Action Dispatcher 各自觸發
- 分類結果記入工作筆記，帶進後續步驟

**擷取失敗 / 內容不完整** → 類型標記 `⚠️待確認`，存 00_Inbox/，報告加警告標記

---

## Step 2：擷取

依平台策略文件執行。降級順序（通用）：
1. curl OG tags
2. web_fetch 全文
3. Browser Relay（最後手段，需 Chrome + 外掛）

## Step 3：AI 生成摘要 + Tags

- **標題**：正規化繁體中文，10-30 字，格式：核心主題-補充描述
- **Telegram 摘要**：約 500 字，分 3 段落，手機好讀（每段 30-60 字）
- **深度摘要**：800-1200 字，涵蓋主要論點、背景脈絡、關鍵細節、留言精華
- **Tags**：3 個語意 tag（主題 + 內容性質 + 具體關鍵字），繁體中文
- **留言精華**：社群平台挑 3-5 則最有代表性的（存入深度摘要）

## Step 3.2：去重檢查（兩層，存前先確認不重複）

> 模型：FRBR — 同一個「作品/工具(Work)」可以有多個「載體(Manifestation)」。同一支工具被作者轉貼到 Threads + FB，是**一個 Work、兩個 URL**。去重要認 Work，不只認 URL 門牌。

**第 1 層 — URL 去重**（同一條網址重複貼）：

```bash
grep -rl "source_url: \"$URL\"" "$VAULT/raw/" 2>/dev/null | head -1
```

找到相同 source_url → skip 整個存檔流程，Integration Report：
`🔄 [標題] 已存過 → [[raw/已存路徑]]（跳過重複存入）`

**第 2 層 — 實體層去重**（同一個 Work、不同平台 URL）：

僅對 `作品` / `工具` 類執行（這兩類有明確的 Work 實體：作品名、工具名/repo）。從 Step 1.5 擷取的內容取出**實體識別鍵**——工具的 GitHub repo / 官方域名 / 工具名，或作品的「作品名＋創作者」——比對既有 raw/ 與 wiki/entities/：

```bash
# 例：工具用 repo slug 當識別鍵（比作品名更穩、跨語言不漂移）
grep -rl "video-autopilot-kit" "$VAULT/raw/" "$VAULT/wiki/entities/" 2>/dev/null | head
```

命中（同一個 Work 已存在）→ **不要再開新的 raw/ 重複存**，改走「併為第二來源」：
1. 在既有 `wiki/entities/<Work>.md` 的 `## 來源` 區塊 append 這條新 URL（標平台＋帳號＋日期）。
2. 既有 `wiki/sources/` 有的話一併補。
3. Integration Report：`🔄 [工具/作品] 已存過（來源 A）→ 本則 [平台] 併為第二來源，未重複存 raw/`

識別鍵取不到（無 repo / 無明確作品名）→ 退回只做第 1 層 URL 去重，正常新建。

---

## Step 3.5：Context Pre-load（存前查重，避免孤島）

從 Step 3 的 Tags 和標題提取 2-3 個核心概念關鍵詞，執行：

```
vault_search(query="<關鍵詞>", scope="wiki/entities/")
vault_search(query="<關鍵詞>", scope="wiki/concepts/")
```

**找到相關頁**：
- 只採信「直接主題命中」的結果——關鍵詞是該頁的主體，不是邊緣提及
- 若信心不足（模糊相關、只在邊緣出現）→ 視同無結果
- 確認命中 → 將**完整檔案路徑**逐字記入工作筆記（如 `wiki/entities/同志之愛.md`），帶進 Step 4.5

**沒找到 / vault_search 報錯**：`RELATED_WIKI` 視為空，Step 4.5 正常新建。不因 MCP 錯誤中斷流程。

*不搜 wiki/sources/（那是來源存根，不是條目層）。如果兩個 vault_search 都無結果，直接跳過。*

## Step 4：存 Obsidian

### Ingest Gate（決定存哪）

| 條件 | 存到 |
|------|------|
| 有 URL + 有實質可引用內容 | `raw/YYYY-MM-DD-正規化標題.md` → 進 wiki |
| 腦補佔位（沒 URL 或內容空洞） | `00_Inbox/YYYY-MM-DD-正規化標題.md` → 不進 wiki |

```
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
檔名：YYYY-MM-DD-正規化標題.md
主路徑：$VAULT/raw/YYYY-MM-DD-正規化標題.md
備路徑：$VAULT/00_Inbox/YYYY-MM-DD-正規化標題.md（gate 未過時用）
```

Frontmatter + 內文格式詳見 refs/obsidian-template.md。

**完成後驗證**：用 `ls` 確認檔案實際落地，不能只存在 session 記憶。

## Step 4.5：Wiki Ingest（僅 Ingest Gate 通過時執行）

**跳過條件**（以下類型不執行 wiki ingest）：
- 類型 = `購買`（純連結，無知識價值）
- 類型 = `迷因`（存 00_Inbox/，不建 stub）
- 類型 = `餐廳`/`學習`/`AV推薦`（輕量路由類型，直接走文末對應「內容類型路由」，不進 Step 4/4.5/4.6/Post-processing 主流程）

其餘類型執行以下流程：

### A. wiki/sources/ 存根（所有類型）

> ⚠️ 2026-07-07 校正：**不要手動建 sources 存根**——Post-processing 的 `wiki-ingest.sh` 會自動用 raw 標題 slug 建一張，它的「已存在跳過」只認自己的 slug，手動另建檔名不同的存根必然重複（實踩：Seed Audio capture 長出兩張，手建那張已刪）。本步驟交給 Post-processing 自動完成；只有 post-processing 因故不跑時才手建，且沿用下列格式。

若確需手建，`wiki/sources/<slug>.md`：
- slug 用英文小寫 kebab-case，不加日期前綴（日期在 frontmatter）
- **來源引用格式**（timestamp 精確到分鐘）：
  `- [[raw/YYYY-MM-DD-slug]] — 貼文摘要（YYYY-MM-DD HH:MM）`

### B. 類型 = `知識` / `課程消費警示` → wiki/concepts/ stub

- 新建或更新 `wiki/concepts/<概念名>.md`（stub: true）
- 在 `## 來源` 區塊末尾加引用行（timestamp 精確到分鐘）
- `課程消費警示` 完成本步驟（B）與下方 E/F 後，還要多做 Step 4.6 的清單 append（不是取代，是額外多一步）

### C. 類型 = `作品` → 創作者 entity + 作品 entity（雙條目）

**創作者 entity** (`wiki/entities/<創作者名>.md`)：
```markdown
---
title: "<創作者名>"
stub: true
tags: [創作者, <類型如漫畫家/作家/音樂人>]
---

## 作品列表
- 《<作品名>》（YYYY）— [[wiki/entities/<作品名>]]

## 來源
- [[raw/YYYY-MM-DD-slug]] — 貼文摘要（YYYY-MM-DD HH:MM）
```

若頁面已存在 → 在對應區塊追加，不覆蓋。

**作品 entity** (`wiki/entities/<作品名>.md`)：
```markdown
---
title: "<作品名>"
stub: true
tags: [作品, <類型如漫畫/小說/電影>]
creator: "[[wiki/entities/<創作者名>]]"
---

## 基本資訊
- 創作者：[[wiki/entities/<創作者名>]]
- 類型：<漫畫/小說/音樂/電影>

## 來源
- [[raw/YYYY-MM-DD-slug]] — 貼文摘要（YYYY-MM-DD HH:MM）
```

**stub 品質門檻**：擷取到的描述 ≥ 30 字，或有購買連結，才建 stub；否則只存 raw/，不建 wiki stub。

### D. 類型 = `工具` → wiki/entities/ 工具頁

- 建 `wiki/entities/<工具名>.md`（stub: true）
- 欄位：功能摘要、官方連結、platform

### E. Context-aware 回寫（通用）

Step 3.5 的 `RELATED_WIKI` 非空 → 在對應頁的 `## 來源` 區塊追加引用行。
格式：`- [[raw/YYYY-MM-DD-slug]] — 貼文摘要（YYYY-MM-DD HH:MM）`

### F. wiki/log.md append

```
- YYYY-MM-DD HH:MM capture: <標題>（@作者/平台）→ raw/ + wiki/[路徑]
```

## Step 4.6：Action Dispatcher（依內容類型觸發後續行動）

根據 Step 1.5 分類結果觸發：

| 類型 | 行動 |
|------|------|
| `作品` | Google Tasks 依作品子類型加入對應清單（見下方 CONFIG 的「Tasks 清單對照」表 + 格式） |
| `購買` | Google Tasks 加入購物清單 |
| `活動` | Google Calendar 建立事件（有日期時） |
| `工具` | wiki/entities/ 工具頁加「試用候補」tag |
| `課程消費警示` | 完成 Step 4.5 的 B/E/F 後，Append 一行到 `wiki/學習/線上課程負評清單.md`（欄位：課程/機構名、爭議摘要、**原始貼文連結**（不是raw/內部連結，YT腳本引用需要外部可查的來源）、raw/存檔連結、收錄日期）。**去重判斷（依序 grep）**：① 原始貼文URL是否已出現在既有某列的來源欄 → 命中直接跳過（同一則貼文重複進來）；② 課程名 → 機構名 → 講師/負責人名 → 常見別名，依序 grep 既有清單找可能相關列；③ 有命中列時，比對事件細節（爭議類型/發生月份或期別/交付或退費或封鎖等具體情節）是否對應同一起事件 → 是則只把這則的原始貼文連結補進該列來源欄，不新增整行；細節對不上（同機構不同期課程、同課程不同時間點的另一起爭議）→ 視為新事件，新增一整行 |

**Google Tasks 加入格式**（沿用 gog skill 命名慣例，不是自由格式）：
- 標題：`Emoji 動詞 作品名 #標籤1 #標籤2`（例：`📖 看 街の上で #生活 #娛樂`、`🎧 聽 XX歌單 #生活 #娛樂`），動詞依子類型選（看/讀/聽），Emoji 依子類型選（📖書/🎬影/🎧樂/🎙️Podcast）
- 描述（notes 欄）：`[平台] [一句話原因] | raw/YYYY-MM-DD-slug.md（@帳號）`
- 清單：依 CONFIG 的「Tasks 清單對照」表選對應清單，用清單 ID（見 gog SKILL.md），不要用清單名稱字串猜測

**去重機制**：加入前先搜對應清單，若有同名項目 → skip，Integration Report 標記「已在清單」。

---

## Step 5：Integration Report（壓縮版）

子代理**不自己 push**，把報告文字作為最終 output 回傳，主 session 負責推送。

### 正常情況（一行）

```
✅ [正規化標題] → [分類] | 已存 raw/ + wiki/[路徑]（[行動，如：Tasks ✓]）
```

範例：
```
✅ 樂園 Kaizbow → 作品 | 已存 raw/ + wiki/entities/Kaizbow + wiki/entities/樂園 | 📚讀書清單 ✓
```

### 需要人介入（正常一行 + 第二行動詞開頭）

```
✅ [標題] → [分類] | 已存 raw/ + wiki/[路徑]
⬜ [動詞] [具體操作]（例：點此確認購買：https://...）
```

### 異常（擷取不完整）

```
⚠️ [標題] 擷取不完整 → 存 00_Inbox/（分類僅供參考）
```

### 完整摘要（附加在一行 report 後，供用戶展開閱讀）

```
📌 [正規化標題]
[作者｜日期｜互動數（如有）]

[摘要，3 段落，每段 30-60 字，手機可讀]

Tags：[tag1 / tag2 / tag3]
（分類錯了？回覆「改成[類型]」即修正）
```

**注意**：Integration Report 的「一行」是首要資訊，完整摘要是次要。ADHD 友善：首行看得懂就夠了。

## LINE 回覆管線化＋狀態尾巴（2026-07-05 使用者裁示）

**背景**：push 配額耗盡（429）期間 reply token 是唯一出口、一則訊息只有一發。即使配額恢復，本節的「榨滿單則資訊量」原則照樣適用。

**鐵則 1：禁發「捕捉中…」類空 ACK**——那是把唯一的一發打在零資訊上。改走延遲交付管線：

1. 使用者丟連結 N → 本輪 reply =「上一個未交付的捕捉結果摘要（若有）」＋「連結 N 已收到、開抓」一句
2. 連結 N 的 Integration Report 寫完先押著（pending 佇列），等使用者下一則訊息的 reply 帶出
3. 使用者連發多個連結沒等回 → 同一則 reply 把佇列裡壓著的結果**全部列出，不准漏**。長度規則：積壓 ≤2 項給完整一行報告；≥3 項每項壓成一行摘要＋「哪項要詳情跟我說」（此條覆寫單則 300 字原則，但仍不得超過 LINE 單則 5000 字硬上限，逼近就再壓縮）
4. 佇列空時，reply 直接講當下捕捉的即時狀態
5. **Flush 出口（防最後一筆永遠送不出去）**：pending 滯留超過 6 小時且使用者無來訊 → 檢查 push 額度，有恢復就 push 清倉；仍 429 就繼續押著並確保已寫進 handoff（結果全文可從 Vault raw/ 重建，slug 就是鑰匙）

**鐵則 2：訊息末尾帶背景任務佇列尾巴**。格式與組裝規則以 `skills/line-output/SKILL.md` §任務狀態尾巴為準（單一去處；含 ⏳ 排隊態）。capture 特有的補充：pending 交付項（押著等下一則 reply 的捕捉結果）也要上尾巴，讓使用者知道有東西在等他領。

**Pending 佇列落地**：主 session 記在對話內即可；跨 session 交接寫進 handoff.md CURRENT，格式含交付指令使其自帶執行力（handoff 是開場自動載入，但 capture SKILL 不是）：
`capture-pending: [slug1, slug2] ← 下一則使用者訊息的 reply 必須帶出這些結果摘要（全文從 Vault raw/<slug> 重建）`

## capture vs youtube-grabber 的區別

| | capture | youtube-grabber |
|--|---------|----------------|
| 觸發 | 朋友分享、隨意瀏覽、想立刻確認 | 訂閱頻道批量收割 |
| 單位 | 單篇即時 | 多篇累積 |
| 去哪 | Vault 00_Inbox/📌_Quick_Refs/ | NotebookLM 知識庫 |
| YT 單篇 | ✅ 走 capture（進 inbox） | 批量時才走這個 |

## 圖片處理原則

**預設不下載**，只在 frontmatter 記 `og_image` URL。

例外（下載到 Vault `00_Inbox/attachments/`）：
1. 資訊圖表（流程圖、對照表、數據視覺化）
2. 來源可能消失（限時動態、可能被刪的帖子）
3. 用戶自己的照片/截圖
4. 類型 = `食譜`（不分平台）：一律下載一張代表菜色照，見下方「食譜輕量路由」Step 4（2026-07-06 使用者裁示，見 cold-storage/rule-changes.md）

## 原文保留原則

**一律原文照搬，不改寫不潤飾。**把抓到的原文、摘要、留言原封不動存入。

## Post-processing（自動 wiki ingest）

capture 存完 raw/ 後，呼叫：
```bash
bash ~/life-os/scripts/wiki-ingest.sh --raw "$RAW_PATH"
```
若 wiki 卡已存在會自動跳過。這一步讓 capture → wiki 形成自動鏈路，不需手動建 wiki stub。

---

## 內容類型路由：餐廳貼文

偵測到貼文主題是「餐廳 / 美食評測」時，走輕量化路由：

**判斷條件**（任一命中）：
- 貼文含地址（`📍` 或「地址：」）
- 貼文含餐廳名 + 菜單描述
- hashtag 含 `#美食` / `#食記` / `#吃什麼`

**輕量化流程**：
1. 擷取關鍵資訊：店名、地點（城市 + 地址）、必點菜色、評分、來源帳號 + URL
2. 判斷食物類別（創意融合、日式、台式小吃、義式、燒烤、火鍋……）
3. 將一行記錄 append 到 `wiki/美食/餐廳清單.md` 的對應分類 table
   - 分類不存在 → 在文末新增 `## 類別名稱` section 再加 table
4. **可省略** raw/ 完整存檔（原始貼文不再重要）；若內容有獨特食評觀點仍可存 raw/
5. wiki/log.md append 一行

**回覆格式**：
```
🍽️ [店名] 已加入餐廳清單（[類別]）
📍 [地址]
✨ [2-3 道必點]
```

## 內容類型路由：課程消費警示貼文

⚠️ 這節不是輕量路由，跟下面「學習類貼文」「AV推薦貼文」的「跳過raw/」邏輯不同——`課程消費警示` **正常走 raw/ + Step 4.5(B) + Step 4.6**，這節只是把散在各處的步驟集中列一次方便查：

1. Step 4：寫 `raw/YYYY-MM-DD-slug.md`（跟 `知識` 類型一樣，完整保留原文，供日後 YT 腳本引用）
2. Step 4.5：執行 A（wiki/sources/）、B（wiki/concepts/ stub，若既有概念頁存在則併入來源）、E（context-aware回寫）、F（wiki/log.md）
3. Step 4.6：Append 到 `wiki/學習/線上課程負評清單.md`（欄位與去重判斷見 Step 4.6 表格）
4. 回覆格式：`⚠️ [課程/機構名] 已存課程消費警示（[新事件/併入既有事件]）`

## 內容類型路由：學習類貼文

偵測到貼文主題是「書單／文學作者介紹／女性主義論述／心理學理論／自由書寫方法」時，走輕量化路由。**此類型跳過 Step 4（raw/存檔判斷）、Step 4.5（wiki ingest）、Post-processing（wiki-ingest.sh）——不存 raw/，只 append 清單一行即完成存檔。**

**子分類固定 6 類（不開放自由新增 section）**：書單、文學作者、女性主義論述、心理學依附、自由書寫、其他。完全不屬於前 5 類時一律併入「其他」，不得依語意自創新 section 名稱。

**輕量化流程**：
1. 擷取關鍵資訊：標題/書名、作者或講者、一句話重點、來源帳號 + URL
2. **去重**：append 前 grep `wiki/學習/學習清單.md`，若同一「標題/書名＋作者」已存在該 row → 跳過不重複加，Integration Report 標記「已在清單」
3. 未重複 → Append 一行到對應子分類 table
4. raw/ 一律省略（此類型不存 raw/，含子分類「書單」在內，無例外）
5. wiki/log.md append 一行

**唯一例外（書單子分類，比照 `作品` 類但不存 raw/）**：子分類為「書單」且描述 ≥ 30 字時，額外建 `wiki/entities/` 作者＋作品 stub（`stub: true`），來源引用格式改用 `- 學習清單 @YYYY-MM-DD — 一句話重點`（不指向 raw/，因為此類型本來就不存 raw/），並視情況加入 📚 讀書清單（格式同 Step 4.6 的 Tasks 加入格式）。其餘 5 個子分類（文學作者/女性主義論述/心理學依附/自由書寫/其他）不建 entity。

**回覆格式**：
```
📚 [標題] 已存學習清單（[子分類]）
```

## 內容類型路由：AV推薦貼文

偵測到貼文內容是「日本AV番號/女優/類型標籤推薦清單」時，走輕量化路由。**此類型跳過 Step 4（raw/存檔判斷）、Step 4.5（wiki ingest）、Post-processing（wiki-ingest.sh）——不存 raw/，只 append 清單一行即完成存檔。**

**輕量化流程**：
1. 擷取每筆：番號、女優/演員名（如有）、類型標籤（如：墙纸/纯爱/师生/反差 等原文標籤照抄不改寫）、來源帳號或截圖出處
2. **去重**：append 前 grep `wiki/影視/AV片單.md` 是否已有相同番號（大小寫不敏感），有 → 該筆跳過不重複加
3. 未重複的筆數 append 到 table（一番號一行）
4. **不建** wiki/entities/ 演員或作品 stub（此類型不做實體擴充，僅平面清單記錄）
5. raw/ 一律省略（不存原始貼文/截圖）
6. wiki/log.md append 一行

**回覆格式**：
```
🔞 [N 筆新增/M 筆重複跳過] 已加入 AV片單（[來源帳號]）
```

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
