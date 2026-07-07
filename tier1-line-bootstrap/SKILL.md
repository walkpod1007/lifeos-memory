---
name: tier1-line-bootstrap
description: 端到端建立新 Tier 1 LINE 群 session 全部資產。觸發：建新 LINE 群 session、bootstrap 新群組、retrofit line-<slug>
version: "2.0"
created: "2026-04-21"
metadata: {"clawdbot":{"emoji":"🏗️"}}
---

# tier1-line-bootstrap — 新 LINE 群 Tier 1 session bootstrap

> 觸發時機：使用者提供 groupId 要求建立獨立 LINE 群 session。
> 兩種模式：`bootstrap`（新建）/ `retrofit <slug>`（補救既有 slug 的缺）。

---

## 入口與參數

skill 入口**第一輪就列出此表**，使用者**一次給齊**，或缺欄時**一次問齊所有缺項**。禁止中途逐欄追問（違反 ADHD 摩擦規則）。

| 參數 | 必/選 | 格式 / 規則 | 防呆 |
|------|-------|------------|------|
| `groupId` | ✅ 必 | LINE 群組 ID，`C[0-9a-f]{32}` | 格式 regex 驗證；已存在於 bindings[] 則中止 |
| `slug` | 選（無預設） | 英數 + hyphen，如 `ita`。需有語意，**不從 groupId 後幾碼 derive** | `ws/line-<slug>/` / `scripts/claude-line-<slug>.sh` / `config/mcp-line-<slug>.json` / `.tier1.<groupId>` 任一存在則中止；不可等於既有 slug（line、line-note、line-talk 等） |
| `template` | 選（預設 `line-talk`） | `line-talk`（完整 chat）或 `line-note`（輕量節流） | 只接受這兩個值 |
| `description` | 選 | 一句話用途說明。未給預設 `<slug> 群組的獨立 session` | — |
| `vault_bg_path` | 選 | Vault 背景文件資料夾。三種寫法都接受：①絕對路徑；②`Vault/X/Y` 相對寫法（自動前綴 Vault 根）；③`Vault / X / Y` 帶空格寫法（自動 trim）| 解析後不存在則列該層候選 + WARNING，繼續 |
| `write_tier1_block` | 選（預設 `false`） | `true` 時同時寫 bindings.json 的 `tier1.<groupId>` block | — |

> **Fork 決策說明（slug 命名）**：slug 是後續所有路徑的基礎，一旦設定難以批改。這是唯一正當的中途停下詢問時機。但要一次問齊（不要問完 slug 再問 template 再問 description）。

---

## Phase A — Worker 可執行（工作層）

寫入 `ws/line-<slug>/` 工作層。可派 Agent 子代理執行。

### A1. 防呆檢查

