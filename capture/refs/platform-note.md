# Platform: 日本 note（note.com）

note.com 是日本的內容平台，**JS 重渲染 + 常有付費牆（有料記事）**。
通用 `web_fetch` 只會拿到首屏／試讀段（常被「ここから先は」切斷），所以 note 走專用抓取。

## 抓取策略：paywall_fetch.py cascade（含 jina）

note 連結一律改用已硬化（過 3 輪 codex）的 paywall 抓取器：

```bash
python3 ~/.claude/skills/notebooklm/paywall_fetch.py "<note_url>"
```

cascade 層級（依序，命中即止）：
- **L0 `authenticated-cookie`**：有設 note cookie 時先試（拿有料記事全文）
- **L1 `jina`**（`r.jina.ai`）：沒 cookie 或 auth 失敗才走這層；免費/軟牆通常這層命中（就是你聽說的那招）
- L2+ `defuddle` 等後備（**除非人工確認，L2+ 命中不自動視為完整**——這些層品質不穩，傾向當不完整走 00_Inbox/）

輸出**分兩個流，務必分開處理**：

```
# stderr（只是 meta，不要進摘要、不要進 Vault）：
ok      : True
method  : jina           # 命中哪層：authenticated-cookie | jina | defuddle
title   : <文章標題>
chars   : <字數>

# stdout（正文全文，這個才是摘要素材）：
<正文全文…>
```

- **只拿 stdout 當摘要素材**；stderr 只用來讀 `method`/`title`/`chars`。
- 取用時務必 `2>/dev/null` 把 stderr 丟掉，或分流捕捉，**絕不可 `2>&1` 把 meta 混進正文**。
- `method: authenticated-cookie` 或 `jina` 且字數合理 **且未命中下方切斷特徵** → 視為完整，往下走摘要。（字數長 ≠ 完整：長試讀段也可能很長，必須同時通過切斷判定。）

## 關鍵差異：Vault 只存「詳細摘要」，**絕不存原文**

⚠️ **note 是 capture「原文保留原則」的明確例外。**
jina/cookie 抓回的 stdout 全文**只當生摘要的素材，留在 session，不寫檔**：
- 避開付費內容版權問題
- 摘要才是這個人要的（使用者明示「Vault 不用讀全文，只需要詳細摘要」）

**覆寫主模板**（重點，否則會把全文塞進 Vault）：
- note 存檔**不使用** `refs/obsidian-template.md` 的 `## 原文` 區塊——該區塊一律**省略**，改放 `## 來源說明`（一句：本文為 AI 詳細摘要，非原文照搬；來源 note 付費/JS 站）。
- SKILL.md Step 3「原文保留原則／一律原文照搬」對 note **不適用**。
- raw/ 內文主體 = Step 3 產生的「深度摘要」（800–1200 字），**不得**貼 stdout 全文。

流程：
1. `paywall_fetch.py` 抓 stdout 全文（素材，session 內用，不寫檔）
2. 用 stdout 全文作為素材，執行 note 專用深度摘要（主要論點＋脈絡＋關鍵細節，800–1200 字）；**不套用 SKILL.md Step 3 的「原文保留原則／一律原文照搬」**
3. **Step 4 存檔**：raw/ 內文放詳細摘要 + `## 來源說明`，省略 `## 原文`；frontmatter 照常記 `source_url`/`title`/抓取 `method`
4. 後續 Step 3.5 / 4.5 / 4.6 照 SKILL.md 正常走（僅在「擷取完整」時，見下）

## 試讀段切斷判定 → 走 00_Inbox/，不污染 wiki

切斷特徵分強弱（在 stdout **任意位置、尤其後半段**掃描，不限結尾——後面常接平台 boilerplate／推薦文／頁尾）：
- **強訊號（單一命中即判切斷）**：`ここから先は`、`この続きをみるには`、`購入すると表示されます`、`記事を購入`、`メンバーシップに加入`等 paywall UI 字樣
- **弱訊號（需搭配字數異常短或上下文才算）**：單獨出現「有料」不足以判定——文章在討論「有料記事」這主題本身也會出現，易誤傷

命中強訊號，或弱訊號＋字數異常短時：

- **視為「擷取不完整」**，依 SKILL.md 主流程走 **`00_Inbox/`**（不是 raw/），frontmatter `status: incomplete`，**跳過 Step 4.5 wiki ingest 與 Step 4.6 action dispatch**——避免不完整內容污染 wiki、被誤當成功擷取。
- 報告標記：`⚠️ 可能只有試讀段（需 note cookie 拿全文）→ 暫存 00_Inbox/`
- 已設 cookie 仍切斷 → cookie 可能過期，提示重設。
- 例外：使用者明示「試讀摘要也當正式來源」才放行進 raw/+wiki。

擷取完整（沒切斷跡象）才走正常 raw/ + wiki ingest。

## note cookie（拿付費記事全文，選配）

**嚴禁從 LINE 貼 cookie。** 從 termi 設：
```bash
python3 ~/.claude/skills/notebooklm/paywall_fetch.py --set-cookie note.com
# 貼上瀏覽器 DevTools → Application → Cookies → note.com 的整串，Enter
```
存於 `~/.config/notebooklm-paywall/cookies.json`（600 權限，不進 git）。cookie 會過期，失效重設。
安全細節見 `ssrf-url-validation-gotchas` skill（cookie 只在 https＋同 host＋同 port 才送）。

## 回報範例

完整擷取：
```
✅ <note 標題> → 知識 | 已存 raw/（詳細摘要，無原文）+ wiki/concepts/<概念>
   （method: jina；Vault 存摘要非全文）
```
付費切斷：
```
⚠️ <note 標題> 可能只拿到試讀段 → 暫存 00_Inbox/（未進 wiki）| 要全文請從 termi 設 note cookie
```
