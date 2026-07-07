# SKILL-file-handler.md
# 工單：LB-006R 文件處理
# 用途：定義龍蝦收到文件時的完整處理行為

---

## 支援格式

| 格式 | 提取方式 | 備註 |
|------|----------|------|
| PDF | pdftotext / pymupdf | 掃描檔用 vision 看 |
| DOCX | docx2txt | 不支援舊版 .doc |
| XLSX/XLS | openpyxl | 多 sheet 全部提取 |
| TXT/MD/CSV/TSV/LOG/JSON | 直接讀取 | UTF-8 優先，失敗偵測編碼 |

---

## 來源一：LINE 直傳

收到 type: "file" 的 webhook 時：

### Step 1：發 [[quick_replies:]]（三選項，走 Reply API）

**⛔ 強制規則：reply 只能是以下格式，禁止加任何其他文字**
**⛔ 禁止：說檔名、說格式、說大小、預覽內容、自動讀取**
**⛔ 發完就停，等 postback，不做任何處理**

收到文件，下載中...
[[quick_replies: 讀取內容:fileRead, 摘要重點:fileSummary, 存到雲端:fileSave]]

根據檔案類型調整前置文字（quick_replies 選項不變）：
- Excel / CSV → 「收到 Excel，下載中...」
- PDF → 「收到 PDF，下載中...」
- DOCX → 「收到 Word 文件，下載中...」
- 其他 → 「收到文件，下載中...」

**為什麼這樣設計：**
- reply token 有效期約 60 秒，只能用一次批次（最多 5 則）
- ACK 先送出，用戶回覆後產生新 reply token → 摘要結果搭那個 token 送出
- 這是「conversational ACK」模式：ACK 邀請對話，結果在下一輪送

⚠️ ack 發出之前不做任何其他工作

### Step 2：下載檔案
```
curl -H "Authorization: Bearer $TOKEN" \
  -o /tmp/{fileName} \
  "https://api-data.line.me/v2/bot/message/{messageId}/content"
```
⚠️ 注意是 api-data.line.me 不是 api.line.me
⚠️ LINE 檔案內容會過期（約 7 天），收到 webhook 後必須立刻下載

### Step 3：提取文字
```
./file-extract.sh /tmp/{fileName}
```

### Step 4：預設行為（SPEC-002）

**PDF 預設行為（用戶沒說話時）：**
1. **自動生成中文摘要**（不等用戶選擇）：
   - prompt：「請用繁體中文摘要這份文件的重點，條列 3-5 項，每項一句話，總字數不超過 300 字。」

2. **暫存 `/tmp/line-last-file.json`**（供後續 postback 引用）：
   ```bash
   # 儲存摘要、路徑、檔名等資訊，key 為 messageId
   cat > /tmp/line-last-file.json <<EOF
   {
     "msg_id": "MSG_ID",
     "file_path": "/tmp/FNAME",
     "filename": "FNAME",
     "filetype": "EXT",
     "summary": "SUMMARY"
   }
   EOF
   ```

