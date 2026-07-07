---
name: line-health
description: LINE 沒反應固定 SOP：tunnel→webhook→queue→session 一條龍診斷。觸發：LINE 沒反應、LINE 不回、LINE 卡住、line-health、LINE webhook 掛了
---

# line-health

LINE bot 沒反應時的**第一站**：跑 9 步 SOP 把整條管道（channel session → claude → webhook → cloudflared → 公開 URL → queue → log）一次盤完，每段印 ✅/⚠️/❌，看哪段斷就修哪段。

## 為什麼存在這個技能

2026-05-01 22:00 LINE webhook 斷線事件：主 session 從 `tmux ls` 一路繞到 cloudflared connector 創建時間才找到根因（cloudflared connector 22:00 斷線、22:07 使用者手動重啟），整個 debug 過程繞了大半小時。每次 LINE 出事都重新挖一遍——把這次摸到的 9 步順序固化成 SOP，下次直接跑。

`skill-routes.md` 裡「重啟 LINE」對應 `safe-restart`，「報錯」對應 `runbook`，但「LINE 沒反應 / 健檢」原本沒有對應 skill。這個 skill 補這個洞。

## 用法

```bash
bash ~/life-os/skills/line-health/check.sh
```

純診斷，不改任何系統。輸出 9 段結構化健檢結果。

## 9 步檢查順序（從近到遠）

| 步 | 檢查 | 看什麼 |
|----|------|--------|
| 1 | tmux sessions | 6 條 channel session 是否都還在（claude-line / line-note / line-talk / line-ita / line-recipe / line-ptcg） |
| 2 | claude binaries | 每條 session 底下是否有 claude process 在跑 |
| 3 | claude pane 狀態 | pane 看到 `❯` prompt（在等指令）還是 hang/error |
| 4 | line-lobster webhook | webhook.ts process 活著 + port 3001 listening |
| 5 | cloudflared tunnel | cloudflared process 活著 + tunnel info 顯示 connector 連線中 |
| 6 | 公開 webhook URL | `curl https://bot{,3}<YOUR_DOMAIN>/line/webhook` 回應碼 |
| 7 | queue 狀態 | `/health` 端點回 pending count（每條 channel） |
| 8 | webhook log 異常 | invalid signature / cooldown skip 計數 + 末 5 條訊息流向 |
| 9 | runtime 目錄 | `~/.claude/channels/line/runtime/` 存在 + queue 檔數量 |

### Debug shortcut：依症狀挑優先看的 step

`check.sh` 永遠跑全部 9 步（順序就是 IP，不換），但解讀時可以根據症狀先看下面這幾步：

| 症狀 | 優先盯這幾步 | 理由 |
|------|-------------|------|
| 「LINE 訊息**進不來**」（webhook 沒被打） | 6 → 5 → 4 → 8 | 入口鏈：公開 URL → tunnel → 後端 → log 看 invalid signature |
| 「LINE 收到但**不回**」（webhook 收到但 claude 沒動） | 7 → 3 → 2 → 1 | 消費端：queue 有訊息 → pane 卡住 → claude 死 → session 沒了 |
| 「**全部都不通**」（不確定哪裡） | 1 → 9 全部跑 | 從近端拉到遠端，看哪段先 ❌ |

## 輸出解讀

跑完看結尾的「解讀指南」一段，根據哪個 step ❌ 對應修法：

| 失敗 step | 含義 | 修法 |
|-----------|------|------|
| 1 / 2 缺 session/binary | channel supervisor 死 | `bash ~/life-os/scripts/claude-line*.sh`（單條）或 `safe-restart` skill |
| 3 pane 卡 hang | claude 卡住 | `safe-restart` skill 走 gen-handoff → SIGTERM → respawn |
| 4 webhook.ts 死 | line-lobster crashed | `cd ~/life-os/plugins/line-lobster && bun webhook.ts >> /tmp/line-lobster.log 2>&1 &` |
| 5 cloudflared down | tunnel agent 死 | `sudo launchctl kickstart -k system/com.cloudflare.cloudflared` 或 `cloudflared-tunnel` skill |
| 6 530 / 1033 | tunnel hostname routing 沒設 | `~/.cloudflared/config.yml` ingress 段確認 hostname 對到 localhost:3001 |
| 6 502 / 503 | ingress 過了但後端死 | 回頭看 step 4（webhook 後端） |
| 7 pending 暴增 | claude 沒在讀 queue | step 3 看 pane 狀態，多半 claude 卡住，走 `safe-restart` |
| 8 invalid signature 暴增 | LINE channel secret 錯 / 平台 retry | 對 LINE Developers Console 比對 channel secret |
| 9 runtime 不存在 | supervisor 第一次啟動會炸 | `mkdir -p ~/.claude/channels/line/runtime` |

## HTTP code 速查（step 6）

> 注意：step 6 用 `curl -I`（HEAD 探測），不是 GET。`/line/webhook` 是 POST-only endpoint，所以 HEAD 預期被拒——405 就是「公開路由抵達後端、後端拒絕 HEAD method」這個成功狀態的訊號，不代表 LINE 真實 POST 一定能成功。

| code | 含義 |
|------|------|
| 405  | Method Not Allowed — HEAD 被拒，代表 tunnel + ingress + 後端 listener 都活；LINE 真實 POST 行為要看 step 7 / 8 |
| 530  | Cloudflare error 1033 — tunnel 沒設 hostname routing 或 connector 斷線 |
| 502 / 503 | tunnel 接到，但後端 :3001 死或不回 |
| 000  | 連不上 — DNS / 網路 / timeout |

## 不該用這個 skill 做什麼

- **不修任何東西**：純診斷，修復走對應修法（safe-restart / cloudflared-tunnel / runbook）
- **不重啟 channel**：要重啟用 `safe-restart` skill，保留對話脈絡
- **不查歷史訊息**：LINE Bot API 不允許讀已讀訊息，這個 skill 也不會去碰

## 已知限制

- 只盤健檢「能否收到訊息 + 能否回」這條主管道；reply token 過期、LINE 平台限速、channel 層級 push 額度等業務規則不在這個 skill 範圍
- step 6 hostname 寫死在 `<YOUR_DOMAIN>` 與 `<YOUR_DOMAIN>`；新增 hostname 要改 check.sh
- step 5 tunnel UUID 寫死（`e4c124fc-…`）；換 tunnel 要改 check.sh

## 延伸

- 重啟 channel：`safe-restart` skill
- 修 cloudflared：`cloudflared-tunnel` skill
- 通用排錯：`runbook` skill

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
