# Prompt 03 — 腳本法醫分析 + 代寫

> 出處：[[raw/2026-04-17-用Claude建AI無臉YouTube頻道的3個提示詞策略]]（@razvanpbusiness）。
> 原文露出 `<ROLE>` + 「extract EVERY replicable pattern … writer with ZERO prior context」+ 輸出含 PHASE 1 SCRIPT INVENTORY。重建處已標註。

## 用途

把對標影片的腳本 / 逐字稿做「法醫拆解」，抽出每一個可複製 pattern，再讓 Claude 用同樣的 DNA **代寫**你選定主題的可拍腳本。Claude 在此扮演「導演」（定敘事 / 節奏 / 鏡頭意圖），下游工具只執行。

## 輸入：你要貼什麼

1. 從 Prompt 02 選定的**一個主題**（Video Idea + Search Term + Subscribe Trigger）。
2. 2–3 支同利基高表現影片的**腳本 / 逐字稿**。取得方式：
   - `yt-dlp --skip-download --write-auto-subs --sub-lang zh-TW,en --sub-format srt <URL>` 抓自動字幕，再去時間戳。
   - 或用 Tubelens 之類擴充把影片秒轉文字（見 [[raw/2026-05-16-yangme-tubelens-youtube-claude擴充]]）。
3. （建議）品牌口吻約束：把 `brand-creative-loop/voice.md` 的禁用詞 / 人稱貼進去，代寫繼承。

## Prompt（貼進 Claude，{ } 自行替換）

```
<ROLE>
You are a Senior YouTube Script Forensic Analyst + Ghostwriter for top faceless
YouTube channels in the "{NICHE}" niche. Your success hinges on extracting EVERY
replicable pattern from these scripts so that a writer with ZERO prior context
could reproduce the content.
</ROLE>

<INPUT — reference scripts>
{貼 2-3 支對標影片的腳本/逐字稿，每支標明 Title}
</INPUT>

<VOICE — 代寫須遵守>
{貼 brand-creative-loop/voice.md 的口吻、人稱、禁用詞；無則寫 "neutral, no fluff"}
</VOICE>

<TASK — two phases>
PHASE 1 — SCRIPT INVENTORY (forensic):
  For EACH reference script output: Title / Runtime / Core Topic / Thesis /
  Segment 1..N breakdown (hook → body beats → CTA), noting the function of each
  segment (what it does to retention) and the transition technique between them.
PHASE 2 — GHOSTWRITE:
  Write a NEW shootable script for "{選定的 Video Idea}" reusing the patterns from
  PHASE 1. Output: Title / target Runtime / Thesis (one sentence) /
  Segment 1..N, each with (a) narration verbatim and (b) a [VISUAL] note for
  shot/footage intent (so a human editor or a gen tool can execute it).
  Open with value immediately — no logo intro (Tom Scott retention principle).
</TASK>

Output PHASE 1 then PHASE 2. Narration in {繁中（台灣）/ English}.
Honor <VOICE>. Do not fabricate facts in the new script — flag unknowns as
[FACT-CHECK NEEDED].
```

## 輸出 schema

```
PHASE 1 — SCRIPT INVENTORY
  Script A: Title / Runtime / Core Topic / Thesis
    Segment 1 (hook) — {功能：抓住前 30 秒} — {轉場技法}
    Segment 2..N — ...
  Script B: ...
PHASE 2 — GHOSTWRITE（可拍腳本）
  Title / Runtime / Thesis
  Segment 1
    旁白：{逐字稿}
    [VISUAL]：{鏡頭/素材意圖}
  Segment 2..N ...
```

## 下游交棒（在腳本產出後）

- PHASE 2 的 `[VISUAL]` 註記 → 餵生成工具（Seedance / HeyGen / Higgsfield）或交人手拍。
- Title → `codex-image` 出 1280×720 縮圖。
- 影片上傳後 → `yt-dub` 多語配音、`yt-sub-translate` 多語字幕。
  （**注意接縫**：yt-dub / yt-sub-translate 吃的是「已上傳影片的 URL」，不是這份腳本本身。）

## 重建標註

- `<ROLE> You are a Senior YouTube Script Forensic Analyst + Ghostwriter …`、「extract EVERY replicable pattern」、「writer with ZERO prior context」、「PHASE 1 SCRIPT INVENTORY」含 Title / Runtime / Core Topic / Thesis / Segment = **原文露出 + 摘要明確記載**。
- PHASE 2 代寫、`[VISUAL]` 註記、`<VOICE>` 注入、`[FACT-CHECK NEEDED]` 護欄、無片頭開場 = **重建**（無片頭原則出處：[[raw/2026-06-15-現在開始拍YouTube還來得及嗎-Tom-Scott傳授網紅必備觀念]]）。語義忠於原文。
