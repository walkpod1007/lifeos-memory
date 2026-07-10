#!/usr/bin/env bash
# realtime-summary.sh — 每 10 分鐘把 Claude Code 對話新增段摘要成 Markdown
#
# 跑法：launchd/cron 每 10 分鐘觸發（模板見 ../templates/），也可手動執行
#
# 流程：對每個監看的 Claude 專案的每條活躍 session（jsonl）
#   讀 transcript 新增段 → 小模型摘要 + state 條目
#   → 寫 $LIFEOS_MEMORY_ROOT/daily/YYYY-MM-DD/HHMM-{proj}-{slug}.md
#   → 更新 $LIFEOS_MEMORY_ROOT/state/{proj}.md（append + per-段 trim + atomic）
#   → （裝了 qmd 才做）更新向量索引
#
# 設定（全部走環境變數，都有預設值）：
#   LIFEOS_MEMORY_ROOT   記憶根目錄，預設 ~/lifeos-memory
#   CLAUDE_HOME          Claude Code 設定目錄，預設 ~/.claude
#   LIFEOS_WATCH         監看哪些專案：~/.claude/projects/ 下的目錄名，
#                        冒號分隔；預設 "auto" = 近 24h 有活動的所有專案。
#                        同專案多開 session（多條 jsonl）也全部入摘要——
#                        記憶層不綁單一 session
#   LIFEOS_SUMMARY_MODEL 摘要模型，預設 haiku（便宜快速就好）
#   LIFEOS_QMD_COLLECTION qmd 索引名，預設 memory；沒裝 qmd 自動跳過；設空字串 = 停用向量層

set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_ROOT="${LIFEOS_MEMORY_ROOT:-$HOME/lifeos-memory}"
WATCH="${LIFEOS_WATCH:-auto}"
MODEL="${LIFEOS_SUMMARY_MODEL:-haiku}"
QMD_COLLECTION="${LIFEOS_QMD_COLLECTION-memory}"

DAILY_DIR="$MEMORY_ROOT/daily"
STATE_DIR="$MEMORY_ROOT/state"
CKPT_DIR="$MEMORY_ROOT/.checkpoints"
LOG="$MEMORY_ROOT/.logs/realtime-summary.log"
MAX_STATE_LINES=20
STALE_SECONDS="${STALE_SECONDS:-86400}"

# ── 全域 lock（atomic mkdir，macOS 無 flock）──
LOCK_DIR="$MEMORY_ROOT/.realtime-summary.lock.d"
mkdir -p "$MEMORY_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # stale lock：超過 30 分鐘視為前次進程已死
    if [[ -d "$LOCK_DIR" ]] && find "$LOCK_DIR" -maxdepth 0 -mmin +30 2>/dev/null | grep -q .; then
        echo "[lock] stale, force-clear" >&2
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "[lock] busy, skip" >&2; exit 0; }
    else
        echo "[lock] busy, skip" >&2
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ── timeout binary 解析（launchd/cron 環境 PATH 常缺 homebrew）──
TIMEOUT_BIN=""
for _tb in timeout gtimeout /opt/homebrew/bin/timeout /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
    if command -v "$_tb" &>/dev/null; then
        TIMEOUT_BIN="$_tb"
        break
    fi
done
unset -v _tb
if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "[error] 找不到 timeout/gtimeout（brew install coreutils）" >&2
    exit 1
fi

mkdir -p "$STATE_DIR" "$CKPT_DIR" "$(dirname "$LOG")"

DATE=$(date +"%Y-%m-%d")
HHMM=$(date +"%H%M")
HHMM_DISPLAY=$(date +"%H:%M")
DATE_DIR="$DAILY_DIR/$DATE"

# ── 摘要用的 claude --print 自己也會留下 transcript ──
# 它落在 $CLAUDE_HOME/projects/<cwd 轉成的目錄名>/。若不隔離，下一輪就會去摘要
# 上一輪摘要留下的 transcript，變成自我餵食的無限迴圈（且每輪都新增檔案）。
# 對策：呼叫 claude 前固定 cd 到 SUMMARIZER_CWD，讓 transcript 一律落在同一個
# 可預測的目錄，並把該目錄從監看清單排除。
SUMMARIZER_CWD="/"
SELF_PROJ_DIR="$CLAUDE_HOME/projects/-"

# ── 監看清單解析 ──
# auto = ~/.claude/projects/ 下近 24h 有 jsonl 活動的所有專案
# （看 jsonl mtime 而非目錄 mtime：append 不會更新目錄時間戳）
resolve_watch_dirs() {
    if [[ "$WATCH" == "auto" ]]; then
        find "$CLAUDE_HOME/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin -1440 2>/dev/null \
            | xargs -I{} dirname {} | sort -u
    else
        local IFS=':'
        local name
        for name in $WATCH; do
            [[ -d "$CLAUDE_HOME/projects/$name" ]] && printf '%s\n' "$CLAUDE_HOME/projects/$name"
        done
    fi
}

