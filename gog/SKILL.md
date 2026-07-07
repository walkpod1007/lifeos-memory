---
name: gog
description: Google Workspace CLI（Gmail/Calendar/Tasks/Sheets/Drive/Docs/Contacts）。觸發：查 tasks、查行事曆、gmail 搜尋、Google Sheet、加 task、gog
version: 2.1.0
account: user@example.com
cli: gws
---

# gws — Google Workspace CLI（yourchannel 帳號）

> ⚠️ **帳號**：`user@example.com`（gws CLI）。yourchannel2 的 Tasks → 用 `gog-yourchannel2` skill。
>
> **2026-07-01 修正**：`gws auth list` 顯示 CLI 預設帳號已於 2026-05-25 切到 `user2@example.com`（非本文件標題所寫的 yourchannel）。不帶 env var 的裸 `gws` 指令現在直接打中 yourchannel2。若要打 yourchannel，`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=.../credentials.json` 這個環境變數機制目前對兩個帳號都回 401（`credentials.json` 與 `credentials-yourchannel2.json` 皆然，`gws` 也沒有 `--account` flag）——已知為壞的，需要重新 `gws auth login --account user@example.com` 才能修，不要假設這條路現在能用。

`gws` 是 Google Workspace 的官方社群 CLI（取代舊 gog），已完成 OAuth，token 自動 refresh。

**指令格式**：`gws <service> <resource> <method> --params '{...}' --json '{...}'`

## 常用指令

### Tasks
```bash
gws tasks tasklists list                                                    # 列出所有清單
gws tasks tasks list --params '{"tasklist": "<tasklistId>"}'               # 列出清單內的任務
gws tasks tasks get --params '{"tasklist": "<tasklistId>", "task": "<taskId>"}' # 取得任務詳細
gws tasks tasks insert --params '{"tasklist": "MDU4Nzc0ODY3NzY1OTg2NDcyMTY6MDow"}' --json '{"title": "標題", "notes": "備註"}'  # 新增任務（預設清單）
gws tasks tasks patch --params '{"tasklist": "<tasklistId>", "task": "<taskId>"}' --json '{"status": "completed"}'  # 標記完成
gws tasks tasks patch --params '{"tasklist": "<tasklistId>", "task": "<taskId>"}' --json '{"title": "新標題"}'  # 更新任務
```

### 已知 Task List ID

> ⚠️ **新增任務不指定清單時，必須用下方 ID，禁止猜測或動態查詢**
> 2026-07-03 校正：曾長期只記錄 1 個清單，實際帳號已有 8 個。用 `gws tasks tasklists list` 可隨時重新核對，發現新清單就補進這張表，不要讓文件再度漂移。

| 清單名稱（web 顯示） | API 標題 | ID | 用途 |
|------|------|-----|------|
| **待辦事項（主）← 預設** | 待辦事項 | `MDU4Nzc0ODY3NzY1OTg2NDcyMTY6MDow` | 一般待辦、無明確分類的任務 |
| 購物清單 | 購物清單 | `TWRKUjBKVWFTdV9UVVVVLQ` | 購買/待買類 |
| #專案 @購物 SOP 開發 | #專案 @購物 SOP 開發 | `NWd0OTJhQ3RHWGlvaU1Tbw` | 特定專案任務，非內容分類清單 |
| Podcast 清單 | Podcast 清單 | `czl6RGYwTnpmYTFiTVc0RQ` | Podcast 類作品 |
| 📚 讀書清單 | 讀書清單 | `V3doMW9RRG5uQmdxVGJ5dg` | 書籍/書單類作品 |
| 觀影清單 | 觀影清單 | `TldtbUNiR2JvMmN0Z19TZQ` | 電影/影集/動畫類作品 |
| 🎓 女書店2026 | 女書店2026 | `OFk1RmNsRThMbkJWc0E4OA` | 特定課程系列專案，非通用清單 |
| 🎧 待聽清單 | 待聽清單 | `VE1URGRWLTE4QW50Vng2Rw` | 音樂/歌單/專輯類作品（2026-07-03 新建，補上原本音樂沒地方去的缺口） |

### Tasks 命名慣例

