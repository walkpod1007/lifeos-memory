# GOTCHAS.md — yt-sub-translate skill

> 格式：日期 + 描述。這些都是真實踩過的坑，改 skill 前先讀這裡。

---

- [0.5] Google OAuth 服務更新後夾帶額外權限，導致 token 儲存時驗證失敗；在 `yt_auth.py` 中加入 `OAUTHLIB_RELAX_TOKEN_SCOPE=true` 環境變數方能解決。為 Google API 側的限制性更新，舊版 scope 不相容新規則。 (2026-06-03, 1 hit)

- [標題 100 字上限] `videos().update` 上傳多語 localization 時，**任一語言標題 > 100 字元 → 整批失敗** `HttpError 400 invalidVideoMetadata: "The request metadata is invalid."`（不會告訴你是哪個欄位）。中文標題翻成英文/泰文常會膨脹超過 100（這次 en=116、th=109）。**翻完、上傳前一定要 `len(title)<=100` 檢查並縮短超長的**。description 上限 5000 字。 (2026-06-16, 1 hit)

- [字幕成功但 localization 失敗＝部分成功] caption insert 與 video localization update 是**獨立兩步**：字幕可能全部上傳成功，localization 那步才炸（如上的 100 字問題）。所以上傳腳本要對 caption 做「已存在則跳過」的 idempotent 檢查（用 `captions().list` 比對 language），重跑時才不會重複上傳字幕軌；localization 修好重跑即可。 (2026-06-16, 1 hit)

- [多語英文鍵 en vs en-US] 影片可能**已有 en-US** localization（別人/先前做的）。新增「en」會與「en-US」並存造成兩個英文版。要嘛沿用既有 en-US 不動、要嘛直接覆蓋 en-US，不要盲目新增 en。上傳前先 `videos().list(part=localizations)` 看現況。 (2026-06-16, 1 hit)

- [泰文 claude -p 必超時] `claude -p --model haiku` 翻泰文（無論字幕批次或 info）穩定 120 秒超時——泰文輸出 token 密度高（每字 3-4 bytes、無空格斷詞），Haiku 生成慢。**泰文一律改派 sonnet 子代理直翻**（Agent tool，不走 CLI）；ko/ja/en 走原管線沒事。SKILL.md Gotchas 原有「泰文品質不穩可改 Sonnet」實為「泰文必掛」。 (2026-07-03, 2 hits 同晚)