# 永遠排除摘要器自己的 transcript 目錄（顯式 LIFEOS_WATCH 指到它也一樣排除）
filter_self_project() {
    grep -vFx "$SELF_PROJ_DIR" || true
}

# 專案目錄名 → 短標籤（取最後一段；-Users-you-myproj → myproj）
proj_label() {
    basename "${1%/}" | sed 's/.*-//'
}

warn_stale_if_needed() {
    local PROJ="$1" JSONL="$2" TOTAL_LINES="$3" LAST_LINE="$4"
    (( TOTAL_LINES <= LAST_LINE )) || return 0
    [[ -f "$JSONL" ]] || return 0
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f %m "$JSONL" 2>/dev/null || stat -c %Y "$JSONL" 2>/dev/null || echo "$now")
    age=$((now - mtime))
    if (( age > STALE_SECONDS )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [stale][$PROJ] 最新 jsonl 無新行且 mtime ${age}s 前：$JSONL" >> "$LOG" 2>/dev/null || true
    fi
}

# 同專案可能同時多條 session（多開 claude → 多條 jsonl）→ 每條活躍的都處理
process_project() {
    local PROJ_DIR="$1"
    local PROJ
    PROJ=$(proj_label "$PROJ_DIR")

    local JSONL FOUND_J=0
    while IFS= read -r JSONL; do
        [[ -n "$JSONL" ]] || continue
        FOUND_J=1
        process_jsonl "$PROJ" "$JSONL"
    done < <(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -mmin -1440 2>/dev/null | sort)
    if [[ "$FOUND_J" == "0" ]]; then
        echo "[skip][$PROJ] no active jsonl in $PROJ_DIR" >&2
    fi
}

