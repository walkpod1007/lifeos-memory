---
name: triad-tools
description: 三大金剛 CLI 派工路由：Claude Code/Codex/MiniMax 角色定位。觸發：三大金剛、派工、委派、用 codex、用 mini-agent
---

> ⚠️ 本檔角色定位若與 `rules/model-dispatch.md` 的現況表衝突（型號可用性、派工鐵則），**以 model-dispatch 為準**（它每次修訂都實查環境；2026-07-03 起）。

# 三大金剛派工（Triad）

## Overview

三家 CLI 各有所長，路由到對的工具不浪費算力。細節流程走 task-sop；本檔只管**角色定位**。2026-04-22 加入 GLM 與 MiniMax（mini-agent）；**2026-06-15 Gemini 退役**（OAuth 6/18 停用 + headless 未支援，見 [[project_gemini_cli_deprecation_agy]]）——它原本的「網路爬梳 / YouTube 解析」改由 **Opus 主 session 自身的 WebSearch / WebFetch** 接手，「長 context 讀多檔」改派 mini-agent（200K）或 codex。**2026-06-15 GLM 退役**（智譜季訂閱到期）；省額度執行改回 mini-agent / 直接 Opus 子代理。

## 角色定位

| 金剛 | 預設定位 | 強項 | 何時**不要**派 | 計費 |
|------|---------|------|---------|------|
| **Claude Code (Opus)** | **派工執行預設** | 有 memory、有脈絡、長任務、跨檔改動、plan 模式、完整 MCP 工具鏈 | 要獨立視角時（會被自己脈絡帶偏） | Anthropic 訂閱 |
| **Codex CLI** | 獨立二意見 + 紅隊 | 紅隊 / code review、web search（技術選型 / 即時資訊）、無狀態小工具 | 要專案脈絡的設計、多輪迭代 | OpenAI |
| **MiniMax (mini-agent)** | **長跑執行者** | 200K context、256 experts MoE、long-chain tool calling（SWE-Pro 56%、Terminal Bench 57%）、token plan 吃到飽、能跑 100 輪迴圈 | 需要即時互動、需要主 session 的 MCP 整合、需要細緻 CWE / 語意精準度 | MiniMax token plan |

### 為什麼 Opus 是派工中心

有 memory、有 plan、有完整 MCP 工具鏈，**省掉每次重新 brief 的成本**。其他兩家不記事，是 Opus 的顧問/工人而不是代班。分工模型：

- Codex = 技術顧問兼紅隊（也有 web search）
- mini-agent = 你睡覺時還在跑迴圈的忍者
- （網路爬梳/研究 = Opus 自己用 WebSearch/WebFetch，不再外派）

### 架構設計歸類

| 任務類型 | 派給 | 理由 |
|---------|------|------|
| 設計一個新模組 | **Opus + Plan** | 脈絡夠、要判斷 |
| A 架構 vs B 架構哪個好 | **Codex 二意見** | 獨立判斷才有意義 |
| 讀完這 10 檔告訴我結構 | **mini-agent**（200K）或 **Codex** | 長 context / 獨立視角 |
| 業界現在怎麼做 X | **Opus WebSearch** 或 **Codex web search** | 主 session 自帶網路工具，不用外派 |
| 同題想聽第三聲意見 | **Codex 二意見** | 獨立判斷才有意義 |
| 跑 100 輪修 bug-fix-test 迴圈 | **mini-agent** | 長任務 + token plan 便宜 |
| 批次掃整個 repo 改 style | **mini-agent** | 不怕跑久 |
| 夜間 / 背景執行的任務 | **mini-agent** | non-interactive 直跑 |
| 單檔 code review | 直接 Opus or Codex | 不值得動三家 |

## 硬規則

- 一兩行小修 → 直接 edit，不派工
- 展開 ≥ 3 檔 / 動規則層 / 跨 skill / 改架構 → 走 task-sop 五段式
- 預期 ≥ 10 步工具呼叫 or 多輪迴圈 → 優先考慮 mini-agent 長跑（省 Anthropic 額度 + 不綁 session）

## 派工模板

> 網路盤查/研究：Opus 主 session 直接用 WebSearch / WebFetch，不再有 Gemini 外派模板。