```bash
REPO_ROOT="$HOME/life-os"
BINDINGS_FILE="$HOME/.claude/channels/line/bindings.json"

[[ "$GROUP_ID" =~ ^C[0-9a-f]{32}$ ]] || { echo "ERROR: groupId 格式錯誤"; exit 1; }

EXISTING_SESSION=$(jq -r --arg id "$GROUP_ID" \
  '.bindings[] | select(.match.id == $id) | .session' "$BINDINGS_FILE" 2>/dev/null)
[ -n "$EXISTING_SESSION" ] && { echo "ERROR: groupId 已綁 session=$EXISTING_SESSION"; exit 1; }

EXISTING_TIER1=$(jq -r --arg id "$GROUP_ID" '.tier1[$id].slug // empty' "$BINDINGS_FILE" 2>/dev/null)
[ -n "$EXISTING_TIER1" ] && { echo "ERROR: groupId 已有 tier1 block (slug=$EXISTING_TIER1)"; exit 1; }

[ -d "$REPO_ROOT/ws/line-$SLUG" ] && { echo "ERROR: ws/line-$SLUG 已存在"; exit 1; }
[ -f "$REPO_ROOT/scripts/claude-line-$SLUG.sh" ] && { echo "ERROR: supervisor 已存在"; exit 1; }
[ -f "$REPO_ROOT/config/mcp-line-$SLUG.json" ] && { echo "ERROR: mcp config 已存在"; exit 1; }

TEMPLATE_SLUG="${TEMPLATE:-line-talk}"
[ "$SLUG" = "${TEMPLATE_SLUG#line-}" ] && { echo "ERROR: SLUG 不能等於 template source slug"; exit 1; }

EXISTING_SLUG_SESSION=$(jq -r --arg sess "claude-line-$SLUG" \
  '.bindings[] | select(.session == $sess) | .session' "$BINDINGS_FILE" 2>/dev/null)
[ -n "$EXISTING_SLUG_SESSION" ] && { echo "ERROR: slug 已被其他 groupId 使用"; exit 1; }

if [ -n "$VAULT_BG_PATH" ]; then
  VAULT_ROOT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
  # 1. trim 兩端空白；2. 把「 / 」「/ 」「 /」全部壓成「/」
  RESOLVED="$(echo "$VAULT_BG_PATH" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]*\/[[:space:]]*/\//g')"
  # 3. 若以 Vault/ 開頭（大小寫都接），脫掉 Vault 前綴換成真 VAULT_ROOT
  case "$RESOLVED" in
    Vault/*|vault/*|VAULT/*) RESOLVED="$VAULT_ROOT/${RESOLVED#*/}" ;;
    /*) ;;  # 已是絕對路徑
    *) RESOLVED="$VAULT_ROOT/$RESOLVED" ;;  # 裸相對路徑也當 Vault 內
  esac
  VAULT_BG_PATH="$RESOLVED"

  if [ ! -d "$VAULT_BG_PATH" ]; then
    PARENT="$(dirname "$VAULT_BG_PATH")"
    echo "WARNING: vault_bg_path 解析為 '$VAULT_BG_PATH' 但不存在"
    if [ -d "$PARENT" ]; then
      echo "  同層候選（ls '$PARENT'）："
      ls "$PARENT" 2>/dev/null | sed 's/^/    - /' | head -20
    fi
    echo "  繼續執行，但 CLAUDE.md 路徑可能無效"
  fi
fi
echo "✓ 防呆檢查通過"
```

### A2. 建目錄結構

```bash
mkdir -p "$REPO_ROOT/ws/line-$SLUG/memory"
```

### A3. 從 template 建 CLAUDE.md

**不從既有 CLAUDE.md sed 生成**（會帶入 template 群組的 Vault 路徑殘留）。用乾淨 template 做 token 替換。

```bash
REPO_ROOT="$HOME/life-os"
SKILL_DIR="$REPO_ROOT/skills/tier1-line-bootstrap"

if [ "$TEMPLATE" = "line-note" ]; then
  TMPL_FILE="$SKILL_DIR/templates/CLAUDE.lightweight.md.tmpl"
else
  TMPL_FILE="$SKILL_DIR/templates/CLAUDE.chat.md.tmpl"
fi

# PROJECT_MEMORY_DIR 公式：cwd 絕對路徑開頭 / 去掉，/ 換 -，前綴 -
WS_ABS="$REPO_ROOT/ws/line-$SLUG"
WS_HASH=$(echo "$WS_ABS" | sed 's|^/||; s|/|-|g')
PROJECT_MEMORY_DIR="$HOME/.claude/projects/-$WS_HASH/memory"

TMPL_CONTENT=$(cat "$TMPL_FILE")
TMPL_CONTENT="${TMPL_CONTENT//\{\{SLUG\}\}/line-$SLUG}"
TMPL_CONTENT="${TMPL_CONTENT//\{\{GROUP_ID\}\}/$GROUP_ID}"
TMPL_CONTENT="${TMPL_CONTENT//\{\{DESCRIPTION\}\}/$DESCRIPTION}"
TMPL_CONTENT="${TMPL_CONTENT//\{\{PROJECT_MEMORY_DIR\}\}/$PROJECT_MEMORY_DIR}"

if [ -n "$VAULT_BG_PATH" ]; then
  TMPL_CONTENT="${TMPL_CONTENT//\{\{VAULT_BG_PATH\}\}/$VAULT_BG_PATH}"
  TMPL_CONTENT=$(echo "$TMPL_CONTENT" | sed '/{{#if VAULT_BG_PATH}}/d; /{{\/if}}/d')
else
  TMPL_CONTENT=$(echo "$TMPL_CONTENT" | \
    awk '/\{\{#if VAULT_BG_PATH\}\}/{skip=1} skip{if(/\{\{\/if\}\}/){skip=0; next}; next} 1')
fi

echo "$TMPL_CONTENT" > "$REPO_ROOT/ws/line-$SLUG/CLAUDE.md"
```

