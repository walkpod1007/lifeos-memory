# GOTCHAS.md — line-health skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] LINE webhook 的 hostname 是 `<YOUR_DOMAIN>`，不是 `<YOUR_DOMAIN>`。 搬機時把 config.yml 的 ingress 只寫了 `<YOUR_DOMAIN>`，沒加 `bot3`，導致 LINE 所有 webhook 進來一律 1033，LINE 完全沒有回應。 **背景**：`<YOUR_DOMAIN>` 是 2026-04-22 幫 Telegram 設的，Telegram 後來改用官方 `--channels` plugin，這個 hostname 就閒置了。LINE 從一開始就用 `<YOUR_DOMAIN>`，是兩個不同的用途，不能混用。 **典型症狀**： - LINE 完全沒回應，queue 裡有訊息但沒有新訊息進來 - `curl https://<YOUR_DOMAIN>/line/webhook` 回 1033 - `curl https://<YOUR_DOMAIN>/line/webhook` 卻正常（因為 config.yml 有寫 bot） - `/tmp/line-lobster.log` 沒有新的 `queued →` 條目進來 **修法**： 1. `~/.cloudflared/config.yml` 的 ingress 加上 `<YOUR_DOMAIN> → localhost:3001` 2. `cloudflared tunnel route dns --overwrite-dns <tunnel-uuid> <YOUR_DOMAIN>`（更新 CNAME 指向當前 tunnel） 3. `sudo launchctl bootout system /Library/LaunchDaemons/com.cloudflare.cloudflared.plist` 4. `sudo launchctl bootstrap system /Library/LaunchDaemons/com.cloudflare.cloudflared.plist` **Hostname 對應表（截至 2026-05-01）**： | Hostname | 用途 | Port | 備注 | |----------|------|------|------| | `<YOUR_DOMAIN>` | LINE Messaging API | 3001 | LINE Developer Console 設的是這個 | | `<YOUR_DOMAIN>` | Telegram（閒置）| 3001 | 原本 8443，Telegram 改 plugin 後沒人用 | **搬機 checklist**： - [ ] config.yml 兩條 ingress 都要有（bot3 + bot） - [ ] DNS CNAME 都要指向新 tunnel（`--overwrite-dns`） - [ ] plist 用 `--config` 模式，不用 `--token` - [ ] `bootout + bootstrap` 重載，不要只用 `kickstart -k` (2026-05-01, 1 hit)
- [0.5] Health check 200 不等於訊息真實流通，需確認 log 輸出端點 (2026-04-27, 1 hit)
- [0.5] 帳號故障期間積壓的 LINE 消息，其 replyToken 在服務恢復後已過期（LINE token 有效期約 1 分鐘），即使帳號恢復也無法事後補送回覆。 (2026-06-08, 1 hit)
- [0.5] line-note曾于对话途中卡死，当轮已修复，Threads连接问题已排除。 (2026-07-02, 1 hit)
- [0.5] 工具清單無 `get_pending`；助理應先確認 LINE 連接方式（若用 MCP 則為 Telegram，非 LINE） (2026-07-03, 1 hit)
