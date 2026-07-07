# GOTCHAS.md — gog skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] gog CLI 能做的事（sheets append/get/update、docs、tasks）就走 gog，不要自己寫 Python + security keychain + urllib 繞 OAuth。 (2026-04-28, 1 hit)
- [0.5] # gog calendar create --rrule BYDAY 多日逗號無效 `gog calendar create --rrule "RRULE:FREQ=WEEKLY;BYDAY=MO,TH"` 回傳 Google API 400 Invalid recurrence rule。 原因：gog CLI 可能把逗號當 flag value separator，導致送出格式錯誤的 RRULE。 **解法**：拆成兩個獨立循環事件，各自指定 BYDAY。 ```bash # 週一 gog calendar create "user2@example.com" --account "user2@example.com" \ --summary "🧺 洗衣服" \ --from "2026-04-27T12:00:00Z" --to "2026-04-27T13:00:00Z" \ --rrule "RRULE:FREQ=WEEKLY;BYDAY=MO" --no-input # 週四 gog calendar create "user2@example.com" --account "user2@example.com" \ --summary "🧺 洗衣服" \ --from "2026-04-30T12:00:00Z" --to "2026-04-30T13:00:00Z" \ --rrule "RRULE:FREQ=WEEKLY;BYDAY=TH" --no-input ``` **附注**：timed 循環事件需用 UTC 時間（timezone 欄位無法透過 gog 設定）；台灣不調整夏令時間，UTC+8 固定，UTC 時間換算不會漂移。 **How to apply:** 任何多天循環行程，拆成多個 event 分別建立。 (2026-04-27, 1 hit)
- [0.5] Google Drive 電腦備份的 MIRROR 模式產生隐形系統負擔，需主動管理或關閉。 (2026-04-26, 1 hit)
- [0.5] Google Sheets TSV 多行表頭+空欄位破壞解析，改用 JSON 輸出更穩定 (2026-04-27, 1 hit)
- [0.5] Google Tasks 清單方案老化（待買/待看分類已失效），音樂類清單缺失待重設計 (2026-07-03, 1 hit)
