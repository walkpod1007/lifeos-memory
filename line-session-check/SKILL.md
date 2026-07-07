---
name: line-session-check
description: 批次檢查所有 LINE session 健康狀態並自動重啟異常者。觸發：檢查 LINE session、LINE 巡檢、LINE session check、LINE 全檢
metadata:
  type: skill
---

# line-session-check

批次健檢所有 LINE channel session，找出 token 爆量 / error 卡住 / process 死亡的 session，**自動走 safe-restart 重啟**。

## 與 line-health 的差異

| | line-health | line-session-check |
|---|---|---|
| 目的 | 管道診斷（為什麼不通） | session 巡檢（哪些需要重啟） |
| 範圍 | tunnel → webhook → queue → session → reply 全鏈 | 聚焦 session 層（token / error / process） |
| 動作 | 純診斷，不修 | 診斷 + 自動重啟 |
| 觸發場景 | 「LINE 沒反應」 | 「檢查 LINE session」 |

## SOP（Opus 跟著做）

### Step 1：跑 check.sh

```bash
bash ~/life-os/skills/line-session-check/check.sh
```

### Step 2：解讀輸出

腳本最後兩行是機器可讀的：
```
RESTART_LIST=claude-line-note claude-line-ita
RESPAWN_LIST=claude-line-ptcg
```

- `RESTART_LIST`：session 活著但有問題（token > 140k / error / 無 claude process）→ 走 safe-restart
- `RESPAWN_LIST`：tmux session 本身不在了 → 直接跑 supervisor script

tokens 欄位的來源標註（2026-07-04 起）：
- `(jsonl)`：從本輪 incarnation 的 transcript 算出（ground truth，與 token-watchdog 同源）
- `(pane)`：JSONL 讀不到、退回抓 tmux 畫面上的「X.Xk tokens」字樣（僅供參考）
- `n/a (no-transcript)`：JSONL 和 pane 都讀不到 token。最常見原因是本輪 claude 還沒收過
  訊息、尚未建 transcript（合法狀態）；但**路徑對映錯誤或解析失敗也會落到這個標籤**，
  若某條 session 明明在忙卻長期 no-transcript，要懷疑 check.sh 的目錄對映而不是當它沒事

⚠️ 舊版只靠 pane 字樣讀 token，rating prompt / statusline 不顯示時會漏檢
（實案 2026-07-04：claude-line 876k 顯示 n/a 未進 RESTART_LIST）。若懷疑 check.sh
全綠但某條 session 不對勁，交叉看 `~/.claude/claude-<name>.log` 的 watchdog 讀數
與 claude process 的實際啟動日（`LC_ALL=C ps -p <pid> -o lstart=`）——watchdog
觸發重啟也可能 kill 失敗後狗自身退出，留下「無狗＋老 claude 活著」的假健康狀態。

### Step 3：執行重啟

**RESTART_LIST 裡的每條**，逐一跑：
```bash
bash ~/life-os/scripts/safe-restart-channel.sh <session-name>
```

**RESPAWN_LIST 裡的每條**，逐一跑：
```bash
bash ~/life-os/scripts/<session-name>.sh
```

### Step 4：驗證

重啟完再跑一次 check.sh 確認全 ✅。

### Step 5：回報

給使用者的回報格式：
```
LINE Session Check 結果：
- 基礎設施：✅ tunnel + webhook 正常
- Session 狀態：N/M 正常，K 條已重啟
  - <session>：<原因> → 已 safe-restart（新 PID XXXXX）
  - <session>：tmux 不在 → 已 respawn
- 全部恢復正常 ✅
```

## 判定「需要重啟」的條件

| 條件 | 嚴重度 | 動作 |
|------|--------|------|
| token > 140k | ⚠️ | safe-restart |
| pane 有 `Operation not permitted` / `panic` / `fatal` | ⚠️ | safe-restart |
| tmux session 在但沒 claude process | ⚠️ | safe-restart |
| tmux session 完全不在 | ❌ | respawn（跑 supervisor script） |

## 基礎設施異常時

如果 check.sh 報 tunnel ❌ 或 webhook ❌，先修基礎設施再檢查 session：
- tunnel 問題 → 用 `cloudflared-tunnel` skill
- webhook 問題 → `cd ~/life-os/plugins/line-lobster && bun webhook.ts >> /tmp/line-lobster.log 2>&1 &`

## 注意

- 一次只 safe-restart 一條，不要平行跑（避免 gen-handoff 搶 Haiku 額度）
- 如果 RESTART_LIST 超過 3 條，先跟使用者確認再批次重啟
- check.sh 是非破壞性的，可以隨時重跑

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