**強制格式：`Emoji 動詞 名詞 #標籤1 #標籤2`**
- Emoji：1 個，反映任務性質
- 動詞：查、買、寫、整理、確認、拍攝、聯絡…等，放在最前
- 名詞：任務對象，盡量簡短
- 標籤：**恰好 2 個**，第一個是領域（#工作 #生活 #日常 #娛樂），第二個是子類（#財務 #行政 #內容 #健康 #外出…）

範例：
- `🎬 上片 洗地機影片 #工作 #YouTube`
- `🛒 下單 IKEA 收納盒 #生活 #採購`
- `💰 核對 Amazon 款項 #生活 #財務`
- `📄 拿 老家桌上文件 #日常 #行政`
- `✍️ 撰寫 施施議題 #工作 #內容`

**禁止**：
- 只有 1 個標籤
- 動詞後面加無關補語（如「避免遲繳」「不要忘了」）
- 標題過長（超過 20 字）

### Tasks 寫入後驗證流程（必做）

**每次 insert 新任務後，必須對該清單執行一次全列命名驗證並修正不合規的標題。**

步驟：
1. `gws tasks tasks list --params '{"tasklist": "<id>", "showCompleted": false}'` 列出該清單所有未完成任務
2. 對每個任務的 `title` 檢查：
   - ✅ 開頭有 Emoji
   - ✅ 有動詞（查/買/寫/整理/確認/拍攝/聯絡/看/完成/下單/上片 等）
   - ✅ 恰好 2 個 `#標籤`
   - ✅ 總長 ≤ 20 字
3. 不合規的 → 改寫後 `gws tasks tasks patch` 更新
4. 回報：「已修正 N 筆，清單現在全部符合格式」

**例外**：`[MUBI]` 等平台前綴屬使用者刻意保留，不視為不合規。**capture skill 自動寫入觀影/讀書/Podcast/待聽等清單的新項目一律套本命名慣例**（沒有例外）；這條例外只適用於「批量回頭修正這些清單裡既有的舊項目」——要不要把舊資料也改到符合格式，由使用者自行決定，跑驗證前先確認範圍。

### Gmail
```bash
gws gmail users messages list --params '{"userId": "me", "q": "newer_than:7d", "maxResults": 10}'  # 搜尋最近 7 天
gws gmail users messages list --params '{"userId": "me", "q": "in:inbox from:xxx", "maxResults": 20}'  # 搜尋特定寄件人
gws gmail users messages get --params '{"userId": "me", "id": "<messageId>"}'  # 讀取信件內容
gws gmail users messages send --params '{"userId": "me"}' --json '{"raw": "<base64>"}'  # 發信
```

> ⚠️ **yourchannel2 帳號 Gmail 搜尋不可用（2026-07-05 實測）**：現行 yourchannel2 OAuth token 只有 metadata scope，`messages list` 帶 `q` 參數直接回 403「Metadata scope does not support 'q' parameter」。不帶 `q` 的列表可用（同日實測 `labelIds` 過濾 OK，注意 **labelIds 要傳字串不是陣列**：`"labelIds": "INBOX"`，傳 `["INBOX"]` 回 400 Invalid label）。要恢復關鍵字搜尋需重新 `gws auth login` 授權 gmail readonly/full scope，不要重試 `q` 硬撞。

### Calendar
```bash
gws calendar events list --params '{"calendarId": "primary", "timeMin": "<iso>", "timeMax": "<iso>"}'  # 列出事件
gws calendar events insert --params '{"calendarId": "primary"}' --json '{"summary": "標題", "start": {"dateTime": "<iso>"}, "end": {"dateTime": "<iso>"}}'  # 建事件
```

### Sheets
```bash
gws sheets spreadsheets values get --params '{"spreadsheetId": "<sheetId>", "range": "Tab!A1:D10"}'  # 讀取
gws sheets spreadsheets values update --params '{"spreadsheetId": "<sheetId>", "range": "Tab!A1:B2", "valueInputOption": "USER_ENTERED"}' --json '{"values": [["A","B"]]}'  # 更新
gws sheets spreadsheets values append --params '{"spreadsheetId": "<sheetId>", "range": "Tab!A:Z", "valueInputOption": "USER_ENTERED"}' --json '{"values": [["新列col1","col2","col3"]]}'  # 新增列
```

