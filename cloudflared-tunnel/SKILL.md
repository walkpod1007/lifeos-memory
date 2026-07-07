---
name: cloudflared-tunnel
description: 診斷修復 Cloudflare Tunnel LaunchAgent，確保重開機後常駐。觸發：tunnel 斷了、webhook 收不到、<YOUR_DOMAIN> 回 530/1033
---

# cloudflared-tunnel

macOS 上 cloudflared LaunchAgent 常見問題：plist 沒帶 `tunnel run` 參數，導致重開機後 tunnel 靜悄悄掛掉。

## 診斷 & 修復

```bash
# 一鍵診斷 + 修復
bash scripts/fix-tunnel.sh

# 只診斷不改動
bash scripts/fix-tunnel.sh --check-only
```

腳本會依序檢查：
1. cloudflared 是否安裝
2. `~/.cloudflared/config.yml` 是否存在
3. LaunchAgent plist 是否存在且帶有 `tunnel run` 參數
4. cloudflared process 是否執行中
5. 外部 HTTPS 連線是否正常（取 config.yml 第一個 hostname）

發現問題會自動修復，包含備份原始 plist。

## 常見根因

| 症狀 | 根因 |
|------|------|
| HTTP 530 / error code 1033 | cloudflared 沒在跑 |
| LaunchAgent 啟動後立即退出 | plist ProgramArguments 缺 `tunnel run` |
| tunnel 連上但 webhook 不通 | config.yml port 與 gateway port 不符 |

## Port 對齊

`~/.cloudflared/config.yml` 的 `service: http://127.0.0.1:<port>` 必須與 OpenClaw gateway 實際 port 一致。

```bash
# 查 gateway port（cloudflared 實際 listening port）
lsof -i -nP | grep cloudflared | grep LISTEN
# 或查看 config.yml 裡設定的 service port
grep service ~/.cloudflared/config.yml
```

## 手動重啟

```bash
launchctl unload ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
launchctl load  ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
```

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