### A4. 建 handoff.md + memory/

```bash
cat > "$REPO_ROOT/ws/line-$SLUG/handoff.md" << 'EOF'
## Session 交接（待寫）[FRESH]

## SUMMARY
（尚未有交接內容）

## CURRENT
（session 剛建立，尚無進行中任務）

## NEXT
1. （待使用者指定）

## LESSON
（尚無）
EOF

echo "（此 session 尚無記憶卡片）" > "$REPO_ROOT/ws/line-$SLUG/memory/MEMORY.md"
```

---

## Phase B — 主 session 強制（核心層）

> ⚠️ **禁止 worker 執行**。涉及核心層檔案（scripts/ / config/ / bindings.json / token-watchdog.sh / webhook process），必須主 session 親自跑。

### B1. 建 supervisor script

**template source = `claude-line-talk.sh`**（最新版，含 `supervisor_backoff_tick` guard func）。

```bash
REPO_ROOT="$HOME/life-os"

cp "$REPO_ROOT/scripts/claude-line-talk.sh" "$REPO_ROOT/scripts/claude-line-$SLUG.sh"

sed -i '' \
  -e "s|LINE-talk 群 (<LINE_GROUP_ID>)|$DESCRIPTION ($GROUP_ID)|g" \
  -e "s|TMUX_SESSION=\"claude-line-talk\"|TMUX_SESSION=\"claude-line-$SLUG\"|g" \
  -e "s|STOP_FLAG=\"\$HOME/.claude/line-talk-supervisor-stop\"|STOP_FLAG=\"\$HOME/.claude/line-$SLUG-supervisor-stop\"|g" \
  -e "s|RESTART_FLAG=\"\$HOME/.claude/line-talk-supervisor-restart\"|RESTART_FLAG=\"\$HOME/.claude/line-$SLUG-supervisor-restart\"|g" \
  -e "s|WORK_DIR=\"\$REPO_ROOT/ws/line-talk\"|WORK_DIR=\"\$REPO_ROOT/ws/line-$SLUG\"|g" \
  -e "s|LOG=\"\$HOME/.claude/claude-line-talk.log\"|LOG=\"\$HOME/.claude/claude-line-$SLUG.log\"|g" \
  -e "s|SUPERVISOR_PID_FILE=\"\$HOME/.claude/claude-line-talk-supervisor.pid\"|SUPERVISOR_PID_FILE=\"\$HOME/.claude/claude-line-$SLUG-supervisor.pid\"|g" \
  -e "s|claude-line-talk\.sh|claude-line-$SLUG.sh|g" \
  -e "s|claude-line-talk|claude-line-$SLUG|g" \
  -e "s|line-lobster-queue-line-talk\.jsonl|line-lobster-queue-line-$SLUG.jsonl|g" \
  -e "s|line-trigger-cooldown-claude-line-talk|line-trigger-cooldown-claude-line-$SLUG|g" \
  -e "s|mcp-line-talk\.json|mcp-line-$SLUG.json|g" \
  -e "s|LINE-talk|LINE-$SLUG|g" \
  "$REPO_ROOT/scripts/claude-line-$SLUG.sh"

chmod +x "$REPO_ROOT/scripts/claude-line-$SLUG.sh"
```

### B2. 建 MCP config

```bash
cp "$REPO_ROOT/config/mcp-line-talk.json" "$REPO_ROOT/config/mcp-line-$SLUG.json"
sed -i '' "s|line-lobster-queue-line-talk\.jsonl|line-lobster-queue-line-$SLUG.jsonl|g" \
  "$REPO_ROOT/config/mcp-line-$SLUG.json"
```

### B3. 更新 bindings.json（原子寫入 + 備份）

