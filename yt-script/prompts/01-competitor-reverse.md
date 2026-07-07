# Prompt 01 — 競品頻道逆向工程

> 出處：[[raw/2026-04-17-用Claude建AI無臉YouTube頻道的3個提示詞策略]]（@razvanpbusiness, Instagram, 2026-04-06）。
> 原文僅露出 `<ROLE>` 開頭片段（IG 貼文截斷，作者要私訊才給全文），下方為依露出片段 + 輸出範例重建的可用版，**重建處已標註**。

## 用途

把對標頻道的高表現標題餵給 Claude，逆向出「為什麼這些影片會紅」的可複製系統，作為後續選題（Prompt 02）的依據。

## 輸入：你要貼什麼

1. 利基 / 內容支柱（一行，例如「二手車購買決策」或對齊 brand-profile 的支柱）。
2. 選 2–3 個對標頻道，各貼**Top 20 最高觀看的影片標題**（YouTube 頻道頁可按觀看數排序；或用 Tubelens / yt-dlp 抓）。

## Prompt（貼進 Claude，{ } 自行替換）

```
<ROLE>
You are a Veteran & Experienced YouTube Channel Growth Strategist.
</ROLE>

<TASK>
Reverse-engineer the {N} most-viewed video titles below to produce actionable,
replicable systems a new channel in the "{NICHE}" niche could copy.
</TASK>

<INPUT — top viewed titles>
{把對標頻道的 Top 20 標題逐行貼在這裡，標明哪些屬於哪個頻道}
</INPUT>

<OUTPUT — produce exactly these sections>
1. SUCCESS SYSTEMS — the 5 repeatable systems behind these titles' performance.
   For each: name it, explain the mechanism, give 2 example titles from the input that use it.
2. TOPIC-SELECTION FRAMEWORK — classify topics on the Fear ↔ Aspiration spectrum.
   State explicitly which pole each top title sits on. Flag that NEUTRAL topics
   (neither fear nor aspiration) underperform and should be avoided.
3. TITLE BREAKDOWN — recurring title patterns (numbers, curiosity gap, contrast,
   loss-aversion, specificity). For each pattern give the formula + an example.
4. NICHE MECHANICS — why this niche earns attention, where viewers drop off,
   and what an entrant must do to differentiate.
</OUTPUT>

Output in {繁體中文（台灣）/ English}. Be concrete; cite the input titles, do not invent data.
```

## 輸出 schema（Claude 應回的結構）

```
1. SUCCESS SYSTEMS
   - System 1: {名稱} — {機制} — 例：{標題A} / {標題B}
   - ... ×5
2. TOPIC-SELECTION FRAMEWORK
   - Fear 極：{標題清單}
   - Aspiration 極：{標題清單}
   - ⚠️ 中性話題避免：{說明}
3. TITLE BREAKDOWN
   - Pattern: {公式} — 例：{標題}
4. NICHE MECHANICS
   - 為何有人看 / 卡點 / 差異化路徑
```

## 重建標註

- `<ROLE> You are a Veteran & Experienced YouTube Channel Growth Strategist.` 與「Reverse-engineer these 20 most viewed videos to produce actionable steps」為**原文露出**。
- Fear vs Aspiration 兩極、不選中性話題、5 大成功系統、標題拆解、利基機制 = **原文摘要明確列出的輸出內容**（見捕捉筆記 Prompt #1 段）。
- `<TASK>/<INPUT>/<OUTPUT>` 的結構化包裝為**重建**，便於直接執行；語義忠於原文，未新增宣稱。
