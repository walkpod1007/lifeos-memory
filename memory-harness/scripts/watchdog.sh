#!/usr/bin/env bash
# watchdog.sh — 看住一條 Claude Code 主 session 的 token 用量，
# 撞門檻自動：產 handoff → 終止 claude → 由 claw wrapper 重生新 session
#
# 使用（通常由 claw wrapper 自動帶起，也可手動）：
#   bash watchdog.sh <session名> <專案cwd> <supervisor_pid>
#   例：bash watchdog.sh main /Users/you/myproj 12345
#
# 職責邊界：狗只保「記憶連續性」——它殺 claude 前一定先寫 handoff。
# 重生（respawn）是 claw wrapper 的事；狗不負責把 claude 拉起來。
#
# 設定（環境變數，皆有預設）：
#   LIFEOS_TOKEN_THRESHOLD  觸發門檻，預設 150000（context 撞牆前留足收尾空間）
#   LIFEOS_MEMORY_ROOT      記憶根目錄，預設 ~/lifeos-memory
#   CLAUDE_HOME             Claude Code 設定目錄，預設 ~/.claude
#   LIFEOS_WRAP_POLL_SECS   斷頭緩衝：多久檢查一次，預設 15（秒）
#   LIFEOS_WRAP_QUIET_SECS  斷頭緩衝：transcript 靜止多久才算輪與輪之間，預設 60（秒）
#   LIFEOS_WRAP_MAX_WAIT    斷頭緩衝：最長等多久，撞頂照殺，預設 600（秒）
#   （三個值都過消毒：空、非純數字、0、超過 5 位數一律回預設）
#
# 設計筆記（來自母系統的實戰教訓）：
# - 不用 set -e/pipefail：監控迴圈靠顯式 if-else 處理錯誤，
#   任何一條 pipeline 非零就整支靜默退出的狗比沒有狗更危險
# - sticky pin：開場鎖定一條 transcript 後就不換，避免同目錄多條 jsonl
#   （多開 session）害狗在檔案間跳來跳去、殺錯對象
# - 只 pin 狗啟動後才出現/更新的 jsonl，避免撿到上一世的殘骸誤觸發

set -u

SESSION_NAME="${1:?用法: watchdog.sh <session名> <專案cwd> <supervisor_pid>}"
PROJECT_CWD="${2:?缺少專案 cwd}"
SUPERVISOR_PID="${3:?缺少 supervisor pid}"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_ROOT="${LIFEOS_MEMORY_ROOT:-$HOME/lifeos-memory}"
THRESHOLD="${LIFEOS_TOKEN_THRESHOLD:-150000}"

CHECK_INTERVAL="${LIFEOS_CHECK_INTERVAL:-60}"   # 每分鐘看一次
ACTIVE_WINDOW_SECS=600   # jsonl 超過 10 分鐘沒動 = session 靜默，跳過本輪
KILL_GRACE_SECS=10       # TERM 之後等這麼久再 KILL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_HANDOFF="$SCRIPT_DIR/gen-handoff.sh"

# ── 斷頭緩衝參數消毒（必須在任何使用點之前；set -u 下垃圾環境值會在算術展開炸死整條狗）──
# 規則：非純數字／空／0／超過 5 位數 → 回預設；10# 強制十進位（防 08 被當八進位）
wrap_sanitize() {
    local v="${1:-}" d="$2"
    case "$v" in ''|*[!0-9]*) echo "$d"; return;; esac
    [ "${#v}" -gt 5 ] && { echo "$d"; return; }
    v=$((10#$v))
    [ "$v" -le 0 ] && v="$d"
    echo "$v"
}
WRAP_MAX_WAIT=$(wrap_sanitize "${LIFEOS_WRAP_MAX_WAIT:-}" 600)
WRAP_QUIET_SECS=$(wrap_sanitize "${LIFEOS_WRAP_QUIET_SECS:-}" 60)
WRAP_POLL_SECS=$(wrap_sanitize "${LIFEOS_WRAP_POLL_SECS:-}" 15)
[ "$WRAP_POLL_SECS" -gt "$WRAP_MAX_WAIT" ] && WRAP_POLL_SECS="$WRAP_MAX_WAIT"

LOG="$MEMORY_ROOT/.logs/watchdog-${SESSION_NAME}.log"
LOCK_DIR="$MEMORY_ROOT/.watchdog-${SESSION_NAME}.triggered.lock.d"
mkdir -p "$MEMORY_ROOT/.logs"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog:${SESSION_NAME}] $*" >> "$LOG"; }