**寫入 sheet 一律走 gws**：禁止手刻 keychain → `oauth2.googleapis.com/token` → `sheets.googleapis.com/v4/...:append` 這條 raw API 路徑。OAuth 已完成在本機 token，gws 自動處理 refresh，一行 done。

### Drive
```bash
gws drive files list --params '{"q": "name contains '\''keyword'\''", "pageSize": 10}'  # 搜尋檔案
gws drive files get --params '{"fileId": "<fileId>"}'  # 取得檔案 metadata
```

### People (Contacts)
```bash
gws people people connections list --params '{"resourceName": "people/me", "pageSize": 20, "personFields": "names,emailAddresses,phoneNumbers"}'  # 列出聯絡人
```

### Docs
```bash
gws docs documents get --params '{"documentId": "<docId>"}'  # 讀取文件
```

**產「有格式」的 Google Doc（標題/表格/粗體）→ 走 HTML 兩段式**（`files create --upload` 帶 mimeType 會 400；`docs +write` 只能純文字 append）：
```bash
gws drive +upload doc.html                                    # 1) 上傳 HTML，拿 fileId
gws drive files copy --params '{"fileId":"<id>"}' \
  --json '{"name":"標題","mimeType":"application/vnd.google-apps.document"}'  # 2) 轉成真 Doc
gws drive files delete --params '{"fileId":"<htmlId>"}'       # 3) 清中繼 HTML（進垃圾桶）
# Doc 連結：https://docs.google.com/document/d/<newId>/edit
```

**在「已存在」的 Doc 尾端 append 有格式內容（標題/bullet）→ 走 `docs documents batchUpdate`**（2026-07-04 驗證可行；HTML 兩段式只適合建新 Doc，不適合對既有 Doc 追加）：
1. `gws docs documents get --params '{"documentId": "<id>"}'` 讀出 `body.content`，找最後一個 paragraph 的 `endIndex`（記為 `E`）——插入點用 `E - 1`（該段落結尾的換行字元之前，UTF-16 code unit 計數；純 BMP 中日文字/全形符號每字 1 unit，若內容含 emoji/罕見字才需留意 surrogate pair）。
2. 組一個字串：`"\n" + "\n".join([段落1文字, 段落2文字, ...])`（開頭一個 `\n` 收掉前一段，段落間用 `\n` 分隔，**結尾不要再加 `\n`**——原文件最後那個換行字元會自動接住最後一段）。
3. 依序算出插入後每個新段落的 `[start, end)`（第一段落 start = `E`，之後每段 `end = start + len(text)`，下一段 `start = end + 1`）。
4. 組 `requests` 陣列，一次 batchUpdate 送出：
   - `{"insertText": {"location": {"index": E-1}, "text": "<整段組好的字串>"}}`
   - 每個要當標題的段落：`{"updateParagraphStyle": {"range": {"startIndex": s, "endIndex": e}, "paragraphStyle": {"namedStyleType": "HEADING_2"}, "fields": "namedStyleType"}}`（標題層級對照既有文件慣例，例如本文件用 HEADING_2 分區）
   - 每個要當 bullet 的段落：`{"createParagraphBullets": {"range": {"startIndex": s, "endIndex": e}, "bulletPreset": "BULLET_DISC_CIRCLE_SQUARE"}}`
5. 送出：`gws docs documents batchUpdate --params '{"documentId": "<id>"}' --json '{"requests": [...]}'`
6. 完成後重新 `docs documents get` 核對新段落確實落在文件尾端、既有內容未被覆蓋。

> 索引一律用「插入前」文件狀態算好整批 requests 再一次送出（單一 batchUpdate 內的 insertText 只會執行一次，後續的 updateParagraphStyle/createParagraphBullets 用的是插入後的新索引，不用擔心多次請求互相位移）。

## 注意事項
- 認證已完成（`gws auth login --account user2@example.com`），token 加密存放自動 refresh
- 發信或建事件前先確認
- `--format table` 可切換表格輸出
- `--dry-run` 可預覽不送出
- 預設帳號：user2@example.com

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
