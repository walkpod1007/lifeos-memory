---
name: task-sop
status: stable
description: 五段式任務 SOP——盤查 → 派工單 → 審驗 → 執行 → 紅隊。觸發詞「走 SOP」。
version: 1.3.0
author: 阿普 + Claude Opus
triggers:
  - "走 SOP"
metadata:
  openclaw:
    emoji: "📋"
    category: workflow
    tags: ["sop", "workflow", "codex", "opus", "multi-model"]
    requires:
      bins: ["codex"]
    health:
      smokeTests:
        - id: "codex-cli"
          command: "command -v codex"
          success: "exit=0"
          tolerance: "none"
---

# Task SOP（五段式）

任何**展開動作 ≥ 3 個檔案 / 動規則層 / 跨 skill / 改架構**的任務，使用者喊「**走 SOP**」即啟動。小修小補（typo、單檔調參數）不走。

## 為什麼

人腦+Opus 容易掉進「拿現有文件做既定印象」的坑——前人寫的 doc 可能過期、可能對著錯地方做、可能有未更新的隱性假設。SOP 強制每次任務開工前**實地盤查**校正 Opus 的前提；執行後**用第三方紅隊**檢查偏移。

> **獨立性取捨（2026-06-15 Gemini 退役後）**：本機盤查仍走 **Codex（獨立模型）**，這是「校正 Opus 偏見」的核心；網路盤查改由 Opus 自己 WebSearch/WebFetch——那是「抓外部來源事實」，靠的是出處可查證而非模型獨立性。**遇到高偏見/爭議性判斷題，仍應另派 Codex 二審**，別只信 Opus 自查。

## 五個 phase

| Phase | Who | 工具 | 產出 |
|---|---|---|---|
| 1. 盤查 | **Codex**（本機）／**Opus WebSearch**（網路） | `codex exec` ／ WebSearch+WebFetch | 現況快照 + 既有提案的衝突點 |
| 2. 派工單 | Opus | Write | `worktickets/YYYY-MM-DD-<slug>.md` |
| 3. 審驗 | Codex | `codex exec` | 紅旗清單 → Opus 修派工單到通過 |
| 4. 執行 | Opus（或子代理） | Edit/Write/Bash | code/file 改動 |
| 4.5 驗收閘 | 機械 | `scripts/verify-ticket.sh` | 跑成功條件驗法，全過才放行（FAIL 硬停） |
| 5. 紅隊 | Codex | `codex exec` 讀 diff + 派工單 | 偏移／回歸／漏網報告 |

### Phase 1 路由（重要）

| 任務性質 | 派誰 | 為什麼 |
|---|---|---|
| 本機檔案／目錄爬梳、Vault 結構盤點、code base 探勘 | **Codex** | 原生在本機 cwd 跑，沒 sandbox 限制、獨立視角 |
| 網路搜尋、外部資料源比對、即時新聞 | **Opus 主 session（WebSearch / WebFetch）** | 主 session 自帶網路工具，不必外派；Gemini 已退役（2026-06-15） |
| 兩者都需要 | 拆兩段：Codex 盤本機 + Opus 自己 WebSearch 補網路 | 各用對工具 |

> **2026-06-15 起 Gemini 退役**（OAuth 6/18 停用 + headless 未支援，見 [[project_gemini_cli_deprecation_agy]]）。網路盤查改由 Opus 主 session 自己用 WebSearch/WebFetch 做，不再外派 CLI。

## Phase 1 — 盤查

**本機任務（含 Vault、code base、設定檔）走 Codex**；網路／即時資訊由 Opus 主 session 自己用 WebSearch / WebFetch 查。

### 1A. 本機任務 → Codex（預設）

**重要**：
- `codex exec` 預設會問「確認」才開掃，必須加 `--full-auto`（sandboxed 自動執行）
- read-only 任務再加 `--sandbox read-only` 雙重保險
- **`--full-auto` 還不夠**——gpt-5.4 model 仍會回「預覽... 回我確認」字串卡住非互動流程。Prompt 開頭必須明寫「**直接開讀，不要回任何「預覽」「確認」「待命」字串，這是非互動 headless 模式**」

```bash
codex exec --full-auto --sandbox read-only "你是 task-SOP phase 1（盤查）。任務：<TASK>。

前手提案（如果有）：
- <提案 A>
- <提案 B>

請用 ls/read/grep 實地盤查（不要相信前手敘述，自己看），回答：
1. 任務涉及的實際檔案／目錄狀態
2. 既有結構長什麼樣（必要時抽樣讀檔推測用途）
3. 前手提案套用到實況會有哪些衝突
4. 一句『前手提案哪個比較貼近實況』的判斷

涉及目錄（自己 ls 進去看，不要硬背前手描述）：
- <目錄 1 絕對路徑>
- <目錄 2 絕對路徑>

回報 800 字內，bullet 為主。"
```