```bash
BINDINGS_FILE="$HOME/.claude/channels/line/bindings.json"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
cp "$BINDINGS_FILE" "${BINDINGS_FILE}.bak-$TIMESTAMP"

NEW_BINDING=$(jq -n \
  --arg kind "group" --arg id "$GROUP_ID" \
  --arg session "claude-line-$SLUG" \
  --arg queue "$HOME/.claude/channels/line/runtime/line-lobster-queue-line-$SLUG.jsonl" \
  '{match:{kind:$kind,id:$id}, session:$session, queueFile:$queue}')
[ -z "$NEW_BINDING" ] && { echo "ERROR: jq 生成 NEW_BINDING 失敗"; exit 1; }

TMPFILE=$(mktemp)
jq --argjson nb "$NEW_BINDING" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg slug "$SLUG" \
  '.bindings += [$nb] | .updated_at = $ts | .updated_by = ("bindings-add-line-" + $slug)' \
  "$BINDINGS_FILE" > "$TMPFILE"

jq . "$TMPFILE" > /dev/null 2>&1 || {
  echo "ERROR: bindings.json jq 驗證失敗，rollback"
  cp "${BINDINGS_FILE}.bak-$TIMESTAMP" "$BINDINGS_FILE"
  rm -f "$TMPFILE"
  exit 1
}

if [ "$WRITE_TIER1_BLOCK" = "true" ]; then
  jq --arg gid "$GROUP_ID" --arg slug "$SLUG" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.tier1[$gid] = {
       slug: $slug,
       session: ("claude-line-" + $slug),
       ws: ("ws/line-" + $slug),
       queue: ("$HOME/.claude/channels/line/runtime/line-lobster-queue-line-" + $slug + ".jsonl"),
       mcp_config: ("config/mcp-line-" + $slug + ".json"),
       supervisor: ("scripts/claude-line-" + $slug + ".sh"),
       created_at: $ts
    }' "$TMPFILE" > "${TMPFILE}.tier1" && mv "${TMPFILE}.tier1" "$TMPFILE"
fi

mv "$TMPFILE" "$BINDINGS_FILE"
echo "✓ bindings.json 更新完成（備份：${BINDINGS_FILE}.bak-$TIMESTAMP）"
```

### B3.5. 補 token-watchdog.sh 的 case（關鍵步驟）⚠️

> **BLOCKING BUG 預防**：token-watchdog.sh 的 `WS_SUFFIX` case `*)` 直接 `exit 2`，新 slug 不補 case 會讓 watchdog 啟動即死 → 150k token 門檻失效、session 裸奔。

```bash
python3 "$REPO_ROOT/skills/tier1-line-bootstrap/patches/token-watchdog-patch.py" "$SLUG"

# 必查 WS_SUFFIX case（最關鍵）
grep -q "ws-line-$SLUG" "$REPO_ROOT/scripts/token-watchdog.sh" || {
  echo "ERROR: WS_SUFFIX case 未補入，watchdog 會 exit 2！"; exit 1
}
```

Python 腳本冪等（重跑跳過已存在的 case）。輸出會標示每個 case 是 `added` / `skip (已存在)` / `ERROR`。

### B3.6. 重啟 line-lobster webhook ⚠️

> **關鍵**：`webhook.ts` 的 `loadBindings()` 是 module-level 一次性載入。bindings.json 修改後 webhook **不會 reload**，新 binding 不生效。

```bash
WH_PID=$(pgrep -f "bun.*webhook.ts" | head -1)
WEBHOOK_SCRIPT="$REPO_ROOT/plugins/line-lobster/start-webhook.sh"

if [ -n "$WH_PID" ]; then
  echo "停止舊 webhook (PID $WH_PID)..."
  kill "$WH_PID"
  for i in $(seq 1 10); do
    kill -0 "$WH_PID" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$WH_PID" 2>/dev/null && kill -9 "$WH_PID" 2>/dev/null
fi

bash "$WEBHOOK_SCRIPT" &
sleep 2

NEW_WH_PID=$(pgrep -f "bun.*webhook.ts" | head -1)
[ -z "$NEW_WH_PID" ] && { echo "ERROR: webhook 重啟失敗，請手動 cd plugins/line-lobster/ && bash start-webhook.sh"; exit 1; }
echo "✓ webhook 重啟 (PID $NEW_WH_PID)"
```

若 webhook 由 launchd 管理，kill 後 launchd 會自動重拉；手動跑的情況則需 `bash start-webhook.sh`。

### B4. 啟動 supervisor

