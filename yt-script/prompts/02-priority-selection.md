# Prompt 02 — 選題優先序排列

> 出處：[[raw/2026-04-17-用Claude建AI無臉YouTube頻道的3個提示詞策略]]（@razvanpbusiness）。
> 原文露出 `<ROLE>` + 前段；輸出表格欄位與範例為原文摘要明確記載。重建處已標註。

## 用途

承接 Prompt 01 的逆向分析，讓 Claude 排出「先拍哪幾支」的優先序，每支附上會跑起來的理由、鎖定搜尋詞、訂閱觸發點。

## 輸入：你要貼什麼

- 同一輪對話接續即可（Claude 已有 Prompt 01 的逆向結論）。
- 若另開對話：把 Prompt 01 的「SUCCESS SYSTEMS + TOPIC FRAMEWORK + NICHE MECHANICS」結論貼回。

## Prompt（貼進 Claude，{ } 自行替換）

```
<ROLE>
You are an Experienced Faceless YouTube Channel Strategist.
</ROLE>

<CONTEXT>
You have already completed a reverse-engineering analysis of the channels and
videos provided in our previous session. You have identified the niche mechanics,
title breakdowns, and topic-selection framework.
</CONTEXT>

<TASK>
Using that analysis, produce a PRIORITY VIDEO SELECTION for the "{NICHE}" niche:
the {N, 例 10} videos to make first, ordered by likelihood of early traction.
</TASK>

<OUTPUT — a table, one row per video>
| # | Video Idea | Why It Earns Early Traction | Search Term Targeted | Subscribe Trigger |
For each row:
- Video Idea: a concrete, specific title (not a vague theme).
- Why It Earns Early Traction: name the mechanism (fear charge / evergreen
  high-search listicle / curiosity gap …) tied to the Prompt-01 framework.
- Search Term Targeted: the exact long-tail query this ranks for.
- Subscribe Trigger: why a viewer subscribes after watching (the value promise).
</OUTPUT>

Order rows #1..#N by early-traction priority. Output in {繁中（台灣）/ English}.
Do not invent search-volume numbers you cannot justify.
```

## 輸出 schema（原文範例）

```
| # | Video Idea | Why It Earns Early Traction | Search Term Targeted | Subscribe Trigger |
|---|-----------|----------------------------|----------------------|-------------------|
| 1 | Why 90% of Truck Buyers Regret This Choice Within 3 Years | fear charge | "truck buyer regret" | … |
| 2 | The 5 SUVs With the Lowest Cost of Ownership in 2025 | 常青高搜量 listicle | … | … |
```

## 重建標註

- `<ROLE> You are an Experienced Faceless YouTube Channel Strategist.` + 「You have already completed a reverse-engineering analysis … niche mechanics, title breakdowns and …」為**原文露出**。
- 「Priority Video Selection」表格 + 四欄（Video Idea / Why It Earns Early Traction / Search Term Targeted / Subscribe Trigger）+ #1 truck buyer / #2 SUV 範例 = **原文摘要明確記載**。
- `<TASK>/<OUTPUT>` 結構化包裝與「不要編造搜尋量」護欄為**重建**，語義忠於原文。