# cwd → Claude Code 的 project 目錄 key（/ 與 . 都變 -）
PROJ_KEY=$(printf '%s' "$PROJECT_CWD" | sed 's#[/.]#-#g')
PROJ_DIR="$CLAUDE_HOME/projects/$PROJ_KEY"

# 開機自檢：上一世殘留的觸發鎖，若鎖內 PID 已死就清掉
if [[ -d "$LOCK_DIR" ]]; then
    _old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ -z "$_old_pid" ]] || ! kill -0 "$_old_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        log "清掉上一世殘留的觸發鎖（pid=${_old_pid:-none} 已不存在）"
    fi
fi

trap 'log "收到信號，狗退出（rc=$?）"' EXIT

# mtime 護欄參考檔：只 pin 比它新的 jsonl（touch 於啟動時與每次重生後）
START_REF="$MEMORY_ROOT/.watchdog-${SESSION_NAME}.startref"
touch "$START_REF"
PINNED_JSONL=""

# supervisor 身份快照：PID 會被系統回收重用，光 kill -0 不夠——
# 記下啟動時刻字串（LC_ALL=C 固定格式），之後每輪比對，防殺到重用 PID 的無辜進程
SUP_LSTART=$(LC_ALL=C ps -p "$SUPERVISOR_PID" -o lstart= 2>/dev/null | sed 's/  *$//')
if [[ -z "$SUP_LSTART" ]]; then
    log "supervisor ($SUPERVISOR_PID) 啟動時就不存在，狗退出"
    exit 1
fi

log "啟動：專案=$PROJECT_CWD 門檻=$THRESHOLD supervisor=$SUPERVISOR_PID lstart=[$SUP_LSTART]"
log "監看目錄：$PROJ_DIR"
log "斷頭緩衝參數：poll=${WRAP_POLL_SECS}s quiet=${WRAP_QUIET_SECS}s max=${WRAP_MAX_WAIT}s"

# 找要殺的 claude：首選 claw 寫的 pidfile（npm 版 claude 進程名是 node，
# pgrep -x claude 認不出）；沒 pidfile 再退回掃 supervisor 直接子進程
CLAW_PIDFILE="$MEMORY_ROOT/.claw-${SESSION_NAME}.claude.pid"
get_claude_pid() {
    local p
    p=$(cat "$CLAW_PIDFILE" 2>/dev/null || echo "")
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
        printf '%s' "$p"
        return 0
    fi
    for p in $(pgrep -P "$SUPERVISOR_PID" -x claude 2>/dev/null || true); do
        printf '%s' "$p"
        return 0
    done
    return 1
}

# ps etime（[[dd-]hh:]mm:ss）→ 秒；解析不了回 999999（當成很老，不算年輕子行程）
etime_to_secs() {
    local e="${1:-}" d=0 h=0 m=0 s=0 rest a b c
    case "$e" in *[!0-9:-]*|'') echo 999999; return;; esac
    if [[ "$e" == *-* ]]; then d="${e%%-*}"; rest="${e#*-}"; else rest="$e"; fi
    IFS=: read -r a b c <<< "$rest"
    if [[ -n "${c:-}" ]]; then h=$a; m=$b; s=$c
    elif [[ -n "${b:-}" ]]; then m=$a; s=$b
    else s=$a; fi
    case "$d$h$m$s" in *[!0-9]*) echo 999999; return;; esac
    echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
}

