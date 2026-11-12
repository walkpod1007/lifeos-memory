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
#   LIFEOS_INDEX_SKIP_WARN_EVERY  索引尾端因「別人正在寫索引／行程表拍不到」連續跳過幾輪後，
#                        在 log 寫一行警告，預設 36（10 分鐘一輪 ≈ 6 小時沒更新索引）
#   LIFEOS_INDEX_SKIP_COUNT_FILE  連續跳過計數檔，預設 $LIFEOS_MEMORY_ROOT/.checkpoints/index-skip.count
#   LIFEOS_SUMMARY_RETRY_UNIT     摘要重試的退避單位秒數，預設 2（第 i 趟失敗後睡 i×單位）
#   REALTIME_SUMMARY_LIB_ONLY=1   只載入函式不執行主流程（測試用）

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

LOCK_DIR="$MEMORY_ROOT/.realtime-summary.lock.d"
LOCK_PIDFILE="$LOCK_DIR/pid"

# 持有者還活著嗎：pid 存在（kill -0）且命令列含 realtime-summary.sh。
# pid 活著但命令列不是本腳本＝pid 被別的行程重用，視為持有者已死。
# 只用 ps -p <特定 pid> 查該 pid 自己的命令列，不用 pgrep -f 掃全表（會被 log 監看器之類的字串假匹配）。
_rts_lock_holder_alive() {
    local pid="${1:-}"
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
    [[ "$cmd" == *"realtime-summary.sh"* ]]
}

# ── 索引更新防撞：判斷「現在有沒有別的行程正在寫 qmd 索引」──
# 為什麼不用 pgrep -f：①只給 yes/no，分不出讀取類（search/query）；②旗標排在子命令前面
# （`qmd --index x embed`）的樣式 pgrep 一行正則很容易看漏；③取不到行程表時 pgrep 的「沒找到」
# 跟「沒人在寫」長得一樣，等於 fail-open。改成先拍一張 `ps -Ao pid=,command=` 快照，離線 awk 比對。
#
# 判法：快照每行先找出「qmd 命令」——第一個 token 的 basename 是 qmd／qmd.js，或第一個 token 是
# node／bun 且緊接著（略過旗標）的 token 是 qmd／qmd.js；之後第一個「認得的子命令」是誰就算誰：
#   update|embed                                  → writer（印出該行）
#   search|query|ask|status|list|doctor|serve     → reader（不算）
#   `qmd --index x embed` → x 不是子命令，續看 → embed → writer（旗標在前也認）
#   `qmd search embed things` → search 先到 → reader（關鍵字帶 embed 不算數）
#   `qmd embed -c search` → embed 先到 → writer（writer 在前不被後面的 reader 字樣放行）
# 逐 token 全等比對，不是子字串（embedding-report 兩邊都不認）。
# 殘留：旗標的值剛好等於某個子命令名（`--index embed`）會被判成 writer——多跳一輪，方向安全。
QMD_WRITE_SUBCMDS="${QMD_WRITE_SUBCMDS:-update|embed}"
QMD_READ_SUBCMDS="${QMD_READ_SUBCMDS:-search|query|ask|status|list|doctor|serve}"

qmd_writer_procs() {
    # stdin＝`ps -Ao pid=,command=` 的快照；stdout＝判定成「正在寫索引」的那幾行
    awk -v WRITE="$QMD_WRITE_SUBCMDS" -v READ="$QMD_READ_SUBCMDS" '
      function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
      BEGIN { nw = split(WRITE, wa, "|"); nr = split(READ, ra, "|") }
      {
        n = split($0, tok, " ")
        # tok[1] 是 pid，tok[2] 起是命令列
        start = 0
        b = base(tok[2])
        if (b == "qmd" || b == "qmd.js") { start = 3 }
        else if (b == "node" || b == "nodejs" || b == "bun") {
          for (j = 3; j <= n && j <= 5; j++) {
            if (substr(tok[j], 1, 1) == "-") continue
            bj = base(tok[j])
            if (bj == "qmd" || bj == "qmd.js") start = j + 1
            break
          }
        }
        if (start == 0) next
        for (t = start; t <= n; t++) {
          for (k = 1; k <= nw; k++) if (tok[t] == wa[k]) { print; next }
          for (k = 1; k <= nr; k++) if (tok[t] == ra[k]) next
        }
      }'
}