3. **回覆 Flex Bubble 卡片**（含摘要 + 三個按鈕）：
   - header：檔案名稱 + 檔案類型圖示
     - 📄 PDF、📊 Excel（xlsx/xls）、📝 Word（docx）、📃 其他
   - body：
     - 摘要文字（300字以內，重點條列）
     - 頁數/字數（若可取得）
   - footer：三個 postback 按鈕
     1. **存 Google Doc**
        - action type: postback
        - data: `action=save_doc&file_id={MSG_ID}`
        - displayText: 存 Google Doc
     2. **深度摘要**
        - action type: postback
        - data: `action=deep_summary&file_id={MSG_ID}`
        - displayText: 深度摘要
     3. **完成**
        - action type: postback
        - data: `action=dismiss`
        - displayText: 完成

   Flex JSON 範本：
   ```json
   {
     "type": "bubble",
     "header": {
       "type": "box",
       "layout": "horizontal",
       "contents": [
         {
           "type": "text",
           "text": "{FILE_ICON} {FILENAME}",
           "weight": "bold",
           "size": "md",
           "wrap": true
         }
       ]
     },
     "body": {
       "type": "box",
       "layout": "vertical",
       "contents": [
         {
           "type": "text",
           "text": "{SUMMARY}",
           "wrap": true,
           "size": "sm"
         },
         {
           "type": "text",
           "text": "{META}",
           "wrap": true,
           "size": "xs",
           "color": "#888888",
           "margin": "sm"
         }
       ]
     },
     "footer": {
       "type": "box",
       "layout": "vertical",
       "spacing": "sm",
       "contents": [
         {
           "type": "button",
           "style": "primary",
           "height": "sm",
           "action": {
             "type": "postback",
             "label": "存 Google Doc",
             "data": "action=save_doc&file_id={MSG_ID}",
             "displayText": "存 Google Doc"
           }
         },
         {
           "type": "button",
           "style": "secondary",
           "height": "sm",
           "action": {
             "type": "postback",
             "label": "深度摘要",
             "data": "action=deep_summary&file_id={MSG_ID}",
             "displayText": "深度摘要"
           }
         },
         {
           "type": "button",
           "style": "secondary",
           "height": "sm",
           "action": {
             "type": "postback",
             "label": "完成",
             "data": "action=dismiss",
             "displayText": "完成"
           }
         }
       ]
     }
   }
   ```

**用戶傳檔案同時說了話**（如「幫我摘要這份報告」）→ 直接執行用戶指令（不走預設摘要流程）。

### Step 5：回覆結果
- 預設摘要：用 Reply API（有 REPLY_TOKEN）或 Push API 回覆 Flex Bubble 卡片（見 Step 4）
- 用戶指定任務：用 ai-reply 模板回覆對應結果

### Step 6：靜默備份（fire-and-forget）
```
gog drive upload /tmp/{fileName} 到對應資料夾：
- PDF/DOCX → 🦞 龍蝦系統/user-uploads/documents/
- XLSX/XLS → 🦞 龍蝦系統/user-uploads/documents/
- TXT/MD/CSV → 🦞 龍蝦系統/user-uploads/documents/
```

### Step 7：清理
```
rm /tmp/{fileName}
```

---

## 來源二：Google Drive

用戶說「幫我看 Drive 上的 XXX」或貼 Drive 連結時：

### Step 1：發 ack
「正在從 Drive 取得檔案...」

### Step 2：搜尋 / 下載
- 有 fileId 或連結 → `gog drive download {fileId}`
- 只有檔名描述 → `gog drive search "{關鍵字}"` → 找到後下載

### Step 3：後續流程同 LINE 直傳
提取 → 判斷意圖 → 回覆
⚠️ 不需要備份（檔案本來就在 Drive 上）

---

## 特殊情況

### 掃描版 PDF（純圖片）
- 判斷方式：pdftotext 輸出為空或幾乎為空
- 處理：改用 vision 逐頁辨識（與處理圖片相同）
- 回覆時告知：「這是掃描版 PDF，我用圖像辨識處理，可能有誤差」

### 檔案太大（文字超過 context 上限）
- 先提取全文，太長則只取前 N 頁 / 行
- 回覆：「這份文件很長（共 X 頁），我先看了前 Y 頁。需要我繼續看後面的嗎？」

### 不支援的格式
- 回覆：「目前支援 PDF、Word、Excel、純文字檔。這個格式（.xxx）我還處理不了，要不要轉成其中一種再傳給我？」

---

## 錯誤處理

| 錯誤 | 處理方式 |
|------|----------|
| 下載失敗（LINE 410 Gone） | 「這份檔案已經過期了，可以重新傳一次嗎？」|
| 提取失敗 | 「這份檔案我打不開，可能是加密或格式有問題」|
| 來源不可用 | 嘗試備用方法，全部失敗才回報 |

一律用 error 模板回覆。

---

## 快捷選項 Postback 處理（SPEC-002）

### 舊按鈕（docTranslate / docChat / docOutline）