Codex 預設 read-only，不會動檔。需要時用 `--sandbox read-only` 強制（一般不用，預設就是）。

### 1B. 網路／即時資訊 → Opus 自己 WebSearch / WebFetch

不外派——主 session 直接用 `WebSearch`（找來源）+ `WebFetch`（讀全文、抽事實），盤查時要回答的還是那四點：
1. 找到的原始來源連結
2. 來源彼此的時間順序與引用關係
3. 二手報導跟原文的偏差
4. 本任務真正該對焦的事實

引用務必標出處 URL（憲法引用紀律）。YouTube 內容走 `watch-video` / youtube-grabber skill，不再靠 gemini。

### 1C. 兩者都要

Codex 盤本機 + Opus 自己 WebSearch 補網路，各用對工具，不硬塞同一個 CLI。

## Phase 2 — 派工單（Opus）

把 phase 1 結果消化後，寫 `worktickets/YYYY-MM-DD-<slug>.md`。模板：

```markdown
# 派工單：<title>

- 日期：YYYY-MM-DD
- 觸發者：<使用者一句話原始要求>
- Phase 1 盤查結論連結／摘要：<...>

## 目標（一句話）
<...>

## 範圍
- 動的檔案／目錄（明列）
- 不動的檔案／目錄（明列，避免範圍蔓延）

## 成功條件（可驗證 — 看結果不看過程）
> 開工前先寫死（spec-first）。每條都要能用一個**具體指令或觀察**驗證，且驗的是「**結果對不對**」而非「步驟有沒有跑完」。寫不出驗法的條件＝還沒想清楚，回去拆細。
- [ ] <條件 1> — 驗法：`<指令／觀察，如 grep -c 'X' file 應回 0>`
- [ ] <條件 2> — 驗法：`<...>`

## 不做什麼
- <明確排除的動作>

## 風險與取捨
- <已知風險>
- <已放棄的選項與原因>

## 執行步驟
1. <step>
2. <step>
```

**派工單寫完先給使用者看一眼再進 phase 3**（避免拿錯方向去問 codex）。

## Phase 3 — 審驗（Codex）

```bash
codex exec "你是 task-SOP phase 3（審驗）。讀以下派工單，用紅旗清單形式回報：

派工單路徑：$HOME/life-os/worktickets/<file>.md

請檢查：
1. 範圍蔓延？（成功條件 vs 動的檔案是否對得上）
2. 前提錯誤？（依賴的事實有沒有過期／搞錯）
3. 工具錯誤？（用了不適合的 skill／script）
4. 缺失？（明顯遺漏的步驟）
5. 不做什麼有沒有覆蓋常見坑

每點給一個『紅／黃／綠』判斷。回報 600 字內。"
```

收到報告後，Opus 修派工單到全綠或可接受的黃，**再進 phase 4**。如有紅旗，回報使用者並停下來討論。

## Phase 4 — 執行（Opus）

照修好的派工單動工。可派子代理。**只動派工單列出的範圍**——若中途發現要動範圍外的東西，停下來回 phase 2 改派工單，不要硬幹。

### 4.x 步驟中途驗收點（Loop Engineering）

每完成派工單「執行步驟」中的一個項目，**在繼續下一步之前**，輸出一個驗收報告：

```
✓ Step N 完成：<實際做了什麼（一行）>
  中間狀態：<可觀察的具體事實，例如 grep 結果、file 路徑、輸出值>
  下一步：<繼續 / 停下等確認 / 發現範圍外問題需回 phase 2>
```

**規則**：
- 每個執行步驟都要輸出，不能跳過
- 「中間狀態」必須是可觀察的事實，不能是「感覺差不多了」
- 發現預期外情況（檔不存在、驗法失敗、範圍超出）→ **立刻停下**，不要繼續後面的步驟

> **背後邏輯（Harness + Loop Engineering）**：AI 失控最常發生在「中途偏離但沒人知道」，等到最後紅隊才發現已經太晚。逐步驗收讓偏移在每個步驟就被發現，而不是累積到收尾才爆。

### 4.z 完成即關單（Close the Loop）

