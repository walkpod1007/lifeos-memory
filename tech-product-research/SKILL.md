---
name: tech-product-research
version: 1.0.0
description: 科技產品多語系評測搜集，整理成 Google Doc 交付。觸發：幫我搜集 X 評測、查 X 開箱、X 跟 Y 比較＋具體產品名
---

# tech-product-research — 科技產品多語系評測搜集

> 來源：worktickets/2026-06-22-tech-product-research-skill-draft.md（2026-06-22 實跑 RayNeo X3 Pro 驗證過的流程蒸餾）

## 執行 SOP

### Step 1 — 解析輸入

從使用者訊息取出：
- `product`：目標產品（如 RayNeo X3 Pro）
- `competitors`：對比產品（如 Rokid Max 2），可選
- `regions`：台灣 / 日本 / 歐美（預設三區）
- `output`：Google Doc（預設）/ LINE / 兩者

### Step 2 — 平行搜尋（三區 + 對比，一次發齊不串行）

```
1. "{product} 開箱 評測 台灣 {當前年份}"
2. "{product} unboxing review english {當前年份}"
3. "{product} 開封 レビュー 日本 {當前年份}"
4. "{product} vs {competitor} comparison review {當前年份}"（如有競品）
```

### Step 3 — 整理資料

```
產品規格
  • 顯示 / 重量 / 處理器 / AI / 電池 / 價格 / 地區認證

台灣評測
  序號. 來源｜標題
  URL
  一句摘要

日本評測（同上）
歐美評測（同上）

競品比較表
  項目 | {product} | {competitor}

NotebookLM 建議（列出 YouTube URL 讓使用者直接丟入）
```

媒體標題適用台灣譯名規則（Rule 0）；產品名保留原文。

### Step 4 — 建立 Google Doc

```bash
DOC_ID=$(gws docs documents create --json '{"title": "{product} 開箱評測整合報告 + {competitor} 比較"}' | jq -r .documentId)
gws docs +write --document "$DOC_ID" --text "$CONTENT"
echo "https://docs.google.com/document/d/$DOC_ID/edit"
```

內容用純文字＋`+write`（不用 batchUpdate API）。

### Step 5 — 回傳 URL

1. 有可用 reply_token → reply（優先）
2. reply_token 過期 → push
3. push 429 → 不重試，直接在對話印出 URL 告知使用者

### Step 6 — NotebookLM（可選）

使用者說「丟進 NotebookLM」→ 觸發 `notebooklm` / `notebooklm-save` skill，把搜到的 YouTube URL 當 sources 加入。

## 注意事項（實跑踩過的坑）

- 搜尋年份帶當前年度，避免撈舊資料
- 三區搜尋**平行發出**，不要串行
- push 月度配額有限：優先 reply；429 不重試
- reply 工具參數是 `text` 字串，不是 `messages` 陣列
- Tier 1 channel 不可寫 skills/；本 skill 的修改只在 Tier 0（LINE DM / termi / Desktop App）做

## 實跑記錄

- 2026-06-22 RayNeo X3 Pro vs Rokid Max 2：台灣 3 篇＋日本 4 篇＋歐美 6 篇＋比較表，Doc 交付成功