# claude 是否有「進行中 tool 工作」跡象：年輕子／孫行程（etime<600s）或有 CPU 的子行程。
# 長跑前景指令期間 transcript 可能長時間不動，這層防誤殺。
# 長駐 MCP server 子行程（老＋0 CPU）天然被過濾；判不準時方向一律是「不殺」。
has_active_tool_work() {
    local pid="$1" k et secs pcpu gk
    for k in $(pgrep -P "$pid" 2>/dev/null || true); do
        et=$(ps -p "$k" -o etime= 2>/dev/null | tr -d ' ')
        secs=$(etime_to_secs "$et")
        [ "$secs" -lt 600 ] && return 0
        pcpu=$(ps -p "$k" -o pcpu= 2>/dev/null | tr -d ' ' | cut -d. -f1)
        case "$pcpu" in ''|*[!0-9]*) pcpu=0;; esac
        [ "$pcpu" -ge 1 ] && return 0
        for gk in $(pgrep -P "$k" 2>/dev/null || true); do
            et=$(ps -p "$gk" -o etime= 2>/dev/null | tr -d ' ')
            secs=$(etime_to_secs "$et")
            [ "$secs" -lt 600 ] && return 0
        done
    done
    return 1
}

# 斷頭緩衝：撞門檻後、寫 handoff 前，等 session 走到輪與輪之間再動刀。
# 放行條件：transcript 靜止 ≥ WRAP_QUIET_SECS 且 claude 沒有活躍子行程。
# 最長 WRAP_MAX_WAIT 秒，撞頂照殺（不能無限等，否則狗形同虛設）。
# stat 失敗＝判不準，保守視為輪中多等一輪（不 fail-open）。
# 回傳 0＝放行（靜止）、1＝撞頂、2＝claude 已不在（不必等）。
wrap_up_buffer() {
    local transcript="$1" cpid="$2" start now deadline t_mtime t_age busy
    start=$(date +%s)
    deadline=$(( start + WRAP_MAX_WAIT ))
    while :; do
        now=$(date +%s)
        busy=0
        t_mtime=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo "")
        case "$t_mtime" in
            ''|*[!0-9]*)
                log "斷頭緩衝：stat transcript 失敗，保守視為輪中"
                busy=1
                ;;
            *)
                t_age=$(( now - t_mtime ))
                [ "$t_age" -lt "$WRAP_QUIET_SECS" ] && busy=1
                ;;
        esac
        if [[ -n "$cpid" ]] && ! kill -0 "$cpid" 2>/dev/null; then
            log "斷頭緩衝：claude PID=$cpid 已不在，停止等待"
            return 2
        fi
        if [ "$busy" -eq 0 ] && [[ -n "$cpid" ]] && has_active_tool_work "$cpid"; then
            busy=1
        fi
        if [ "$busy" -eq 0 ]; then
            log "斷頭緩衝：已靜止（等了 $(( now - start ))s），放行收尾"
            return 0
        fi
        if [ "$now" -ge "$deadline" ]; then
            log "斷頭緩衝：撞頂 ${WRAP_MAX_WAIT}s 仍在輪中，照殺"
            return 1
        fi
        sleep "$WRAP_POLL_SECS"
    done
}

