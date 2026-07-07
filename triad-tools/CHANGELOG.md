# Changelog

## v1.1.0 — 2026-06-15

### 變更
- **Gemini 退役**：五金剛 → 四金剛（Claude / Codex / GLM / MiniMax）。網路爬梳改 Opus 自身 WebSearch/WebFetch、長 context 多檔改 mini-agent(200K)/codex、紅隊維持 codex。

### 為什麼這樣做
Gemini CLI OAuth 於 2026-06-18 停用、headless 認證未支援（feature req #78），且其網路能力與 Opus 自帶 WebSearch/WebFetch 重複。見 [[project_gemini_cli_deprecation_agy]]。

### 已知問題 / 待觀察
- gemini binary 不刪（無害）。歷史紅隊對比表保留 Gemini 紀錄供參。

---

## v1.0.0 — 2026-03-24

### 新增
- 初始版本，三大金剛派工路由（Gemini/Codex/CC）

### 為什麼這樣做
從 lobster-skills 移植，加入 Life-OS 本地算力分攤（德瑪/小蝦）context。

### 已知問題 / 待觀察
- 硬規則：一兩行小修直接 edit，不派工。

---
> 格式：版本 + 日期 → 改了什麼 → 為什麼 → 已知問題
> 目的：防止迭代後不知道前一版改過什麼又改回去
