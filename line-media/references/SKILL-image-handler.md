# SKILL-image-handler.md
# 龍蝦圖片處理規則（LB-005R / Route C）

## 1. 觸發條件

當用戶傳送圖片訊息時觸發（LINE event type: message, message.type: image）。

## 2. 批次多圖處理規範（Batch Mode）

當系統在一秒內或同一個 webhook 輪次中收到多張圖片時，必須採取合併處理策略以優化使用者體驗。

### 2a. ACK 抑制與合併回覆
- 禁止針對每張圖片發送獨立的 `[[buttons:]]` 或 `[[quick_replies:]]`。
- **規則**：偵測到多圖連發時，僅在最後一張圖片收到後發送一則整體的 ACK 卡片。
- **卡片內容**：標記為「收到一組圖片（N張）」，並提供「整體分析」按鈕。

### 2b. 批次 Vision 分析
- **流程**：在背景將該組所有圖片路徑打包，一次性發送給 Vision 模型進行「場景綜覽（Scene Overview）」分析。
- **目標**：理解這組圖片整體的時空背景、主題與關聯性（例如：同一路口的四個視角、同一份文件的不同分頁）。

### 2c. 整體回覆與細節引導
- **回覆方式**：先給出整體判斷（例如：「這是一組在高雄五福一路路口的街景照片」）。
- **後續動作**：詢問是否需要針對其中某張特定圖片進行處理（如 OCR 或存入筆記），避免無意義的重覆動作。

## 3. 圖片回溯機制

**問題：** postback 是新的對話輪次，原圖片不一定還在 context。

**解法：** 收到圖片的當下，立刻把 LINE message_id 存到暫存檔：
```
/tmp/line-last-image.json
格式：{"messageId": "XXXXXXXX", "ts": 1234567890}
```

之後收到 postback 時，從暫存檔讀取 messageId，用 LINE Content API 重新下載：

```bash
# 注意：以下三行必須在同一個 bash 呼叫中執行（TOKEN 變數不跨 tool call 保留）
TOKEN=$(cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; print(json.load(sys.stdin)['channels']['line']['channelAccessToken'])")
MSG_ID=$(cat /tmp/line-last-image.json | python3 -c "import json,sys; print(json.load(sys.stdin)['messageId'])")
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api-data.line.me/v2/bot/message/$MSG_ID/content" \
  -o /tmp/line-current-image.jpg
```

然後用 image 工具分析 /tmp/line-current-image.jpg。

**注意：** LINE 圖片內容在 webhook 後約 30 分鐘內有效，需在此時間內完成處理。

## 4. 步驟 1：收到圖片後，詢問使用者意圖

收到圖片時，不要自動分析。先用 [[quick_replies:]] 詢問使用者想做什麼：

收到圖片，分析中...
[[quick_replies: 分析內容:imageAnalyze, OCR文字:imageOCR, 生成類似圖:imageGen, 隨便看看:imageBrowse]]

圖片路徑已在 /tmp/openclaw/（OpenClaw 自動下載）。
等用戶按按鈕觸發 postback 後，再根據 action 執行對應處理。

### 4a. 先存 messageId
```bash
echo '{"messageId":"IMAGE_MESSAGE_ID","ts":'$(date +%s)'}' > /tmp/line-last-image.json
```

### 按鈕組依圖片來源決定（優先判斷）

**判斷方式：** 分析圖片時，如果 Claude vision 描述中出現以下特徵，視為 AI 生成圖：
- 風格高度一致的插畫質感。
- 不自然的光影（如：發光特效、螢光粒子、異常絢爛的色彩）。
- 電影海報或藝術插畫構圖，但畫面細節過於完美或比例過於理想。

**1. AI 生成圖 → 配置「創作導向」按鈕組：**
- 按鈕 A：label: "換個風格", displayText: "換個風格", data: action=restyle&prompt={原始 prompt 或主題描述}
- 按鈕 B：label: "再生一張", displayText: "再生一張", data: action=regen&prompt={同上}

**2. 真實照片 → 根據圖片內容自行判斷最合適的兩個動作按鈕。**
讓 AI 依分析結果決定，不硬性規定。

**規格要求：**
- 所有按鈕 displayText 必須嚴格等於 label。

## 5. 步驟 2：收到 postback 後處理

### 共同第一步（所有 action 皆適用，**除 imageGen 外**）

立刻發純文字：「⏳ 處理中...」（沿用 LB-002R-fix 即時回覆規則）

> ⚠️ **imageGen 例外**：零 Push 設計，**不發「處理中」ack**（reply token 一次性、撐不到 codex 生圖完成），直接背景執行、結果走 pending-result 等下一則訊息 reply。見下方 imageGen handler。

然後下載圖片（TOKEN + curl 必須在同一個 bash 呼叫中執行）：
```bash
TOKEN=$(cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; print(json.load(sys.stdin)['channels']['line']['channelAccessToken'])")
MSG_ID=$(cat /tmp/line-last-image.json | python3 -c "import json,sys; print(json.load(sys.stdin)['messageId'])")
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api-data.line.me/v2/bot/message/$MSG_ID/content" \
  -o /tmp/line-current-image.jpg
```

然後使用 image 工具分析圖片，再根據 action 類型處理。

---

### action: imageOCR

1. 下載圖片後，用 image 工具：
   - prompt：「請提取這張圖片中的所有文字，保留原始段落格式，不要加任何說明。」

