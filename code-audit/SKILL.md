---
name: code-audit
status: draft
description: GitNexus 知識圖譜驅動的程式碼健檢。一次跑完架構掃描 + 批次審計 + 匯報。觸發詞：大檢查、code audit、健檢、程式碼掃描。
version: 0.2.1
author: 阿普 + Claude Opus
triggers:
  - "大檢查"
  - "code audit"
  - "健檢"
  - "程式碼掃描"
  - "codebase audit"
metadata:
  openclaw:
    emoji: "🔬"
    category: workflow
    tags: ["gitnexus", "audit", "mini-agent", "codex", "code-quality"]
    requires:
      bins: ["gitnexus", "codex"]
      optional_bins: ["mini-agent"]
    health:
      smokeTests:
        - id: "gitnexus-cli"
          command: "command -v gitnexus"
          success: "exit=0"
          tolerance: "none"
        - id: "gitnexus-index"
          command: "gitnexus status 2>&1 | grep -q 'up-to-date'"
          success: "exit=0"
          tolerance: "warn"
        - id: "codex-cli"
          command: "command -v codex"
          success: "exit=0"
          tolerance: "none"
---

# Code Audit — GitNexus 驅動的程式碼健檢

## 定位

read-only 健檢工具。不修改任何檔案，不取代 task-sop Phase 5 紅隊（task-sop 管改動任務的品質閘門，code-audit 管全局結構健康度）。底層符號探索、impact、debugging 複用 gitnexus-* 系列 skill 的能力，code-audit 是批次編排器。

## 前置 Gate

啟動時依序檢查，任一失敗則停止並輸出原因：

```bash
# 1. CLI 存在
command -v gitnexus || { echo "ABORT: gitnexus CLI not installed"; exit 1; }

# 2. repo 已索引且 up-to-date
STATUS=$(gitnexus status 2>&1)
echo "$STATUS" | grep -q "up-to-date" || {
  echo "ABORT: index not up-to-date. Run: gitnexus analyze"
  echo "$STATUS"
  exit 1
}

# 3. 取 meta 供後續使用
META=$(cat .gitnexus/meta.json 2>/dev/null) || { echo "ABORT: .gitnexus/meta.json not found"; exit 1; }
```

## 三階段流程

### Phase 1：圖譜掃描（主 session，~2 分鐘）

主 session 依序執行以下 GitNexus CLI 命令。每個查詢的 JSON 輸出存入 `drafts/code-audit-phase1-YYYY-MM-DD.json` 對應欄位。任一查詢失敗記錄 error 但不中斷，報告標註該項為 `SKIPPED`。

**注意**：GitNexus LadybugDB schema 用單一 `CodeRelation` edge type，以 `type` 屬性區分關係種類（`CALLS`、`IMPORTS`、`EXTENDS` 等）。Node properties 用 `filePath`（非 `file`）、`symbolCount`（非 `size`）、`heuristicLabel`（非 `label`/`name`）。schema 可能隨 GitNexus 版本變動——查詢失敗時先用 `gitnexus cypher "CALL table_info('CodeRelation')"` 確認當前 schema 再修查詢。

```bash
# 1. 叢集總覽
gitnexus cypher "MATCH (c:Community) RETURN c.heuristicLabel, c.symbolCount, c.cohesion ORDER BY c.symbolCount DESC"

# 2. 孤立節點偵測——沒有 usage-type incoming edge 的函式（死程式碼候選）
#    只看 CALLS/IMPORTS/EXTENDS/IMPLEMENTS/ACCESSES，排除 structural edge（CONTAINS/DEFINES）
gitnexus cypher "MATCH (f:Function) WHERE NOT EXISTS { MATCH ()-[r:CodeRelation]->(f) WHERE r.type IN ['CALLS','IMPORTS','EXTENDS','IMPLEMENTS','ACCESSES'] } RETURN f.name, f.filePath ORDER BY f.filePath"

# 3. 循環依賴偵測——檔案層級的雙向 import
gitnexus cypher "MATCH (a:File)-[r1:CodeRelation {type: 'IMPORTS'}]->(b:File)-[r2:CodeRelation {type: 'IMPORTS'}]->(a) WHERE id(a) < id(b) RETURN a.filePath, b.filePath"

# 4. 核心模組影響半徑排名——被最多其他節點依賴的 top 20（只計 usage-type edges）
gitnexus cypher "MATCH ()-[r:CodeRelation]->(t) WHERE r.type IN ['CALLS','IMPORTS','EXTENDS','IMPLEMENTS','ACCESSES'] RETURN t.name, t.filePath, count(r) AS deps ORDER BY deps DESC LIMIT 20"

# 5. 執行流程清單
gitnexus cypher "MATCH (p:Process) RETURN p.heuristicLabel, p.entryPointId, p.stepCount, p.processType ORDER BY p.stepCount DESC"

# 6. 過度耦合偵測——fan-out > 10 的函式（只計 usage-type edges）
gitnexus cypher "MATCH (f:Function)-[r:CodeRelation]->(t) WHERE r.type IN ['CALLS','IMPORTS','EXTENDS','IMPLEMENTS','ACCESSES'] WITH f, count(r) AS fanout WHERE fanout > 10 RETURN f.name, f.filePath, fanout ORDER BY fanout DESC"

# 7. 變更影響（如果有 uncommitted changes）
gitnexus detect-changes 2>/dev/null || echo '{"changes": "none"}'
```

