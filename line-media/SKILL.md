---
name: line-media
description: 處理 LINE 收到的圖片/語音/影片/檔案。觸發：由 line-dispatcher 呼叫，message.type 為 image/audio/video/file/location
metadata: {"clawdbot":{"emoji":"🖼️"}}
---

# LINE 媒體訊息處理原則（line-media）

> 觸發時機：收到任何非文字的 LINE 訊息（圖片 / 語音 / 影片 / 檔案 / 位置 / 貼圖）

---

## 多圖緩衝（最高權重，每張圖都要判斷）

收到圖片時：
0. 第零步（強制）：30 秒內的圖視為同一批，一起看。超過 30 秒的舊圖視為過期不參考（OpenClaw 不自動清除圖片 context，行為層補償）。同時清除 30 秒前的暫存圖：
   find /tmp -name "line-media-*" -not -newermt "30 seconds ago" -delete 2>/dev/null
1. 檢查 context 裡最近 30 秒內有沒有其他圖片：
- 第一張 → 回一則 [[buttons:]]，不強調數量
- 後續圖片 → NO_REPLY（累積在 context）
- 使用者按 postback 或發文字 → 統一處理 context 裡所有圖片
- 不管幾張，一次分析完，不逐張回覆

違反此規則 = 浪費 token + 使用者體驗差。

---

## 核心原則

**媒體內容會過期。收到就要立刻下載，不能等。**

LINE 媒體內容在 webhook 後約 30 分鐘失效。每次收到媒體訊息，第一步是下載，第二步才是處理。

---

## 媒體下載 API

```
下載：curl -s -H "Authorization: Bearer $LINE_TOKEN" \
  "https://api-data.line.me/v2/bot/message/{messageId}/content" \
  -o /tmp/{filename}

LINE Token 取得：
grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env | cut -d= -f2
```

⚠️ domain 必須是 `api-data.line.me`（不是 api.line.me，那個只能查狀態）

---

## 各媒體類型能力邊界（概覽）

### 圖片（message.type: image）
- 能做：vision 分析、OCR、描述內容、存檔
- 收到時：只輸出一則 [[buttons:]]，不加前置文字
- 按鈕依圖片類型調整（截圖→分析/OCR，插畫→分析/生成/隨便看看）

### 語音（message.type: audio）
- 能做：STT 轉文字 → 回覆內容
- 完整流程見 skills/line-stt/SKILL.md（Whisper 路線）

### 影片（message.type: video）
- 能做：下載保存（需先查 transcoding 狀態）
- 目前無自動影片分析能力

### 檔案（message.type: file）
- 能做：PDF / DOCX / XLSX / TXT / CSV / JSON 擷取
- 工具：`bash ~/life-os/scripts/file-extract.sh /tmp/{filename}`
- 收到時：reply 只能用標準格式（見 references/SKILL-file-handler.md）

### 位置（message.type: location）
- 能做：地理查詢、生成 Google Maps URL、距離計算

### 貼圖（message.type: sticker）
- 能做：keywords 判讀使用者情緒意圖

---

## 處理決策原則

使用者傳媒體，通常是希望你**理解內容**，不是確認收到。

**3 秒原則**：任何媒體處理都超過 3 秒，先發 [[buttons:]] ack（真正 postback，非純文字）（走 Reply API，0 Push）。

---

## 完整參考文件（references/）

- `references/SKILL-voice-handler.md` — 語音 STT 完整流程
- `references/SKILL-image-handler.md` — 圖片 vision 完整流程
- `references/SKILL-file-handler.md` — 文件擷取完整流程
- `references/SKILL-media-persist.md` — 媒體沙盒限制解法
- `references/SKILL-postback-rules.md` — 3 秒 ack 規則

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
