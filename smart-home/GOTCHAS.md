# GOTCHAS.md — smart-home skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] # Homebrew Python 無 Local Network 權限（macOS） Homebrew 安裝的 python3（/opt/homebrew/bin/python3）在 macOS 上沒有 Local Network entitlement，無法連線本地網路裝置（Sonos、Roborock 等）。 症狀：TCP connect 回傳 errno 65（EHOSTUNREACH），但 curl / ping / /usr/bin/python3 同一 IP 都能通。 **解法**：Sonos（soco）和其他本地網路控制一律改用 `/usr/bin/python3`。 ```bash # 安裝 soco 到 system python /usr/bin/python3 -m pip install soco # 執行 /usr/bin/python3 -c "import soco; s = soco.SoCo('<LAN_IP>'); print(s.player_name)" ``` **Why:** macOS 要求 app 有 Local Network entitlement 才能做 mDNS/multicast。System Python 由 Apple 簽署，有此權限；Homebrew binary 沒有。 **How to apply:** 任何 soco / local network Python 腳本，shebang 或呼叫路徑改成 `/usr/bin/python3`。playlist-manager.py 也要改。 (2026-04-27, 1 hit)
