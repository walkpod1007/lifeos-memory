---
name: mini-agent
description: Mini-Agent (MiniMax M2.7) agentic coding CLI，Anthropic-API 相容。觸發：mini-agent、MiniMax、M2.7、長跑 agent、不要燒 Claude quota
---

# mini-agent — MiniMax M2.7 agentic coding CLI

Mini-Agent 是 MiniMax 官方提供的 agentic coding CLI，把 M2.7 包成 Claude Code 對等的 agent（Anthropic API 相容，支援 interleaved thinking、shell、file ops）。

> ✅ **安裝狀態（2026-04-22）**：已安裝。啟動驗證通過，讀 15 個 Claude Skills、載 8 個 tools（bash / bash-output / bash-kill / file ops / skill / session-note）。MCP config 未配（`mcp.json` 可選），system prompt 用 default。

## 觸發時機

- 使用者要跑 M2.7 做 agentic coding
- 要用完整 200K context + 256 experts 的能力
- 比對同一題 Claude vs GLM vs M2.7 的 agentic 決策

## 安裝（待授權）

```bash
# 1. uv 已裝（/opt/homebrew/bin/uv 0.9.28）
# 2. 裝 Mini-Agent
uv tool install git+https://github.com/MiniMax-AI/Mini-Agent.git

# 3. 執行 setup 初始化 config
mini-agent setup    # 或 init，實際以 repo README 為準

# 4. 配置 ~/.mini-agent/config/config.yaml
# api_base: "https://api.minimax.io"
# model: "MiniMax-M2.7"
# max_steps: 100
```

## 啟動

```bash
mini-agent                              # 當前目錄當 workspace
mini-agent --workspace /path/to/project # 指定 workspace
```

## 能力範圍

- **File system + Shell**：內建工具
- **Persistent memory**：跨 session 記憶
- **Context management**：自動壓縮
- **15 professional skills**：文件處理、dev 工作流
- **Anthropic API compatible**：可用 Anthropic SDK 的介面呼叫
- **Interleaved thinking**：支援思考/行動交錯（類 Claude Code extended thinking）

## Token Plan 注意

使用者目前 MiniMax token plan 對應 quota：
- `MiniMax-M*` text：1500/interval ✅
- `coding-plan-vlm` / `coding-plan-search`：1500/interval（Mini-Agent 內部工具）✅
- `image-01` / `speech-2.8-hd` / `video`：❌ 需 Plus plan

**M2.7 的 agentic coding 能跑，但多模態產出（圖/音/影）不含在現 plan。**

## 與 glm-code / Claude Code 的定位差異

| CLI | 後端 | API 協定 | 費用模式 |
|-----|------|----------|---------|
| `claude` | Anthropic | Anthropic 原生 | Anthropic sub |
| `glm-code` | 智譜 GLM-4.6/4.7 | Anthropic shim | 智譜 pay-per-token |
| `mini-agent` | MiniMax M2.7 | 獨立 CLI（Anthropic-style） | MiniMax token plan |

三者共存不打架：每個吃自己的 quota、config、memory。

## 派工模式

**主 session 啟動**型（類 glm-code / 真 claude）。
子代理只能透過 `mmx text chat` 直呼 MiniMax Messages API，不能啟 mini-agent REPL。

## 比對 mmx-cli

| 項目 | `mmx` | `mini-agent` |
|------|-------|--------------|
| 定位 | 媒體生成工具（文/圖/音/影/搜/視） | agentic coding CLI |
| 互動 | CLI 一次呼叫 | 進入 REPL，多步驟工具使用 |
| M2.7 text | `mmx text chat` | `mini-agent` 內部呼叫 |
| File/Shell 工具 | 無 | 有 |
| 計費 model | 同 token plan | 同 token plan（含 coding-plan-*） |

兩者**共用** `sk-c...zXRI` API key，不衝突。mmx 適合一次性生成，mini-agent 適合持續工作流。

## 故障排解

| 症狀 | 原因 | 修法 |
|------|------|------|
| `uv tool install` 被擋 | Sandbox 擋外部 code | settings.json 加 `Bash(uv tool install *)` permission |
| `your current token plan not support model, MiniMax-M2.7-highspeed` | Token plan 沒 highspeed | 改用 `MiniMax-M2.7`（預設） |
| 安裝後找不到 `mini-agent` 指令 | uv tool 的 bin 路徑沒進 PATH | `uv tool update-shell` 或 `export PATH="$HOME/.local/bin:$PATH"` |

## 延伸資源

- 官方 doc：https://platform.minimax.io/docs/token-plan/mini-agent
- GitHub：https://github.com/MiniMax-AI/Mini-Agent
- 模型頁：https://github.com/MiniMax-AI/MiniMax-M2

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