```bash
bash "$REPO_ROOT/scripts/claude-line-$SLUG.sh"
```

### B5. 驗證（retry loop，最多 60 秒）

> **關鍵**：supervisor 內含 `sleep 25`，claude process 要 40 秒才出現。不能只 `sleep 3` 就驗證。

```bash
SLUG_SESSION="claude-line-$SLUG"
LOG="$HOME/.claude/claude-line-$SLUG.log"
TIMEOUT=60
INTERVAL=5

check_retry() {
  local name="$1"; local check_cmd="$2"; local elapsed=0
  while [ $elapsed -lt $TIMEOUT ]; do
    if eval "$check_cmd" 2>/dev/null; then
      echo "✓ [${elapsed}s] $name"
      return 0
    fi
    sleep $INTERVAL; elapsed=$((elapsed + INTERVAL))
  done
  echo "✗ $name（${TIMEOUT}s 後仍未就緒）"
  return 1
}

check_retry "tmux session $SLUG_SESSION 存在" "tmux has-session -t '$SLUG_SESSION'"
check_retry "log 含 supervisor started" "grep -q 'supervisor started inside tmux' '$LOG'"
check_retry "claude process (mcp-line-$SLUG.json)" "ps aux | grep -E 'mcp-line-${SLUG}\\.json' | grep -v grep | grep -q ."

# 靜態驗證 token-watchdog.sh
grep -q "ws-line-$SLUG" "$REPO_ROOT/scripts/token-watchdog.sh" && \
  echo "✓ token-watchdog WS_SUFFIX case 已補" || \
  echo "✗ token-watchdog WS_SUFFIX 未補（⚠️ watchdog 會 exit 2）"
```

### B6. Tier 2 升級清理

若 groupId 原本是 Tier 2（`ws/line/contexts/<groupId>.md` 存在），封存舊檔避免 dispatcher 混淆。

```bash
TIER2_CONTEXT="$REPO_ROOT/ws/line/contexts/${GROUP_ID}.md"
if [ -f "$TIER2_CONTEXT" ]; then
  mkdir -p "$REPO_ROOT/ws/line/contexts/archived"
  mv "$TIER2_CONTEXT" \
    "$REPO_ROOT/ws/line/contexts/archived/${GROUP_ID}.md.tier1-migrated-$(date +%Y%m%d%H%M%S)"
fi
```

---

## Retrofit 模式（`--retrofit <slug>`）

對已存在但建立時有缺的 Tier 1 slug 做補救，**不重建、只補缺**。

### 前置：驗 slug 存在

```bash
SLUG="$1"
REPO_ROOT="$HOME/life-os"
BINDINGS_FILE="$HOME/.claude/channels/line/bindings.json"

GROUP_ID=$(jq -r --arg sess "claude-line-$SLUG" \
  '.bindings[] | select(.session == $sess) | .match.id' "$BINDINGS_FILE" 2>/dev/null)
[ -z "$GROUP_ID" ] && { echo "ERROR: slug $SLUG 不在 bindings[]"; exit 1; }
echo "Retrofit: slug=$SLUG, groupId=$GROUP_ID"
```

### R1. token-watchdog.sh case 補齊（冪等）

```bash
python3 "$REPO_ROOT/skills/tier1-line-bootstrap/patches/token-watchdog-patch.py" "$SLUG"
# Python 腳本會自己判斷每個 case 是 added / skip / ERROR，不用前置 grep
```

### R2. webhook 時間戳對比 + 需要時重啟

```bash
BINDINGS_MTIME=$(stat -f %m "$BINDINGS_FILE" 2>/dev/null || echo 0)
WH_PID=$(pgrep -f "bun.*webhook.ts" | head -1)

if [ -n "$WH_PID" ]; then
  WH_START=$(ps -p "$WH_PID" -o lstart= 2>/dev/null | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null || echo 0)
  if [ "$BINDINGS_MTIME" -gt "$WH_START" ]; then
    echo "⚠️ bindings.json 比 webhook 新，重啟"
    kill "$WH_PID"; sleep 2
    bash "$REPO_ROOT/plugins/line-lobster/start-webhook.sh" &
    sleep 2
    pgrep -f "bun.*webhook.ts" > /dev/null && echo "✓ webhook 重啟完成"
  else
    echo "✓ webhook 比 bindings.json 新，不需重啟"
  fi
else
  echo "⚠️ webhook 不在，啟動中..."
  bash "$REPO_ROOT/plugins/line-lobster/start-webhook.sh" &
fi
```