# 連續跳過計數（落檔）：log 沒有讀者，連續跳一整天跟跳一輪長得一模一樣，所以每累積 N 輪在 log 寫一行警告。
# 公開版不接告警轉發，警告就是 log 一行；要接外部通知請自己監看 log 或這個計數檔。
# 計數檔寫不進去要出聲，不能吞：唯讀或磁碟滿時計數每輪都從 0 重算，永遠到不了門檻，
# 告警機制自己安靜地不存在了，外觀跟「一直很健康」一模一樣。
INDEX_SKIP_COUNT_FILE="${LIFEOS_INDEX_SKIP_COUNT_FILE:-$CKPT_DIR/index-skip.count}"
INDEX_SKIP_WARN_EVERY="${LIFEOS_INDEX_SKIP_WARN_EVERY:-36}"
case "$INDEX_SKIP_WARN_EVERY" in ''|*[!0-9]*|0) INDEX_SKIP_WARN_EVERY=36;; esac
INDEX_SKIP_WARN_EVERY=$((10#$INDEX_SKIP_WARN_EVERY))

rts_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true; }

index_skip_bump() {   # $1=跳過原因（寫進 log）
    local n=0
    if [[ -f "$INDEX_SKIP_COUNT_FILE" ]]; then
        n=$(tr -dc '0-9' < "$INDEX_SKIP_COUNT_FILE" 2>/dev/null || echo 0)
        n=${n:-0}
    fi
    n=$((10#$n + 1))
    if ! { mkdir -p "$(dirname "$INDEX_SKIP_COUNT_FILE")" 2>/dev/null && printf '%s\n' "$n" > "$INDEX_SKIP_COUNT_FILE" 2>/dev/null; }; then
        rts_log "[warn] 索引連續跳過計數檔寫不進去（$INDEX_SKIP_COUNT_FILE），本輪是第 ${n} 輪起算不可信；跳過原因：$1"
        return 0
    fi
    if (( n % INDEX_SKIP_WARN_EVERY == 0 )); then
        rts_log "[warn] 索引已連續跳過 ${n} 輪沒更新（原因：$1）——檢查是不是有長跑的 qmd embed／update 卡住"
    fi
}
index_skip_reset() { rm -f "$INDEX_SKIP_COUNT_FILE" 2>/dev/null || true; }

# 索引防撞閘：0＝可以寫、1＝有別人在寫（跳過）、2＝行程表拍不到或是空的（fail-safe 跳過）
qmd_index_gate() {
    local snap rc=0 writers
    snap=$(ps -Ao pid=,command= 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 || -z "$(printf '%s' "$snap" | tr -d '[:space:]')" ]]; then
        return 2
    fi
    writers=$(printf '%s\n' "$snap" | qmd_writer_procs)
    if [[ -n "$writers" ]]; then
        QMD_GATE_WRITERS="$(printf '%s' "$writers" | head -1 | cut -c1-200)"
        return 1
    fi
    return 0
}

if [[ "${REALTIME_SUMMARY_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── 全域 lock（atomic mkdir，macOS 無 flock）──
# 舊版單看鎖目錄 mtime>30 分鐘就強拆，會拆掉仍在跑的合法行程（摘要重試加索引更新最壞可超過 30 分）。
# 改成「齡＋持有者存活」雙判：持有者活著一律跳過、不看年齡；持有者已死（或 pid 檔缺失／pid 被重用）
# 才允許在鎖目錄齡 >30 分鐘時強拆（齡的條件避免誤拆「剛建立、pid 檔還沒寫完」的新鎖）。
mkdir -p "$MEMORY_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    HOLDER_PID=""
    [[ -f "$LOCK_PIDFILE" ]] && HOLDER_PID=$(cat "$LOCK_PIDFILE" 2>/dev/null || echo "")
    if _rts_lock_holder_alive "$HOLDER_PID"; then
        echo "[lock] busy, holder pid=$HOLDER_PID alive, skip" >&2
        exit 0
    fi
    if [[ -d "$LOCK_DIR" ]] && find "$LOCK_DIR" -maxdepth 0 -mmin +30 2>/dev/null | grep -q .; then
        echo "[lock] stale (holder pid=${HOLDER_PID:-unknown} dead), force-clear" >&2
        rm -f "$LOCK_PIDFILE" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "[lock] busy, skip" >&2; exit 0; }
    else
        echo "[lock] busy, skip" >&2
        exit 0
    fi
fi
echo "$$" > "$LOCK_PIDFILE" 2>/dev/null || true
trap 'rm -f "$LOCK_PIDFILE" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

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

全部輸出（凡是中文）一律台灣慣用繁體、禁止簡體。請嚴格照以下格式回覆。行首標籤（SUMMARY:/SLUG:/STATE:）原樣保留，不加粗體、編號或其他裝飾；不要輸出格式以外的任何文字：

SUMMARY: 100 字以內的對話摘要，一行寫完（用對話所使用的語言；輸出只要是中文，一律台灣慣用繁體、禁止出現任何簡體字——即使對話記錄裡混有簡體也照樣用繁體寫）
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

    local RESPONSE="" i UPDATE_OK=0
    # 簡體軟閘（只重試、不否決）：prompt 已明寫要台灣慣用繁體，但小模型偶爾仍整段回簡體。
    # 前兩趟驗到簡體就當這趟不算、重抽；第三趟不論驗不驗得過都收下並留一行 warn。
    # 刻意不做硬閘——硬否決會讓 checkpoint 停在原地、同一窗反覆重摘要燒 token。
    # 偵測器只收「正體中文不會用到」的字（寧可漏報不誤報）；檢查器不在就整格略過，不阻斷本輪。
    local _SIMP_CHK _RETRY_UNIT="${LIFEOS_SUMMARY_RETRY_UNIT:-2}"
    case "$_RETRY_UNIT" in ''|*[!0-9]*) _RETRY_UNIT=2;; esac
    _SIMP_CHK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/simplified-char-check.py"
    for i in 1 2 3; do
        RESPONSE=$(echo "$PROMPT" | "$TIMEOUT_BIN" -k 15 60 claude --print --model "$MODEL" 2>/dev/null || true)
        if [[ -n "$RESPONSE" ]] && ! echo "$RESPONSE" | grep -qi "not logged in\|please run.*login\|authentication failed\|unauthorized"; then
            if [[ -f "$_SIMP_CHK" ]] && ! printf '%s' "$RESPONSE" | python3 "$_SIMP_CHK" >/dev/null 2>&1; then
                if [[ "$i" -lt 3 ]]; then
                    rts_log "[warn][$PROJ] 第 $i 趟摘要驗到簡體字，重抽一次"
                    sleep $((i * _RETRY_UNIT))
                    continue
                fi
                rts_log "[warn][$PROJ] 三趟都驗到簡體字，照收：$(printf '%s' "$RESPONSE" | python3 "$_SIMP_CHK" 2>/dev/null | head -1)"
            fi
            UPDATE_OK=1
            break
        fi
        sleep $((i * _RETRY_UNIT))
    done
    if [[ "$UPDATE_OK" != "1" || -z "$RESPONSE" ]]; then
        echo "[error][$PROJ] 摘要模型三次 retry 仍失敗（檢查 claude 登入狀態）" >&2
        return
    fi

    # 解析三段（行首標籤定位；容忍模型偷加 #/*/空白等裝飾）
    local PART1 PART2 PART3
    # || true：set -euo pipefail 下模型漏標籤時 grep rc=1 會炸死整支腳本，
    # 這裡缺段有 fallback（SUMMARY 退回全文、SLUG 退回 segment），解析失敗不該致命
    PART1=$(echo "$RESPONSE" | grep -m1 -E '^[#*[:space:]]*SUMMARY[:：]' | sed -E 's/^[#*[:space:]]*SUMMARY[:：][[:space:]]*//; s/[*[:space:]]+$//' || true)
    PART2=$(echo "$RESPONSE" | grep -m1 -E '^[#*[:space:]]*SLUG[:：]' | sed -E 's/^[#*[:space:]]*SLUG[:：][[:space:]]*//; s/[*[:space:]]+$//' || true)
    PART3=$(echo "$RESPONSE" | awk '/^[#*[:space:]]*STATE[:：]/{f=1; next} f{print}' || true)

    local SUMMARY="${PART1:-$RESPONSE}"
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
done < <(resolve_watch_dirs)
if [[ "$FOUND" == "0" ]]; then
    echo "[warn] 沒有可監看的專案（$CLAUDE_HOME/projects/ 近 24h 無活動，或 LIFEOS_WATCH 指的目錄不存在）" >&2
fi

# ── checkpoint 清理：14 天沒動的 session 記錄不再需要 ──
find "$CKPT_DIR" -type f -mtime +14 -delete 2>/dev/null || true

# ── 向量索引更新（裝了 qmd 才做；設 LIFEOS_QMD_COLLECTION="" 可停用；singleton guard 防 sqlite 鎖疊撞）──
if [[ -n "$QMD_COLLECTION" ]] && command -v qmd &>/dev/null; then
    QMD_GATE_WRITERS=""
    QMD_GATE_RC=0
    qmd_index_gate || QMD_GATE_RC=$?
    if [[ "$QMD_GATE_RC" -eq 1 ]]; then
        rts_log "[skip] 既有 qmd update/embed 執行中，本輪不更新索引：${QMD_GATE_WRITERS}"
        index_skip_bump "有別的行程在寫索引"
    elif [[ "$QMD_GATE_RC" -ne 0 ]]; then
        # 行程表拍不到或是空的＝判不出有沒有人在寫：fail-safe 跳過，不放行
        rts_log "[skip] 行程表快照失敗或為空，無法確認有沒有人在寫索引，本輪不更新索引"
        index_skip_bump "行程表快照失敗或為空"
    else
        index_skip_reset
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
