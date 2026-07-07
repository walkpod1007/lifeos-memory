# Obsidian Note Template

## 檔案路徑
```
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
$VAULT/00_Inbox/📌_Quick_Refs/YYYY-MM-DD-正規化標題.md
```

## Frontmatter

```yaml
---
source: threads          # 平台 ID（threads/x/instagram/facebook/dcard/ptt/zhihu/reddit/article/youtube）
platform: Threads        # 平台顯示名稱
url: https://...         # 原始 URL
author: "@username"      # 作者（社群平台）或網站名（文章）
date: 2026-03-24         # 內容發布日期
captured: 2026-03-24T17:00:00+08:00  # 捕捉時間
interactions:            # 社群互動數（有的話）
  likes: 0
  comments: 0
  shares: 0
tags:
  - AI生成tag1           # 主題分類
  - AI生成tag2           # 內容性質
  - AI生成tag3           # 具體關鍵字
status: inbox
---
```

## 內文

```markdown
## 摘要

（深度摘要 800-1200 字，涵蓋主要論點、背景脈絡、關鍵細節）

## 留言精華

（社群平台才有，挑選最有代表性的 3-5 則）

- **留言者A**（讚數）：內容摘要
- **留言者B**（讚數）：內容摘要

## 圖片描述

（如有需要分析的圖片，描述圖片內容）

- [1] 描述...

## 原文

（完整原文，保留原始格式，不改寫）
```

## Tag 生成規則

AI 自動生成 3 個語意 tag：
1. **主題分類**（如：AI工具、感情、科技、投資、電影）
2. **內容性質**（如：教學、心得、討論、新聞、評論）
3. **具體關鍵字**（如：Claude、免費模型、心靈捕手）

Tag 用繁體中文，不加 `#` 前綴。

## 正規化標題規則

- 繁體中文
- 去除標點符號和特殊字元
- 適合搜尋和索引
- 長度 10-30 字
- 格式：核心主題-補充描述
- 範例：`OpenClaw新手配置攻略免費模型`、`心靈捕手電影筆記`