收到 docTranslate / docChat / docOutline postback 時：

#### 共同第一步
1. 立刻發純文字 ack：「⏳ 處理中...」
2. 從 `/tmp/line-last-doc.json` 讀取先前暫存的文件內容

#### action: docTranslate
- 用暫存 `extractedText` 翻譯成繁體中文（若已是中文則翻英文）
- ai-reply 模板，TAG: 🌐 翻譯結果

#### action: docChat
- 純文字回覆：「請問你想了解這份文件的什麼？」
- 後續對話把 `extractedText` 作為 context

#### action: docOutline
- 產生文件大綱（各章節標題 + 一句話說明）
- ai-reply 模板，TAG: 📋 文件大綱

---

### 新按鈕 Postback 處理（WO-FILE-FLEX）

收到含 `action=save_doc` / `action=deep_summary` / `action=dismiss` 的 postback 時：

#### 共同第一步
1. 立刻發純文字 ack：「⏳ 處理中...」
2. 從 `/tmp/line-last-file.json` 讀取先前暫存的檔案資訊

#### action=save_doc
1. 從 `/tmp/line-last-file.json` 取得 `file_path` 和 `summary`
2. 建立 Google Doc：
   ```bash
   gog docs create --title "{filename} 摘要" --body "{summary}" --account user2@example.com
   ```
3. 設為 anyoneWithLink 分享：
   ```bash
   gog drive share --permission anyoneWithLink {DOC_ID}
   ```
4. Reply Flex Bubble 卡片：
   - header：「✅ 已存至 Google Drive」
   - body：文件標題
   - footer：一個連結按鈕「開啟文件 →」（uri action → Doc URL）

#### action=deep_summary
1. 從 `/tmp/line-last-file.json` 取得 `file_path`
2. 執行深度摘要：
   ```bash
   # 文件全文走 stdin，不塞進 argv（避免全文進 process list / 炸 ARG_MAX）
   { printf '直接輸出摘要本身，不要回「預覽」「確認」「待命」字串（非互動 headless）。請對以下文件做深度摘要，包含：主要論點、關鍵數據、結論建議，請用繁體中文條列，並附各節標題。\n\n'; cat {file_path}; } | codex exec --full-auto --sandbox read-only --ephemeral -
   ```
3. 將深度摘要結果建立 Google Doc：
   ```bash
   gog docs create --title "{filename} 深度摘要" --body "{deep_summary}" --account user2@example.com
   gog drive share --permission anyoneWithLink {DOC_ID}
   ```
4. Reply Flex Bubble 卡片：
   - header：「📋 深度摘要完成」
   - body：深度摘要前 200 字預覽
   - footer：一個連結按鈕「開啟完整摘要 →」（uri action → Doc URL）

#### action=dismiss
- 直接 Reply 純文字：「好的！有需要再說 🙌」

---

## 重要提醒

- 3 秒原則：ack 永遠第一個發，提取工作排在 ack 之後
- LINE Content API domain 是 api-data.line.me，不是 api.line.me
- LINE 檔案會過期（約 7 天），webhook 收到後必須立刻下載
- XLSX 要處理多 sheet，不能只讀第一個
- 掃描版 PDF 的 vision fallback 很重要，台灣很多文件是掃描的
- PDF 預設行為（SPEC-002）：不等用戶選擇，直接自動中文摘要 + 附快捷選項
- `/tmp/line-last-doc.json` 暫存 messageId、fileName、extractedText、summary（舊 docTranslate 等 postback 引用）
- `/tmp/line-last-file.json` 暫存 msg_id、file_path、filename、filetype、summary（新 save_doc / deep_summary / dismiss postback 引用）
- Flex 卡回覆優先用 Reply API（有 REPLY_TOKEN 時），否則用 Push API
- gog docs create 加上 `--account user2@example.com`
- 依賴：LB-007R（Drive）✅、LB-008R（Flex 模板）✅、SKILL-postback-rules.md ✅、WO-FILE-FLEX ✅