**Phase 1 產出 JSON schema**：

```json
{
  "meta": { "repo": "string", "commit": "string", "date": "string", "nodes": 0, "edges": 0, "clusters": 0 },
  "communities": [{ "label": "string", "symbolCount": 0, "cohesion": 0 }],
  "orphanCandidates": [{ "name": "string", "filePath": "string" }],
  "cycles": [{ "fileA": "string", "fileB": "string" }],
  "hotspots": [{ "name": "string", "filePath": "string", "deps": 0 }],
  "processes": [{ "label": "string", "entryPointId": "string", "stepCount": 0, "type": "string" }],
  "highFanout": [{ "name": "string", "filePath": "string", "fanout": 0 }],
  "changes": "object | 'none'",
  "errors": [{ "query": "string", "error": "string" }]
}
```

CLI 輸出是 `{ "markdown": "...", "row_count": N }` 格式。主 session 負責從 markdown table 解析為上述 schema（用 jq 或腳本處理），command failure 記入 `errors[]`。

### Phase 2：批次審計（mini-agent / codex，~10-20 分鐘）

根據 Phase 1 的叢集清單分批派工。

**分批策略**：
- 以 symbolCount 為主要維度（非叢集數量），每批累積 symbolCount ≤ 200
- 單一叢集 symbolCount > 200 時拆為 symbol-level split（按 filePath 前綴分組）
- 叢集為 0 時跳過 Phase 2，直接進 Phase 3（報告標註「無叢集，僅 Phase 1 結果」）
- 每批一個 mini-agent 任務，最多同時 3 個並行

**每批審計項目**：

| 項目 | 查法 | 嚴重度 | 工具 |
|------|------|--------|------|
| Error handling 覆蓋 | async 函式有無 try-catch 或 .catch | critical | rg + gitnexus context |
| 安全漏洞 | command injection、path traversal、未驗證外部輸入 | critical | rg + gitnexus context |
| 命名一致性 | 同叢集內函式/變數命名風格是否統一 | warning | gitnexus context |
| 重複邏輯 | 叢集內/跨叢集高度相似的程式碼段 | warning | rg + Read |
| 未使用的 export | export 但無 incoming CodeRelation 的符號 | info | gitnexus cypher |
| 過度耦合 | fan-out > 10（Phase 1 已偵測，此處做 detail review） | warning | gitnexus impact |
| 缺型別 | TypeScript 檔中 any 使用頻率 | info | rg |

**mini-agent 派工**：

主 session 先產出 batch 任務檔 `drafts/code-audit-batch-N.json`：

```json
{
  "batch_id": 1,
  "repo_path": "$HOME/life-os",
  "community_labels": ["line-lobster-webhook", "token-watchdog"],
  "symbol_uids": ["Function:plugins/line-lobster/webhook.ts:handleEvent", "Function:scripts/token-watchdog.sh:main"],
  "output_file": "drafts/code-audit-findings-batch-1.txt",
  "read_only": true
}
```

然後派工：

```bash
mini-agent -w ~/life-os --task "$(cat <<'TASK'
你是程式碼審計員。只讀模式——不得修改任何檔案。

任務檔：drafts/code-audit-batch-1.json
讀取任務檔取得 community_labels 和 symbol_uids。

對每個 symbol：
1. gitnexus context <symbol_name> -f <file_path> 查 360 度視圖
2. gitnexus impact <symbol_name> -f <file_path> 查影響半徑
3. rg 搜尋相關檔案的 error handling、any 使用、安全疑慮

審計項目：error handling、安全漏洞、命名一致性、重複邏輯、未使用 export、過度耦合、缺型別。

輸出格式（每個 finding 一行）：
[SEVERITY] [FILE:LINE] 描述 | evidence: <具體程式碼或查詢結果摘要>

SEVERITY = critical / warning / info
結果寫到 drafts/code-audit-findings-batch-1.txt
TASK
)"
```

**codex 備用路線**（mini-agent 不可用時）：

```bash
# codex read-only sandbox 不能寫檔，結果由主 session 從 stdout 重導
codex --full-auto --sandbox read-only exec "$(cat <<'TASK'
讀取 drafts/code-audit-batch-1.json 取得審計目標。
對每個 symbol 用 gitnexus context/impact 查關係，rg 搜尋 error handling 和安全疑慮。
輸出 [SEVERITY] [FILE:LINE] 描述 | evidence: <摘要>
所有結果輸出到 stdout，不要寫入任何檔案，不改任何原始碼。
TASK
)" > drafts/code-audit-findings-batch-1.txt
```

