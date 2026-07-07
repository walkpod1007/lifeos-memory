# GOTCHAS.md — tech-product-research skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] 初期未知 mdutil CLI 限制、嘗試錯誤才發現其無資料夾級支援。 (2026-07-02, 1 hit)
- [0.5] 無法取得匈牙利官方單人方案的現行市價，導致無法將本地目標利潤（1617）與全球定價基準完全對標驗證。 (2026-07-02, 1 hit)
- [0.5] Claude 官方的 rate_limits 和 tokens_used 資訊只能通過 statusline TUI payload 的實時流輸出，standalone 工具（如 claude-monitor）無法直接呼叫 API 查詢，導致無法動態編程監控配額狀態。 (2026-07-01, 1 hit)