2. 用 info-card.json 回覆：
   - TAG: OCR 結果, TAG_COLOR: #06C755（green）
   - TITLE: 文字辨識完成
   - BODY: {{提取的文字（超過 100 字裁到 100 字並加...）}}
   - 按鈕: 💬 以此提問 → postback: {"action":"imageChat","preview":"(前30字)"}

3. curl 指令模板：
```bash
curl -X POST https://api.line.me/v2/bot/message/push \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "to": "GROUP_ID",
    "messages": [{
      "type": "flex", "altText": "OCR 結果",
      "contents": {
        "type": "bubble",
        "header": {
          "type": "box", "layout": "vertical", "backgroundColor": "#F0FDF4",
          "contents": [
            {"type": "text", "text": "OCR 結果", "size": "xs", "color": "#06C755", "weight": "bold"},
            {"type": "text", "text": "文字辨識完成", "size": "md", "weight": "bold", "color": "#111111"}
          ]
        },
        "body": {
          "type": "box", "layout": "vertical",
          "contents": [
            {"type": "text", "text": "OCR_TEXT_HERE", "wrap": true, "size": "sm", "color": "#444444"}
          ]
        },
        "footer": {
          "type": "box", "layout": "vertical",
          "contents": [{
            "type": "button", "style": "primary", "color": "#06C755", "height": "sm",
            "action": {"type": "postback", "label": "💬 以此提問", "data": "{\"action\":\"imageChat\",\"preview\":\"PREVIEW_30_CHARS\"}"}
          }]
        }
      }
    }]
  }'
```

---

### action: imageAnalyze

1. 用 image 工具：
   - prompt：「請用繁體中文詳細描述這張圖片的內容。」

2. 用 ai-reply.json 樣式回覆：
   - TAG: 💬 圖片分析, TAG_COLOR: #2563EB（blue）
   - TITLE: (圖片主要主題，前 15 字)
   - BODY: {{詳細描述}}

3. 把分析結果記入 context，支援後續追問。

---

### action: imageTranslate

1. 先做 OCR 提取文字（同 imageOCR prompt）
2. 偵測語言（根據 OCR 結果判斷）
3. 翻譯成繁體中文

4. 用 info-card.json 回覆：
   - TAG: 翻譯結果, TAG_COLOR: #7C3AED（purple）
   - TITLE: 翻譯完成
   - 資訊列: 原始語言: {{偵測到的語言}}
   - BODY: {{翻譯後的文字}}

---

### action: imageChat

當用戶點「以此提問」後：
- 把 OCR 結果或圖片分析結果當成 context
- 進入一般對話模式，等待用戶問題
- 純文字回覆：「請問你想了解什麼？我已讀取了圖片內容。」

---

### action: imageGen（風格化生圖 · 長任務 — 必須背景執行）

> 升級（2026-06-15）：改用 codex-image，**吃使用者上傳圖當 style reference**（真風格類似，非純文生圖）。引擎 `scripts/line-stylegen.sh`。

⚠️ 生圖是長任務（codex 約 20-40 秒 + Drive 上傳），必須用 exec(background=true)，不可同步等待。

步驟：
1. **不發 ack**（零 Push 設計：reply token 一次性、撐不到生圖完成，留給下一則訊息送結果）。
2. 用 exec(background=true) 執行：
```bash
USER_PROMPT="<使用者的風格描述，若無則留空>" \
bash ~/life-os/scripts/line-stylegen.sh
```
（腳本自己讀 `/tmp/line-last-image.json` 的 messageId 下載參考圖，不需傳路徑/GROUP_ID。）
3. 立刻回到對話（不等待結果）。
4. 腳本完成後**不主動推播**——把結果寫進 `pending-result`（type=text_link，caption 含 Drive 連結）。

**零 Push 交付**：由**下一則使用者訊息**攜帶的新 reply token，把 pending-result 的 caption 當**純文字 reply**（內含 Drive 連結）送出。詳見 line-output 的 text_link 規則。

**⚠️ 紅線**：本流程**禁用 Push**。reply token 過期就 hold 等下一則訊息，不得 fallback 到 Push API（違反 reply-only 紅線）。Drive 分享連結非直連圖，**不要**走 [[media_player:]]，只回文字連結。

---

## 6. 常數與路徑

LINE Token: 從 ~/.openclaw/openclaw.json 讀取
圖片暫存: /tmp/line-last-image.json（messageId）
圖片下載: /tmp/line-current-image.jpg
LINE Content API: https://api-data.line.me/v2/bot/message/{messageId}/content
主對話群組: <LINE_GROUP_ID>

## 7. 已知限制

- LINE 圖片有效期約 30 分鐘，超時無法重新下載
- Flex bubble body 文字有長度限制，OCR 結果超過需截斷
- /tmp 暫存只保存最後一張圖片，多圖同時處理會覆蓋（目前 MVP 不處理此情境）

## 輸出規則（強制）

收到圖片 → 用 [[quick_replies:]] 詢問意圖（不自動分析）→ 等 postback → 執行對應動作。
禁止純文字直接回覆分析結果。

長任務 → 必須 exec(background=true)，對話不阻塞。交付依各 handler contract：
- **imageGen（風格化生圖）禁 push**——腳本寫 pending-result（type=text_link），由下一則訊息 reply token 送 Drive 連結（零 Push 紅線）。
- 其他既有長任務（舊式 TTS 等）沿用原推播約定。
