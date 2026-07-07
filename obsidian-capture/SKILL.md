---
name: obsidian-capture
description: 快速把想法、筆記、內容存進 Obsidian Vault，自動歸類到正確資料夾。使用時機：記一下、記到 obsidian、新增筆記、存到 vault、把這個記起來、寫進筆記。不確定放哪先進 Inbox。
---

# Obsidian Capture

## Overview

快速存進 Vault，不讓好東西消失在對話裡。用 `obsidian-cli` 操作。

## Vault 路徑

```
$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/
```

## 內容 → 資料夾對應

| 內容類型 | 存到 |
|----------|------|
| 隨手想法、靈感 | `00_Inbox/` |
| 工作任務 | `10_Projects/` |
| 學習、知識 | `30_Knowledge/` |
| 研究、收集 | `50_Research/` |
| 日記 | `20_Areas/diary/` |
| URL 捕捉 | `50_Research/captures/` |

不確定放哪 → 一律先進 `00_Inbox/`。

## 建立筆記

```bash
# 丟到 Inbox（最快）
obsidian-cli create "00_Inbox/$(date +%Y%m%d-%H%M)-標題" --content "內容"

# 直接歸類
obsidian-cli create "30_Knowledge/主題/標題" --content "# 標題

內容"

# 帶 frontmatter
obsidian-cli create "路徑/標題" --content "---
date: $(date +%Y-%m-%d)
tags: [標籤]
---

內容"
```

## 搜尋

```bash
obsidian-cli search "關鍵字"          # 搜標題
obsidian-cli search-content "關鍵字"  # 搜內容
```

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