while true; do
    sleep "$CHECK_INTERVAL"

    # supervisor 死了（或 PID 被重用成別的進程）→ 狗也退場（不留孤兒、不誤殺）
    _sup_now=$(LC_ALL=C ps -p "$SUPERVISOR_PID" -o lstart= 2>/dev/null | sed 's/  *$//')
    if [[ -z "$_sup_now" || "$_sup_now" != "$SUP_LSTART" ]]; then
        log "supervisor ($SUPERVISOR_PID) 已不存在（或 PID 被重用，lstart 不符），狗退出"
        exit 0
    fi

    # ── Pin：鎖定本世 session 的 transcript ──
    if [[ -z "$PINNED_JSONL" || ! -f "$PINNED_JSONL" ]]; then
        PINNED_JSONL=""
        [[ -d "$PROJ_DIR" ]] || continue
        # 兩道護欄：
        # 1. mtime：只接受狗啟動（或上次重生）後還有更新的 jsonl，防撿到上一世殘骸
        # 2. 檔頭 mode 行：主對話 session 的 jsonl 檔頭必有 "type":"mode"；
        #    helper 一次性 session（gen-handoff 的 claude -p、subagent sidechain）沒有。
        #    沒這道會 pin 到狗自己觸發 gen-handoff 時生出的殘檔（母系統實戰教訓）
        _candidate=""
        while IFS= read -r _c; do
            [[ -f "$_c" ]] || continue
            head -c 8192 "$_c" 2>/dev/null | grep -q '"type":"mode"' || continue
            _candidate="$_c"
            break
        done < <(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -newer "$START_REF" -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null)
        if [[ -n "${_candidate:-}" ]]; then
            PINNED_JSONL="$_candidate"
            log "pin transcript：$PINNED_JSONL"
        else
            continue  # session 還沒開始寫 transcript（或只有 helper jsonl）
        fi
    fi

    # session 靜默中（jsonl 沒在動）→ 不檢查
    _mtime=$(stat -f %m "$PINNED_JSONL" 2>/dev/null || stat -c %Y "$PINNED_JSONL" 2>/dev/null || echo 0)
    _now=$(date +%s)
    (( _now - _mtime > ACTIVE_WINDOW_SECS )) && continue

    # ── Token 計數：usage 三欄加總，取 transcript 最後一筆 ──
    CURRENT_TOKENS=$(python3 - "$PINNED_JSONL" << 'PYEOF'
import json, sys
last_total = 0
try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                d = json.loads(line)
                u = (d.get('message') or {}).get('usage') or d.get('usage') or {}
                total = (u.get('input_tokens', 0)
                         + u.get('cache_read_input_tokens', 0)
                         + u.get('cache_creation_input_tokens', 0))
                if total > 0:
                    last_total = total
            except Exception:
                continue
except Exception:
    pass
print(last_total)
PYEOF
    )
    CURRENT_TOKENS=${CURRENT_TOKENS:-0}

    # ── 門檻 gate ──
    [[ "$CURRENT_TOKENS" -ge "$THRESHOLD" ]] 2>/dev/null || continue

    # mkdir 原子鎖：防多條狗（或殘留進程）對同一 session 雙重觸發
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "token 超限（${CURRENT_TOKENS}）但觸發鎖被占用，跳過本輪"
        continue
    fi
    echo $$ > "$LOCK_DIR/pid"

    log "⚠️ 觸發：${CURRENT_TOKENS} >= ${THRESHOLD}，開始收尾"

    # Step 0: 斷頭緩衝（持觸發鎖等待，期間不會重入）
    _wrap_cpid=$(get_claude_pid || true)
    wrap_up_buffer "$PINNED_JSONL" "${_wrap_cpid:-}"

    # Step 1: 寫 handoff（記憶先落地，之後才准殺進程）
    if [[ -f "$GEN_HANDOFF" ]]; then
        if bash "$GEN_HANDOFF" "$PINNED_JSONL" >> "$LOG" 2>&1; then
            log "handoff 產出成功"
        else
            log "handoff 產出失敗（rc=$?），保留舊 handoff，仍繼續重生流程"
        fi
    else
        log "找不到 gen-handoff.sh（${GEN_HANDOFF}），跳過 handoff"
    fi

    # Step 1.5: 留 respawn 標記——必須在動刀「之前」放（claw 看到 claude 死時
    # 標記已在場才會重生；殺完才放會跟 claw 的死因判定賽跑）
    touch "$MEMORY_ROOT/.watchdog-${SESSION_NAME}.respawn"

    # Step 2: 終止 claude（TERM → 等 → KILL），claw wrapper 會重生它
    CLAUDE_PID=$(get_claude_pid || true)
    if [[ -n "${CLAUDE_PID:-}" ]]; then
        log "終止 claude PID=$CLAUDE_PID"
        kill -TERM "$CLAUDE_PID" 2>/dev/null || true
        for _i in $(seq 1 "$KILL_GRACE_SECS"); do
            kill -0 "$CLAUDE_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$CLAUDE_PID" 2>/dev/null; then
            log "TERM ${KILL_GRACE_SECS}s 未退，升級 KILL"
            kill -KILL "$CLAUDE_PID" 2>/dev/null || true
        fi
    else
        log "找不到 claude 進程（supervisor=$SUPERVISOR_PID 之下），可能已自行退出"
    fi

    # Step 3: 解鎖 + 解 pin，重設 mtime 護欄，等 claw 拉起的新 session
    rm -rf "$LOCK_DIR"
    PINNED_JSONL=""
    touch "$START_REF"
    log "收尾完成，等待新 session"
done
