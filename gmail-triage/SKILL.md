---
name: gmail-triage
description: 整理 Gmail 郵件未讀信件，找出需要行動的，分類優先級。使用時機：郵件、email、Gmail、看信、信件整理、未讀信、有沒有重要信件、信箱整理、mail check、收件匣。高頻問題「錢到了沒」「貨出了沒」相關信件優先標出。
---

# Gmail Triage

## Overview

掃未讀信，找要動的，其他略過。用 `gog` CLI 查 Gmail。

## 執行流程

```bash
# 搜尋未讀信（最近 3 天）
gog gmail search 'is:unread newer_than:3d' --max 20

# 讀特定信件內容
gog gmail messages search 'is:unread from:<sender>' --max 5
```

## 分類邏輯

| 優先級 | 判斷標準 | 標記 |
|--------|----------|------|
| 🔴 立刻處理 | 客戶信、有問句、要求行動、錢/貨相關 | 今天回 |
| 🟡 今天看 | 帳單、出貨通知、重要夥伴 | 知道即可 |
| ⚪ 略過 | 電子報、廣告、自動通知 | 統計數字 |

## 輸出格式

```
📧 信件整理 YYYY-MM-DD
共 N 封未讀

🔴 需要回覆（N 封）
• [寄件人] 主旨
  → 要做什麼（一句話）

🟡 需要知道（N 封）
• [寄件人] 主旨 — 重點

⚪ 可略過：N 封
```

## 注意

- 「錢到了沒」「貨出了沒」相關信件一律 🔴
- 電子報只計數，不逐一列出
- 提行動建議，不幫忙寫回信

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