### R3. tier1 block 補寫（若 `--write-tier1-block`）

```bash
TIER1_EXISTS=$(jq -r --arg id "$GROUP_ID" '.tier1[$id] // empty' "$BINDINGS_FILE" 2>/dev/null)
if [ -z "$TIER1_EXISTS" ] && [ "$WRITE_TIER1_BLOCK" = "true" ]; then
  # 同 B3 的 tier1 block 寫入邏輯
  echo "（補寫 tier1 block）"
elif [ -n "$TIER1_EXISTS" ]; then
  echo "✓ tier1 block 已存在"
else
  echo "（tier1 block 無，但 flag 未開，跳過）"
fi
```

### R4. 全面狀態驗證

```bash
tmux has-session -t "claude-line-$SLUG" 2>/dev/null && echo "✓ tmux 存活" || echo "✗ tmux 不存在"

SUPERVISOR_PID_FILE="$HOME/.claude/claude-line-$SLUG-supervisor.pid"
if [ -f "$SUPERVISOR_PID_FILE" ]; then
  SUP_PID=$(cut -d'|' -f1 "$SUPERVISOR_PID_FILE" 2>/dev/null)
  kill -0 "$SUP_PID" 2>/dev/null && echo "✓ supervisor 存活 (PID $SUP_PID)" || echo "✗ supervisor 死了"
else
  echo "✗ supervisor PID file 不存在"
fi

ps aux | grep -E "mcp-line-${SLUG}\.json" | grep -v grep > /dev/null && \
  echo "✓ claude process 存活" || echo "✗ claude 不在"

pgrep -f "token-watchdog.sh.*claude-line-$SLUG" > /dev/null && \
  echo "✓ token-watchdog 存活" || \
  echo "⚠️ token-watchdog 不在（supervisor 下輪 iteration 會拉起）"
```

### R5. 輸出報告

由 R1-R4 的輸出彙整「補了哪些 / 跳過哪些 / 還缺哪些」。

---

## 結尾輸出卡

bootstrap 或 retrofit 完成後輸出：

```
=== tier1-line-bootstrap 完成 ===
模式         : bootstrap / retrofit
groupId      : <GROUP_ID>
slug         : <SLUG>
session      : claude-line-<SLUG>
ws 路徑      : ~/life-os/ws/line-<SLUG>/
tmux attach  : tmux attach -t claude-line-<SLUG>
tail log     : tail -f ~/.claude/claude-line-<SLUG>.log
手動重啟     : bash ~/life-os/scripts/claude-line-<SLUG>.sh
bindings 備份: ~/.claude/channels/line/bindings.json.bak-<TIMESTAMP>
tier1 block  : <true / false>
watchdog     : token-watchdog.sh 5 處 case 已補
webhook      : <已重啟 / 未變動>
```

---

## 路由表更新提醒

Phase B 尾段 / retrofit 結束，**主動檢查**兩個檔案是否已收此 slug 條目：

```bash
grep "line-$SLUG" "$REPO_ROOT/skill-routes.md" || \
  echo "⚠️ skill-routes.md 尚無 line-$SLUG 條目"
```

若群組有特定觸發詞要被路由，協助使用者在 `skill-routes.md` 加一行。

---

## 依賴檔案

```
skills/tier1-line-bootstrap/
├── SKILL.md                                          (本檔)
├── templates/
│   ├── CLAUDE.lightweight.md.tmpl                    (line-note 風格)
│   └── CLAUDE.chat.md.tmpl                           (line-talk 風格)
└── patches/
    └── token-watchdog-patch.py                       (冪等補 5 處 case)
```

讀 template 時用 `{{SLUG}}` / `{{GROUP_ID}}` / `{{DESCRIPTION}}` / `{{VAULT_BG_PATH}}` / `{{PROJECT_MEMORY_DIR}}` 替換；無 `VAULT_BG_PATH` 時用 awk 刪 `{{#if VAULT_BG_PATH}}...{{/if}}` 整段。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
