# GOTCHAS.md — mac-health skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] iCloud Documents 路徑的 Read/Write 工具被 macOS TCC 沙箱攔截（EPERM）；Bash 工具加 disableSandbox flag 可繞過。**Why:** Claude Code sandbox 層權限與終端機不同。 (2026-06-11, 1 hit)
- [0.5] lsof 層護欄無效：Claude 進程不持有 jsonl handle，純粹監控盲點——非功能缺陷 (2026-07-02, 1 hit)
- [0.5] 第五種路徑變體長期漏網；rss-brief殭屍cron仍活動（sp500 skill已廢棄）——掃除時發現的 (2026-07-03, 1 hit)
- [0.5] 誤記「開放 App 救了它」——實為家機靠早期長效票滑行，生產未驗證反而更糟 (2026-07-04, 1 hit)
