---
name: switch-channel-model
description: 切換 channel session 的 --model 並讓 supervisor 生效。觸發：換 model、切 model、改成 sonnet/opus/haiku、batch switch model
version: "1.0"
created: "2026-05-04"
---

# switch-channel-model

主 session 切換 channel session model 的**唯一合法路徑**。寫 handoff → 改 supervisor script → 重啟 supervisor 本身。

## 為什麼存在這個技能

歷史踩坑（2026-05-04）：使用者要把 6 個 LINE channel 從 opus-4-6 切到 sonnet-4-6。原以為流程是「改 supervisor script 的 `--model` → 跑 safe-restart-channel.sh 重啟 inner claude」。**結果不行**——`safe-restart` 結束後，新 claude 用的還是舊 model。

根本原因：supervisor 是 `while true; do ... claude --model X ...; done` 結構，**bash 把整個 compound command 一次 parse 進記憶體**，loop 內每次重拉 claude 用的指令是 supervisor 啟動時的版本。光改 script、再 SIGTERM inner claude，supervisor 還是用記憶體裡的舊指令重拉。

要讓新 model 生效，必須**重啟 supervisor 本身**：`tmux kill-session`（連 supervisor 一起殺）→ 清 supervisor pid file → 立即重 spawn supervisor → 新 supervisor 才會 parse 到改過的 script。

`safe-restart` 不夠用的這條路徑就由本 skill 補上。

## 用法

```bash
bash ~/life-os/skills/switch-channel-model/scripts/switch-channel-model.sh <channel> <model>
```

範例：
```bash
# 單一 channel
bash .../switch-channel-model.sh claude-line claude-sonnet-4-6

# 批次（5 個 LINE channel 切到 sonnet）
for c in claude-line claude-line-talk claude-line-ita claude-line-note claude-line-ptcg; do
  bash .../switch-channel-model.sh "$c" claude-sonnet-4-6
done
```

支援 channel：`claude-line` / `claude-line-talk` / `claude-line-ita` / `claude-line-note` / `claude-line-ptcg` / `claude-line-recipe` / `claude-remote` / `claude-terminal`

支援 model：`claude-opus-4-8` / `claude-opus-4-7` / `claude-opus-4-6` / `claude-sonnet-5` / `claude-sonnet-4-6` / `claude-haiku-4-5-20251001`

## 流程

1. 引數驗證 + channel/model 白名單檢查
2. 寫 handoff（safe-restart-channel.sh；ptcg/recipe 不在白名單則直接呼 gen-handoff.sh）
3. `sed -i.bak` 修 supervisor script 的 `claude --model X` 那行
4. `tmux kill-session -t <channel>`（殺 supervisor + 內部 claude）
5. 刪除 `~/.claude/<channel>-supervisor.pid`
6. `nohup bash <supervisor>.sh & disown` 立即重 spawn（不等 watchdog 5 min）
7. sleep 6s + `pgrep` 驗證新 process 用新 model

## 退出碼

| code | 意義 |
|---|---|
| 0 | ✅ 新 model 已生效（pgrep 命中）|
| 1 | ⚠️ 重啟後驗證失敗（pgrep 找不到 NEW_MODEL）|
| 2 | supervisor script 不存在 |
| 3 | 用法錯誤 / 白名單不通過 |

## 何時用

- 使用者說「把 X channel 改成 Y model」「所有 LINE 切 sonnet」「換 model」
- supervisor script 已改但實 process 還在跑舊 model（safe-restart 跑了沒效）

## 何時不用

- 純重啟（沒換 model）→ 用 `safe-restart`
- 改 mcp-config / channel 設定 → 改 script 後 `safe-restart` 即可（mcp-config 是 inner claude 啟動時讀的，不受 supervisor compound command parse 限制）
- 主 session（remote / terminal）自己換 model：本 skill 雖白名單包含 `claude-remote` / `claude-terminal`，但這兩個 session 通常由使用者手動管理；自動切之前先 `gen-handoff` 否則對話脈絡會掉

## 紅線

- ❌ 禁止跳過 step 2 的 handoff（直接 tmux kill 會丟脈絡）
- ❌ 禁止用 `pkill -f "claude --model"` 想直接砍——会跨 session 誤殺
- ❌ 禁止手動 sed 改完就跑 `safe-restart`（這是本 skill 存在的原因）
- ✅ 一律走本 skill 的 script

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
