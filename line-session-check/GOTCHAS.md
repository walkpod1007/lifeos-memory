# GOTCHAS.md — line-session-check skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] line-note session 因 monthly spend limit 互動窗口卡頓，需後續修復跟進。 (2026-07-02, 1 hit)
- [0.5] prune 上限設太低，高頻 cron 幾分鐘內洗爆 session 名單，導致 session-once 失效，底卡重複注入。 (2026-07-02, 1 hit)
