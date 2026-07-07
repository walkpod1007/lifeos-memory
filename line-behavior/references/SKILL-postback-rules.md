# SKILL-postback-rules.md
# 龍蝦 LINE 回應通用規則

---

## ⛔ 媒體 Intent-First 總則（最高優先）

收到圖片 / 語音 / 文件 / 影片 → reply **只能**是 [[buttons:]]，兩個選項，不加任何其他文字。
不說「收到」、不說大小、不預覽、不自動處理。發完就停，等 postback。

| 媒體類型 | 固定兩選 |
|---------|---------|
| 圖片 | 🔍 分析內容:imageAnalyze, 🎨 生成類似圖:imageGen |
| 語音 | 💬 直接回覆:sttReply, 📝 存筆記:toNote |
| 文件 | 📝 摘要重點:fileSummary, 💾 存到雲端:fileDrive |

---

**即時回應原則（文字訊息適用）：任何預期超過 3 秒的操作，第一個動作是發 ack 訊息告知用戶正在處理。ack 發出之前不做任何準備工作。**

---

## 適用場景

| 操作類型 | ack 訊息範例 |
|----------|-------------|
| AI 生圖 | 🎨 生成中，約 10-15 秒... |
| 語音轉文字 | 🎙️ 處理中... |
| 圖片 OCR / 分析 | 🔍 分析中... |
| 派工給阿普（Claude Code） | ⚙️ 已派工，處理中... |
| 搜尋 / 查資料 | 🔎 查詢中... |

## 執行順序

> ⚠️ **例外：`imageGen`（風格化生圖）不適用本 ack/push 通則。** imageGen 走零 Push——**不得 push ack**，只背景執行 line-stylegen.sh，結果寫 pending-result（type=text_link），由下一則使用者訊息的 reply token 送出。詳見圖片 postback 表與 line-output。

1. 收到請求 → **立刻 push ack**（目標 < 1 秒）
2. 做準備工作（找腳本、查 key、翻檔案）
3. 執行主要操作
4. 回傳結果

## 違反此原則的後果

- 用戶看到 6 分鐘沉默，以為沒收到請求
- 用戶重複傳送，觸發重複執行
- 體驗差，信任降低

## 備註

- ack 用 LINE push API 送出（不依賴 replyToken，replyToken 有 30 秒限制）
- ack 純文字即可，不需要 Flex 卡
- 若操作 < 3 秒可直接回結果，不需 ack

---

*最後更新：2026-02-22（LB-009R-fix）*

---

## WO-024 Intent-First Postback 路由

### 圖片 postback
| action | 處理方式 |
|--------|---------|
| imageAnalyze | 讀 /tmp 圖片 → vision 全面分析 → reply [[buttons:]] 結果 |
| imageOCR | 讀 /tmp 圖片 → vision OCR → reply 純文字 |
| imageGen | 讀 /tmp 圖片 → 風格化生圖（line-stylegen.sh：吃參考圖當 style reference、codex-image 生成、Drive 連結交付、零 Push） |
| guessLocation | 讀 /tmp 圖片 → vision 猜地點 → reply 純文字 |

### 語音 postback
| action | 處理方式 |
|--------|---------|
| sttReply | 讀 /tmp/line-last-stt.json → 直接回應內容 |
| toNote | 讀 /tmp/line-last-stt.json → 存 Apple Notes（osascript，4s timeout）→ 失敗則存 /tmp/pending-notes/ → reply 確認 |
| sttSummary | 讀 /tmp/line-last-stt.json → 摘要重點 → reply |

### 找不到暫存檔時
回覆：「還在處理，請稍等一下後重試。」