### Codex（工程審驗 / 紅隊）

```bash
# 非互動一次性
codex exec "<prompt>"
cat prompt.txt | codex exec -

# 互動限定目錄
codex -C <dir> --no-alt-screen

# 非互動限定目錄
codex exec -C <dir> "<prompt>"
```

### Claude Code (Opus)（長流程 + MCP 生態）

```bash
claude           # REPL
claude -p "<q>"  # 一次性 print
```

### MiniMax (mini-agent)（長跑執行者）

```bash
# REPL（互動）
mini-agent -w <workspace_path>

# 非互動一次性（給 opus 派工用）
mini-agent -w <workspace_path> --task "<詳細任務描述>"

# 查 log（Mini-Agent 把每次 run 記到 ~/.mini-agent/log/）
mini-agent log                    # 列最近 log
mini-agent log <filename>         # 讀特定 log
```

**派給 mini-agent 的任務描述要寫足以下五段：**

1. **目標**：一句話說要什麼結果
2. **輸入**：要讀哪些檔 / 指定 workspace 路徑
3. **產出**：要寫哪些檔 / 或輸出什麼格式
4. **驗收**：怎麼判定完成（測試通過？檔案存在？指令退出 0？）
5. **限制**：不能動什麼、最多跑幾步（對應 max_steps）

範例任務包：

```
目標：修好 app.py 全部安全漏洞，並用 pytest 驗證。
輸入：/tmp/redteam-test/app.py（8 個漏洞見前一次紅隊報告）
產出：
  - /tmp/redteam-test/app_fixed.py（修好的版本）
  - /tmp/redteam-test/test_app.py（每個漏洞一個 test case）
驗收：cd /tmp/redteam-test && python -m pytest test_app.py → all pass
限制：不要動 app.py 原檔、步數上限 30 步
```

## 派工標準作業（SOP）

1. **鎖工作目錄**：`-C` (codex) / `-w` (mini-agent) / CWD (claude)
2. **留痕**：`stdout | tee logs/<task>.log`（mini-agent 自動記 `~/.mini-agent/log/`）
3. **互動開 PTY**：Codex / Claude / mini-agent 互動模式
4. **能沙盒就沙盒**（Codex）：`--sandbox --ask-for-approval`
5. **長任務一律 mini-agent**：> 10 步 or 多輪迴圈 → 優先 mini-agent --task，讓 Opus 主 session 不卡

## 紅隊實測對比（2026-04-22 歷史快照，Gemini / GLM 已退役僅留紀錄）

同一題（Flask app 含 8 個漏洞），終極成績：

| 家 | 核心 8 個 | Bonus | CWE 精準度 | Agentic 亮點 |
|----|:-:|:-:|:-:|:---|
| Codex | 8/8 | 2 (CWE-916, CWE-79) | ⭐⭐⭐⭐⭐ 最精準 | — |
| ~~GLM-4.6~~（退役） | 8/8 | 2 (CWE-306, CWE-94) | ⭐⭐⭐⭐ | **主動算出 MD5 明文="password"** |
| ~~Gemini~~（退役） | 8/8 | 1 (CWE-79) | ⭐⭐⭐⭐ | — |
| M2.7 (mmx text) | 8/8 | 0 | ⭐⭐⭐⭐ | 格式乾淨 |
| M2.7 (mini-agent) | 8/8 | 0 | ⭐⭐⭐ 兩個 CWE 標錯 | 主動用 read_file tool |

**教訓**：
- 單檔小題分不出 agentic 深度 → 要大任務才看得出 mini-agent 真價值
- GLM 的「破 MD5」最有 agentic 味，其他家只回答不動手
- mini-agent 格式漂亮但 CWE 標錯，**紅隊位建議留給 codex**

## Life-OS 算力分配

| 機器 | 角色 | 用途 |
|------|------|------|
| 德瑪（Mac mini M4 Pro） | 主力 | Claude Code 長流程、mini-agent 長跑 |
| 小蝦（辦公室機） | 客服 | LINE@ 自動回覆 |

## 延伸文件

- `~/life-os/skills/mini-agent/SKILL.md` — mini-agent 詳細設定
- `~/.agents/skills/mmx-cli/SKILL.md` — MiniMax 官方 mmx 媒體生成

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