「做完」的定義包含記帳。執行完所有步驟後，**同一輪、不換 session、不留到收尾**做完三件事才算完成：

1. 派工單末尾 append `## 執行結果` 段（列實際動的檔、commit hash if any）
2. 回填驗收 checkbox（做到哪勾到哪；沒做的保持未勾並寫一行卡點）
3. 更新工單開頭狀態行——**注意時序，Phase 4 完成 ≠ DONE**：
   - Phase 4 步驟全過 → 標 `狀態：READY_FOR_QA（日期）`（等 Phase 4.5 驗收閘＋Phase 5 紅隊）
   - Phase 4.5 + Phase 5 都綠燈、使用者確認收工 → 才標 `狀態：DONE（日期）`
   - 部分完成 → `狀態：部分完成（日期）＋殘留清單`

> **背後邏輯**：漏統計的根因是「完成」與「記帳」分離、中間無強制閉環（2026-07-02 單日對帳抓到 6 例，含 6/14 已 commit 的單掛「未 commit」狀態 18 天）。關單不是收尾雜務，是執行的最後一步——watchdog 隨時可能咬斷 session，回填必須跟做完在同一個原子動作裡，不能等「之後再補」。

## Phase 4.5 — 驗收閘（機械跑，無人值守的第一道防線）

執行後、進紅隊前，**先機械驗收**。這道閘把「人類已寫進派工單的驗法」逐條跑一遍，全過才放行——是 Tester 棒，不是 Coder（它驗結果，不替 agent 做事、不新增自主權）。

```bash
bash $HOME/life-os/scripts/verify-ticket.sh worktickets/YYYY-MM-DD-<slug>.md
```

它抓「## 成功條件」段每條的 `驗法：\`<cmd>\``逐一執行，並 shellcheck 改動的 .sh：
- **exit 0**：全 PASS → 放行進 Phase 5 紅隊。
- **exit 1**：有 FAIL → **硬停**，回 Phase 4 修到全 PASS，不准進紅隊/收工。
- **exit 2**：找不到派工單檔。
- **exit 3**：成功條件沒寫可機械驗的驗法 → 回 Phase 2 補（Phase 2 模板已要求每條附驗法）。

> **驗法是用授權 shell 執行（非沙箱、有完整權限）**，不是「安全唯讀」——責任在寫工單的人：只放可信、唯讀斷言（grep/test/ls…），別放會改檔的命令。每條驗法須是**單行** shell command（解析只抓單行單組反引號）。每條在子 shell 隔離跑，單條驗法無法污染其他條的判定。
> **無人值守邊界**：本閘是「自動驗證」，安全增量。把整條 SOP 改成「無人值守自動寫檔」是另一回事（寫入安全風險），未經護欄設計前不啟用。

## Phase 5 — 紅隊（Codex）

```bash
codex exec "你是 task-SOP phase 5（紅隊）。讀派工單跟最新 git diff，回報：

派工單：$HOME/life-os/worktickets/<file>.md
Diff 取得：cd $HOME/life-os && git diff HEAD~1 (或 git diff)

請檢查：
1. 偏離派工單嗎？（動了範圍外的東西？）
2. 成功條件真的滿足？（逐條驗）
3. 引入回歸／副作用？
4. 漏掉什麼派工單沒列但顯然該做的？
5. 有無秘密／敏感資料寫進檔？

**發現請照槓桿（impact ÷ effort × confidence）由高到低排序**，高槓桿的先講；每點標 impact、effort、confidence，讓我先處理最划算的。換算：impact 高=3/中=2/低=1；effort 低=1/中=2/高=3；confidence 0–1。分數 = impact ÷ effort × confidence，高者先列。不確定是不是真問題的標 confidence 低，別當鐵口。

最後給『可上線 / 需修補 / 回 phase 2』三選一判決。回報 600 字內。"
```

使用者看到紅隊報告後決定是否收工。

## 跳過 SOP 的情況

- typo、單檔改 1 行、調個參數
- 純 read-only 探查（沒要動檔）
- 已經在 SOP 中段，使用者明確說「不用走完，直接做 X」

## 失敗模式

- **Codex phase 3 全紅**：表示派工單前提錯太多，回 phase 1 重盤查（不要硬改派工單）。
- **Phase 5 判『回 phase 2』**：表示執行過程偏離太遠，退回派工單階段重來，**不要打補丁**。

## 派工單存檔位置

```
$HOME/life-os/worktickets/YYYY-MM-DD-<slug>.md
```

不索引到 MEMORY.md（短期工件，做完就丟在那供 git 追溯）。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