process_jsonl() {
    local PROJ="$1" JSONL="$2"

    # checkpoint per-jsonl：每條 session 各自記已讀到第幾行，互不干擾
    local JSONL_UUID LAST_LINE=0
    JSONL_UUID=$(basename "$JSONL" .jsonl)
    local CHECKPOINT_FILE="$CKPT_DIR/${PROJ}--${JSONL_UUID}"
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        LAST_LINE=$(tr -dc '0-9' < "$CHECKPOINT_FILE" 2>/dev/null || echo "0")
        LAST_LINE=${LAST_LINE:-0}
    fi

    local TOTAL_LINES
    TOTAL_LINES=$(wc -l < "$JSONL" | tr -d ' ')
    if (( TOTAL_LINES <= LAST_LINE )); then
        warn_stale_if_needed "$PROJ" "$JSONL" "$TOTAL_LINES" "$LAST_LINE"
        echo "[skip][$PROJ] no new ($LAST_LINE/$TOTAL_LINES)" >&2
        echo "${TOTAL_LINES}" > "$CHECKPOINT_FILE"
        return
    fi

    # 擷取 [U][A] 新段落
    local NEW_TEXT
    NEW_TEXT=$(python3 - "$JSONL" "$LAST_LINE" <<'PYEOF'
import sys, json, re
jsonl_path = sys.argv[1]
start_line = int(sys.argv[2])
out = []
with open(jsonl_path, 'r', encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f):
        if i < start_line: continue
        raw = raw.strip()
        if not raw: continue
        try: obj = json.loads(raw)
        except: continue
        t = obj.get('type', '')
        msg = obj.get('message', {})
        content = msg.get('content', '')
        text = ''
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'text':
                    text = c.get('text', ''); break
        elif isinstance(content, str):
            text = content
        if t == 'user':
            text = re.sub(r'<system-reminder>.*?</system-reminder>', '', text, flags=re.DOTALL)
            text = re.sub(r'<[^>]+>', '', text).strip()
            if text: out.append(f"[U] {text[:300]}")
        elif t == 'assistant':
            text = text.strip()
            if text: out.append(f"[A] {text[:300]}")
print('\n'.join(out))
PYEOF
)
    if [[ -z "$(echo "$NEW_TEXT" | tr -d '[:space:]')" ]]; then
        echo "[skip][$PROJ] no U/A content in new lines" >&2
        echo "${TOTAL_LINES}" > "$CHECKPOINT_FILE"
        return
    fi

    # 小模型摘要（timeout + retry 3 次）
    local PROMPT="以下是一段 AI 助理與使用者的對話記錄（[U]=使用者，[A]=助理）。專案：${PROJ}。

請嚴格照以下格式回覆。行首標籤（SUMMARY:/SLUG:/STATE:）原樣保留，不加粗體、編號或其他裝飾；不要輸出格式以外的任何文字：

SUMMARY: 100 字以內的對話摘要，一行寫完（用對話所使用的語言）
SLUG: 精準描述內容的檔名 slug（3-6 個詞，- 連接，禁用 summary/session/對話 等通用詞）
STATE:
## 近況
[時間戳] 一句話（使用者在忙什麼）
## 觀察
[時間戳] 一句話（值得記住的模式或決定；沒有就整段省略）
## 踩坑
[時間戳] 一句話（這段對話踩到的坑；沒有就整段省略）

對話記錄：
${NEW_TEXT}"

    # 成功判準是「輸出符合契約」（白名單），不是「輸出不像錯誤訊息」（黑名單）。
    # claude --print 認證失敗時 exit code 仍是 0、錯誤訊息走 stdout，而訊息文字隨環境而異
    # （空環境是 "Not logged in"，launchd 與 Claude Code session 下都是 "API Error: 401"）。
    # 黑名單漏掉任何一種寫法，錯誤訊息就會被當成摘要寫檔。
    local RESPONSE="" i UPDATE_OK=0
    for i in 1 2 3; do
        # cd 到 SUMMARIZER_CWD：這次呼叫留下的 transcript 才會落進被排除的 $SELF_PROJ_DIR，
        # 而不是污染腳本當前所在的專案目錄（手動執行時 cwd 就是某個真專案）。
        RESPONSE=$(cd "$SUMMARIZER_CWD" && echo "$PROMPT" | "$TIMEOUT_BIN" -k 15 60 claude --print --model "$MODEL" 2>/dev/null || true)
        if [[ -n "$RESPONSE" ]] && echo "$RESPONSE" | grep -qE '^[#*[:space:]]*SUMMARY[:：]'; then
            UPDATE_OK=1
            break
        fi
        sleep $((i*2))
    done
    if [[ "$UPDATE_OK" != "1" ]]; then
        # 不寫 checkpoint：這段 transcript 必須留給下一輪重試，否則永遠不會被摘要。
        echo "[error][$PROJ] 摘要三次 retry 仍無合法 SUMMARY，checkpoint 不推進（檢查 claude 登入狀態）" >&2
        echo "[error][$PROJ] 模型最後輸出：${RESPONSE:0:200}" >&2
        return
    fi

    # 解析三段（行首標籤定位；容忍模型偷加 #/*/空白等裝飾）
    local PART1 PART2 PART3
    # || true：set -euo pipefail 下模型漏標籤時 grep rc=1 會炸死整支腳本，
    # 這裡缺段有 fallback（SUMMARY 退回全文、SLUG 退回 segment），解析失敗不該致命
    PART1=$(echo "$RESPONSE" | grep -m1 -E '^[#*[:space:]]*SUMMARY[:：]' | sed -E 's/^[#*[:space:]]*SUMMARY[:：][[:space:]]*//; s/[*[:space:]]+$//' || true)
    PART2=$(echo "$RESPONSE" | grep -m1 -E '^[#*[:space:]]*SLUG[:：]' | sed -E 's/^[#*[:space:]]*SLUG[:：][[:space:]]*//; s/[*[:space:]]+$//' || true)
    PART3=$(echo "$RESPONSE" | awk '/^[#*[:space:]]*STATE[:：]/{f=1; next} f{print}' || true)

    # 不可 fallback 成 $RESPONSE：那會在解析失敗時把模型的原始輸出（可能是錯誤訊息）當成摘要。
    # 上面的契約驗證已保證 SUMMARY: 存在，這裡只防 sed 把它清成空字串。
    local SUMMARY="$PART1"
    if [[ -z "$SUMMARY" ]]; then
        echo "[error][$PROJ] SUMMARY 標籤存在但內容為空，不寫檔（checkpoint 不推進）" >&2
        return
    fi
    local SLUG
    SLUG=$(echo "$PART2" | python3 -c "
import sys, re
s = sys.stdin.read().strip().replace(' ','').replace('\n','').replace('\r','')
s = re.sub(r'[^\w一-鿿-]', '', s)
print(s[:40])
")
    [[ -z "$SLUG" || ${#SLUG} -lt 2 ]] && SLUG="segment"

    # 寫 daily/YYYY-MM-DD/HHMM-{proj}-{slug}.md
    # （同分鐘多條 session 撞名時補 session 短 id，不互相覆蓋）
    mkdir -p "$DATE_DIR"
    local OUT_FILE="$DATE_DIR/${HHMM}-${PROJ}-${SLUG}.md"
    [[ -e "$OUT_FILE" ]] && OUT_FILE="$DATE_DIR/${HHMM}-${PROJ}-${SLUG}-${JSONL_UUID:0:6}.md"
    cat > "$OUT_FILE" <<MDEOF
---
date: ${DATE}
time: ${HHMM_DISPLAY}
project: ${PROJ}
session: ${JSONL_UUID:0:8}
type: realtime-summary
lines: ${LAST_LINE}-${TOTAL_LINES}
---

${SUMMARY}
MDEOF
    echo "[done][$PROJ] → $OUT_FILE" >&2

    # 更新 state/{proj}.md（atomic + per-段 trim + 時間戳強制校正）
    if [[ -n "$PART3" ]]; then
        python3 - "$STATE_DIR/${PROJ}.md" "$MAX_STATE_LINES" "$PROJ" <<'PYEOF' "$PART3" "${DATE} ${HHMM_DISPLAY}"
import sys, os, re

state_file = sys.argv[1]
max_lines  = int(sys.argv[2])
project    = sys.argv[3]
new_entries = sys.argv[4]
now_stamp   = sys.argv[5]

sections = {"近況": [], "觀察": [], "踩坑": []}

if os.path.exists(state_file):
    cur = None
    with open(state_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            for s in sections:
                if line.startswith(f"## {s}"):
                    cur = s; break
            else:
                if cur and line.startswith("["):
                    sections[cur].append(line)

cur = None
for line in new_entries.split('\n'):
    line = line.strip().lstrip('- ')
    for s in sections:
        if line.lstrip('#* ').startswith(f"## {s}") or line.lstrip('#* ') == s:
            cur = s; break
    else:
        if cur and line.startswith("["):
            # 時間戳不信任模型輸出，一律改寫成本輪實際時刻
            sections[cur].append(re.sub(r'^\[[^\]]*\]', f'[{now_stamp}]', line))

for s in sections:
    sections[s] = sections[s][-max_lines:]

tmp = state_file + ".tmp"
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(f"# state/{project}.md\n")
    f.write(f"> 每 10 分鐘自動更新（realtime-summary）\n")
    f.write(f"> 各段保最新 {max_lines} 條\n\n---\n\n")
    for s in ["近況", "觀察", "踩坑"]:
        f.write(f"## {s}\n")
        f.write('\n'.join(sections[s]))
        f.write("\n\n---\n\n")
os.replace(tmp, state_file)
print(f"[state][{project}] updated", file=sys.stderr)
PYEOF
    fi

    echo "${TOTAL_LINES}" > "$CHECKPOINT_FILE"
}

# ── 主迴圈：串行處理（不背景化，避免 race）──
FOUND=0
while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    FOUND=1
    process_project "$dir"
    sleep 1
done < <(resolve_watch_dirs | filter_self_project)
if [[ "$FOUND" == "0" ]]; then
    echo "[warn] 沒有可監看的專案（$CLAUDE_HOME/projects/ 近 24h 無活動，或 LIFEOS_WATCH 指的目錄不存在）" >&2
fi

# ── checkpoint 清理：14 天沒動的 session 記錄不再需要 ──
find "$CKPT_DIR" -type f -mtime +14 -delete 2>/dev/null || true

# ── 向量索引更新（裝了 qmd 才做；設 LIFEOS_QMD_COLLECTION="" 可停用；singleton guard 防 sqlite 鎖疊撞）──
if [[ -n "$QMD_COLLECTION" ]] && command -v qmd &>/dev/null; then
    if pgrep -f "qmd.*(update|embed) -c ${QMD_COLLECTION}$" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [skip] 既有 qmd update/embed 執行中" >> "$LOG" 2>/dev/null || true
    else
        if ! qmd collection list 2>/dev/null | grep -q "^${QMD_COLLECTION}\b\|\b${QMD_COLLECTION}\b"; then
            # qmd 語法：路徑在前、--name 給名字（與 install.sh/SKILL.md 一致；name 在前會被當相對路徑）
            qmd collection add "$MEMORY_ROOT" --name "$QMD_COLLECTION" >> "$LOG" 2>&1 || true
        fi
        if "$TIMEOUT_BIN" -k 15 240 qmd update -c "$QMD_COLLECTION" >> "$LOG" 2>&1; then
            "$TIMEOUT_BIN" -k 15 240 qmd embed -c "$QMD_COLLECTION" >> "$LOG" 2>&1 || \
                echo "$(date '+%Y-%m-%d %H:%M:%S') [warn] qmd embed 逾時或失敗" >> "$LOG" 2>/dev/null || true
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [warn] qmd update 逾時或失敗" >> "$LOG" 2>/dev/null || true
        fi
    fi
fi
