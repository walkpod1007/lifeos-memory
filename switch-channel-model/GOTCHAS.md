# GOTCHAS.md — switch-channel-model skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] 升級 Opus 至 4.8 時，switch-channel-model skill 的白名單未自動增加 opus-4-8，導致無法透過 skill 切換新版本，需手動補入。建議模型版本發佈時同步審查依賴此 skill 的所有配置。 (2026-05-29, 1 hit)
