---
name: safe-restart
description: Channel session 安全重啟總閘：kill/重啟/換 model 前先存 handoff 再重拉。觸發：重啟、重開、reset、kill、respawn、換 model、清殭屍 session
---

# safe-restart

> **2026-05-13 整併**：原先的 `session-cleanup` 與 `session-reset` skill 已 archive（描述 OpenClaw gateway 機制已熄火），所有 session 重啟/清理一律走本 skill。

主 session 對任何 channel 做重啟時的**唯一合法路徑**。確保 handoff、realtime snapshot、daily 冷儲存三件事在砍 claude 前都跑完。

## 為什麼存在這個技能

歷史踩坑：主 session 為了重啟 channel（例如 webhook routing 改完、換 model、修 bug）直接 `kill -TERM`，supervisor 雖然會 respawn 但 **handoff 沒寫、最後 N 小時的工作脈絡全飛**。新 session 接手讀到的是更久之前的 handoff，誤以為「沒事發生」。

修法不是讓 Opus 自己呼 `/session-end`（Opus 可能正卡在某個工具，response 慢或永遠不回）——改用 Haiku 跑獨立腳本讀 transcript jsonl 寫 handoff，跟 claude alive 與否解耦。

## 用法

```bash
bash ~/life-os/scripts/safe-restart-channel.sh <session-name>
```

範例：
```bash
bash ~/life-os/scripts/safe-restart-channel.sh claude-line
bash ~/life-os/scripts/safe-restart-channel.sh claude-line-talk
bash ~/life-os/scripts/safe-restart-channel.sh claude-line-ita
bash ~/life-os/scripts/safe-restart-channel.sh claude-telegram
```

支援的 session 名（依 supervisor 腳本存在性）：`claude-line`、`claude-line-talk`、`claude-line-ita`、`claude-line-note`、`claude-telegram`、`claude-remote`。

## 流程（6 步）

1. **找 claude PID + transcript jsonl**（按 `~/.claude/projects/-Users-<user>-Documents-life-os-ws-<slug>/` 最新 mtime）
2. **`gen-handoff.sh`**（timeout 150s）— Haiku 4.5 跑 `claude -p` 讀 transcript → 寫 SUMMARY/CURRENT/NEXT/LESSON 4 段 + 最後 10 輪對話原文 → 覆寫 `ws/<slug>/handoff.md`
3. **`realtime-summary.sh`**（timeout 60s）— 抓最新對話寫 `daily/YYYY-MM-DD/HHMM-<slug>-session.md`
4. **`claude-hook-session-end.sh`**（timeout 30s）— 冷儲存 + 向量索引
5. **`touch <slug>-supervisor-restart`**（讓 supervisor 知道是有意重啟，不計 fast-fail）
6. **`kill -TERM <claude-pid>`** + 最多等 30s 確認 supervisor 重拉新 PID

## 退出碼

| code | 意義 |
|---|---|
| 0 | ✅ 新 claude 已就緒 |
| 1 | ⚠️ supervisor 30s 內沒重拉（人工檢查 supervisor PID file） |
| 2 | claude 早已不在跑（直接跑 supervisor script，不需此技能） |
| 3 | 用法錯誤 |

## 何時用

- 使用者說「重啟 LINE / line-talk / line-ita / telegram / remote」「安全重啟 X」「safe-restart」
- 改完 supervisor `.sh` 的 mcp-config / permission-mode 等 inner claude 啟動參數要重啟生效
- channel claude 卡死、queue 積壓久但還活著
- token-watchdog 沒觸發但你想主動換 session（換 token 預算）

> ⚠️ **不含 `--model` 切換**：supervisor 的 `while true; do … claude --model X …; done` 是 bash compound command，整段一次 parse 進記憶體，loop 內重拉 claude 用的是 supervisor 啟動時的指令版本——本 skill 只 SIGTERM inner claude，supervisor 還是用舊 model 重拉。換 model 必須**重啟 supervisor 本身**（tmux kill-session + 重 spawn），請改用 `switch-channel-model` skill。
> 踩坑日期：2026-05-04（6 LINE channel opus-4-6 → sonnet-4-6 第一輪 safe-restart 全部沒生效）。

## 何時不用

- channel 完全沒 claude process（用 `bash ~/life-os/scripts/<session>.sh` 直接拉新的）
- 緊急要立刻砍（用 `pkill -TERM -f ...`，handoff 會掉但你接受這個取捨）
- 主 session 自己重啟（不適用，這只管 channel）

## 與 token-watchdog 的關係

`token-watchdog.sh` 的兩條 kill 路徑（token 滿 + MCP 死亡 health-check）已經在用同一支 `gen-handoff.sh`。`safe-restart` 是**主 session 手動觸發版**，邏輯一致，不重複造輪。

## 紅線

- ❌ 禁止用 `pkill -f "claude.*mcp-config"` 直接砍——handoff 不會寫
- ❌ 禁止 `tmux send-keys '/session-end'` 然後 sleep 90s 假設 Opus 寫完——Opus 可能卡住
- ❌ 禁止跳過 RESTART_FLAG 直接 SIGTERM——supervisor 會誤判 fast-fail，連續 30 次後退出
- ✅ 一律走這個 skill 的腳本

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
