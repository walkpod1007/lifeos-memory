---
name: session-end
description: Session 結束收尾流程：補尾段摘要 → 更新向量索引 → 寫 handoff.md → 判斷里程碑 → 自重啟。使用時機：要換 session、結束工作、/session-end、寫日檔。
---

# Session End

## Overview

換 session 前的標準收尾，確保記憶完整傳遞，然後自動重啟乾淨 session。

## 執行流程

1. 補尾段摘要
   `bash ~/life-os/scripts/realtime-summary.sh`

2. 更新 Life-OS 向量索引
   `python3 ~/life-os/scripts/lifeos-index-update.py`

2.5. 更新 wiki 引用索引 + 對話作品同步
   先推導 slug 和 session name（規則同步驟 3）：
   - SLUG = 當前 session 名稱 strip `claude-` 前綴（例：`claude-terminal` → `terminal`）
   - SESSION_NAME = 當前 session 名稱（例：`claude-terminal`）

   把本次對話的重點摘要寫入暫存檔，然後跑：
   ```bash
   # Claude 先把對話摘要寫入暫存檔
   # 然後執行：
   bash ~/life-os/scripts/conv-catalogue-sync.sh "/tmp/conv-session-${SLUG}.txt"
   ```
   - conv-catalogue：用 haiku 抽出對話中提到的作品，dedup 後 append 進 catalogue
   - 若無作品，腳本秒結不影響流程
   - ~~wiki-citation-update~~（2026-07-02 移除）：概念卡/條目回寫已由夜間對帳管線（04:40）單軌接管——session 九成死於 watchdog 從不走到這步，實查 76 卡只寫過 10 筆全停在 5 月；兩軌並存會雙寫打架。single writer 原則：回寫只有夜間對帳一個裁決點。

3. 寫 handoff.md（覆寫式交接卡）
   覆寫 `ws/<current-slug>/handoff.md`，格式四段：SUMMARY / CURRENT / NEXT / LESSON

   **slug 推導規則**（同 2.5）：
   - 從當前 session 名稱 strip `claude-` 前綴
     例：session `claude-terminal` → slug `terminal` → `ws/terminal/handoff.md`
   - 或透過 registry：`bash -c "source ~/life-os/scripts/lib/session-registry.sh && registry_get_json claude-<session> | python3 -c \"import sys,json;d=json.load(sys.stdin);print(d['handoff_path'])\""`
   - Fallback（無法解析 slug）：寫到 `~/life-os/handoff.md`（保持向後相容）

   ⛔ 禁止寫入 memory/ 目錄。如有值得長期保存的 feedback/project/reference 洞察，
   另建對應型別的 memory 卡片（選做，不是必做流程）。

4. 判斷里程碑 → 追加 CHANGELOG.md
   問自己：「這次 session 有完成系統級的基礎建設或變更嗎？下一個我需要知道這件事存在嗎？」
   - 有 → 追加一行到 ~/life-os/CHANGELOG.md 對應日期區塊
   - 沒有 → 跳過（日常對話不寫）
   - 格式：`- [完成] 簡述變更（關鍵細節）`

5. 廢檔掃描（快速，< 3 秒）
   ```bash
   find ~/life-os -maxdepth 3 \( -name '*.bak' -o -name '*.bak-*' -o -name '_backup_*' \) 2>/dev/null
   ```
   有結果就提醒：「本 session 留下 N 個 .bak / _backup_，要清嗎？」
   沒結果就跳過，不報告。

6. 存 handoff 工單
   寫 ~/life-os/drafts/WO-YYYY-MM-DD-session-handoff.md

7. 自重啟
   `bash ~/life-os/scripts/self-restart.sh &`
   （SessionEnd hook 寫日檔 → 等 30 秒 → kill 當前 session → supervisor 重開）

## 輸出格式

```
Session 收尾完成 ✓

📝 YYYY-MM-DD-HHMM-summary.md 寫入
🔢 Life-OS 向量：N 個入庫
📋 handoff.md 覆寫完成
📋 handoff 工單存檔

待辦帶去下個 session：
• [未完成項目]

重啟中，30 秒後見新 session。
```

## 交接卡品質檢查（借鑑 session-handoff）

寫完交接卡後，執行簡單完整性驗收：

| 項目 | 檢查 |
|------|------|
| 有「做了什麼」 | ✓/✗ |
| 有「現在狀態」 | ✓/✗ |
| 有「下一步」 | ✓/✗ |
| 無明文 token/密碼 | ✓/✗ |

三項以上 ✓ 才算合格，否則補寫後再重啟。

交接卡加上新鮮度標籤：
`## Session 交接（YYYY-MM-DD HH:MM）[FRESH]`

## 原則

- 不重複 SessionEnd hook（hook 負責完整日檔）
- 這個 skill 補「即時摘要尾段 + 向量 + 快速交接卡 + 重啟」
- 自重啟用 & 背景跑，不阻塞輸出

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