**Phase 2 產出**：每批一個 `drafts/code-audit-findings-batch-N.txt`，格式統一

### Phase 3：匯報（主 session，~1 分鐘）

1. 收集所有 `drafts/code-audit-findings-batch-*.txt`
2. 去重（同一 FILE:LINE 的 finding 只保留最高嚴重度）
3. 按嚴重度分組：critical → warning → info
4. 標註 coverage：哪些 batch 成功、哪些失敗/跳過
5. 產出結構化報告

**報告格式**：

```
=== Code Audit Report ===
Repo: life-os
Date: YYYY-MM-DD
Index: [commit] ([nodes] nodes / [edges] edges / [clusters] clusters)
Coverage: [N]/[total] batches completed

--- CRITICAL ([count]) ---
[FILE:LINE] 描述 | evidence: ...
...

--- WARNING ([count]) ---
[FILE:LINE] 描述 | evidence: ...
...

--- INFO ([count]) ---
[FILE:LINE] 描述 | evidence: ...
...

--- PHASE 1 STRUCTURAL ---
Orphan candidates: [count]
Circular dependencies: [count]
High fan-out functions: [count]
Execution flows: [count]

--- COVERAGE GAPS ---
Skipped files (>512KB): [list]
Failed scope extraction: [list]
Failed batches: [list]

--- SUMMARY ---
Total findings: N (C critical / W warning / I info)
Top 5 hotspot files: ...
False positive note: 自動審計 finding 可能有誤判，critical 級必須人工確認後才可行動。
```

**報告存放**：`cold-storage/code-audit-YYYY-MM-DD.md`

**推播規則**：
- termi 觸發：直接在 terminal 顯示，不推 LINE
- LINE 觸發：用 reply 回覆摘要（critical 數 + top 3 findings + 報告路徑）。如需 push（reply token 過期），走黃線確認（與 runbook confirmation gate 一致）

## 已知限制

- **Schema 版本耦合**：Cypher 查詢依賴 GitNexus v1.6.x 的 LadybugDB schema（`CodeRelation` edge + `type` 屬性）。版本升級可能改 schema，導致查詢失敗。Phase 1 遇錯時應先用 `CALL table_info()` 確認 schema 再修正。
- **FTS 不可用**：v1.6.3 已知 bug，BM25 搜尋暫不可用，Cypher + 向量搜尋正常。
- **Python scope 部分失敗**：token_extractor.py 等檔案的函式不在圖譜中，形成安全掃描盲區。
- **大檔案跳過**：超過 512KB 的 generated/vendored 檔被跳過，同為掃描盲區。報告 COVERAGE GAPS 區段會列出。
- **叢集邊界非人工定義**：自動偵測的叢集不一定跟人類認知的模組邊界對齊。
- **圖譜非萬能**：知識圖譜不能取代 AST/型別檢查。`any` 使用、try-catch 覆蓋、相似程式碼偵測仍需 `rg` / TypeScript compiler / linter 輔助（Phase 2 的審計項目已包含 rg 搜尋）。
- **False positives**：自動審計 finding 會有誤判，critical 級必須人工確認後才可行動。
- **Batch 部分失敗**：mini-agent/codex 可能部分 batch 失敗或 timeout。報告需標註 coverage 百分比和失敗 batch 清單。
- **mini-agent context window**：單批 symbolCount 不能太大，超過 200 會拆分。

## 參數（skill 層級，由主 session 解釋，非 CLI flag）

| 參數 | 預設 | 狀態 | 說明 |
|------|------|------|------|
| scope | 全 repo | v0.2 可用 | 指定子目錄（如 `plugins/`），Phase 1 查詢加 filePath 前綴過濾 |
| severity | all | v0.2 可用 | 報告只顯示特定嚴重度以上 |
| skip-phase2 | false | v0.2 可用 | 只跑 Phase 1 圖譜掃描，跳過批次審計 |
| parallel | 3 | v0.2 可用 | Phase 2 同時跑幾個 batch |
| report-to-line | auto | v0.2 可用 | LINE 觸發時用 reply 回摘要，termi 不推 |

這些參數由使用者在觸發時口頭指定（如「大檢查 plugins/ 只看 critical」），主 session 解析後傳入流程。無獨立 CLI 入口。

## 維護

- GitNexus 索引過期時 PostToolUse hook 會提醒，跑 `gitnexus analyze` 更新
- 報告存 cold-storage，不進 git（避免 diff 噪音）
- Phase 2 的審計項目可隨 pitfall 卡片新增而擴充
- Cypher 查詢如因 schema 變更失敗，更新本 SKILL.md 的查詢語句並提升 version

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
