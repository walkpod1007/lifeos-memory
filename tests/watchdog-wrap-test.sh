#!/usr/bin/env bash
# watchdog 斷頭緩衝（wrap-up buffer）沙箱測試
# 驗證：(a) transcript 剛被寫入 → 不立刻殺，靜止後才殺
#       (b) 一直在寫 → 撞 LIFEOS_WRAP_MAX_WAIT 照殺（不無限等）
#       (c) 垃圾環境值回預設（含 08 十進位）
#       (d) stat transcript 失敗不 fail-open（保守多等，撞頂才殺）
#       (e) 年輕子行程（活躍工具工作）算輪中
# 等待時間全用環境變數縮到幾秒，不真等 600 秒。
set -u

SB="$(cd "$(dirname "$0")" && pwd)/sandbox-wrap"
SRC="$(cd "$(dirname "$0")/.." && pwd)/memory-harness/scripts"
rm -rf "$SB"; mkdir -p "$SB"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

PIDS_TO_CLEAN=()
cleanup() { local p; for p in "${PIDS_TO_CLEAN[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done; }
trap cleanup EXIT

# 孤兒化的長睡行程（避免變成本 shell 的殭屍而讓 kill -0 誤判還活著）
spawn_sleep() { bash -c 'sleep 600 >/dev/null 2>&1 & echo $!'; }
alive() { local s; s=$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' '); [[ -n "$s" && "$s" != Z* ]]; }

# setup_case <名> → 設 C_DIR/C_MEM/C_HOME/C_WORK/C_PROJ/C_SUP/C_CLAUDE
setup_case() {
    C_DIR="$SB/$1"; C_MEM="$C_DIR/memory"; C_HOME="$C_DIR/home/.claude"; C_WORK="$C_DIR/work"
    mkdir -p "$C_DIR/scripts" "$C_MEM" "$C_HOME/projects" "$C_WORK"
    cp "$SRC/watchdog.sh" "$C_DIR/scripts/"
    cat > "$C_DIR/scripts/gen-handoff.sh" <<'EOF'
#!/usr/bin/env bash
date +%s >> "$(dirname "$0")/gen-handoff.calls"
exit 0
EOF
    C_PROJ="$C_HOME/projects/$(printf '%s' "$C_WORK" | sed 's#[/.]#-#g')"
    mkdir -p "$C_PROJ"
    C_SUP=$(spawn_sleep); C_CLAUDE=$(spawn_sleep)
    PIDS_TO_CLEAN+=("$C_SUP" "$C_CLAUDE")
    echo "$C_CLAUDE" > "$C_MEM/.claw-$1.claude.pid"
}
# start_dog <名> [ENV=值…] → 設 C_DOG
start_dog() {
    local name="$1"; shift
    env "$@" LIFEOS_MEMORY_ROOT="$C_MEM" CLAUDE_HOME="$C_HOME" LIFEOS_TOKEN_THRESHOLD=1000 \
        LIFEOS_CHECK_INTERVAL=1 bash "$C_DIR/scripts/watchdog.sh" "$name" "$C_WORK" "$C_SUP" >/dev/null 2>&1 &
    C_DOG=$!; disown "$C_DOG" 2>/dev/null
    PIDS_TO_CLEAN+=("$C_DOG")
    sleep 1.3   # 讓 startref 比之後寫的 jsonl 舊
}
write_transcript() {  # 超門檻的 transcript（檔頭 mode 行＋usage 1200）
    printf '{"type":"mode","mode":"default","sessionId":"s1"}\n' > "$1"
    printf '{"message":{"usage":{"input_tokens":900,"cache_read_input_tokens":300,"cache_creation_input_tokens":0}}}\n' >> "$1"
}
wait_dead() {  # wait_dead <pid> <最多等幾秒>
    local i; for ((i=0; i<$2*5; i++)); do alive "$1" || return 0; sleep 0.2; done; return 1
}
stop_case() { kill -9 "$C_DOG" "$C_SUP" "$C_CLAUDE" 2>/dev/null; sleep 0.2; }
dog_log() { cat "$C_MEM/.logs/watchdog-$1.log" 2>/dev/null; }

echo "— W1 (a) transcript 剛寫入 → 不立刻殺，靜止後才殺 —"
setup_case wa
start_dog wa LIFEOS_WRAP_QUIET_SECS=4 LIFEOS_WRAP_POLL_SECS=1 LIFEOS_WRAP_MAX_WAIT=30
T0=$(date +%s)
write_transcript "$C_PROJ/s1.jsonl"
sleep 2.5
check "(a) 寫入後 2.5 秒：claude 還活著" "alive $C_CLAUDE"
check "(a) 寫入後 2.5 秒：handoff 還沒產" "[[ ! -f '$C_DIR/scripts/gen-handoff.calls' ]]"
wait_dead "$C_CLAUDE" 15; DEAD_RC=$?
T1=$(date +%s)
check "(a) 靜止後 claude 被殺" "[[ $DEAD_RC -eq 0 ]]"
check "(a) 殺在寫入 3 秒之後（靜止門檻 4s）" "[[ $((T1 - T0)) -ge 3 ]]"
check "(a) handoff 先於殺產出" "[[ -f '$C_DIR/scripts/gen-handoff.calls' ]]"
check "(a) log 有「已靜止」放行" "dog_log wa | grep -q '已靜止'"
stop_case

echo "— W2 (b) 一直在寫 → 撞 MAX_WAIT 照殺 —"
setup_case wb
start_dog wb LIFEOS_WRAP_QUIET_SECS=3 LIFEOS_WRAP_POLL_SECS=1 LIFEOS_WRAP_MAX_WAIT=3
write_transcript "$C_PROJ/s1.jsonl"
( while true; do printf '{"x":1}\n' >> "$C_PROJ/s1.jsonl"; sleep 0.4; done ) >/dev/null 2>&1 &
WRITER=$!; disown "$WRITER" 2>/dev/null; PIDS_TO_CLEAN+=("$WRITER")
T0=$(date +%s)
wait_dead "$C_CLAUDE" 20; DEAD_RC=$?
T1=$(date +%s)
kill -9 "$WRITER" 2>/dev/null
check "(b) 一直在寫仍被殺（不無限等）" "[[ $DEAD_RC -eq 0 ]]"
check "(b) log 有「撞頂」" "dog_log wb | grep -q '撞頂'"
check "(b) 沒有「已靜止」放行" "! dog_log wb | grep -q '已靜止'"
check "(b) 殺得不算太晚（< 15 秒）" "[[ $((T1 - T0)) -lt 15 ]]"
stop_case

echo "— W3 (c) 垃圾環境值回預設 —"
setup_case wc1
start_dog wc1 LIFEOS_WRAP_MAX_WAIT=abc LIFEOS_WRAP_QUIET_SECS=08 LIFEOS_WRAP_POLL_SECS=
check "(c) abc/08/空 → max=600 quiet=8（十進位）poll=15" "dog_log wc1 | grep -q 'poll=15s quiet=8s max=600s'"
stop_case
setup_case wc2
start_dog wc2 LIFEOS_WRAP_MAX_WAIT=123456 LIFEOS_WRAP_QUIET_SECS=0 LIFEOS_WRAP_POLL_SECS=-5
check "(c) 六位數/0/負數 → 全回預設" "dog_log wc2 | grep -q 'poll=15s quiet=60s max=600s'"
stop_case
setup_case wc3
start_dog wc3 LIFEOS_WRAP_MAX_WAIT=5 LIFEOS_WRAP_POLL_SECS=99
check "(c) poll 大於 max → 夾到 max" "dog_log wc3 | grep -q 'poll=5s quiet=60s max=5s'"
stop_case

echo "— W4 (d) stat 失敗不 fail-open —"
setup_case wd
start_dog wd LIFEOS_WRAP_QUIET_SECS=3 LIFEOS_WRAP_POLL_SECS=1 LIFEOS_WRAP_MAX_WAIT=7
write_transcript "$C_PROJ/s1.jsonl"
sleep 1.2
rm -f "$C_PROJ/s1.jsonl"
T0=$(date +%s)
sleep 2.5
check "(d) transcript 消失 2.5 秒後 claude 仍活著（沒有 fail-open）" "alive $C_CLAUDE"
wait_dead "$C_CLAUDE" 15; DEAD_RC=$?
check "(d) 撞頂後仍會殺" "[[ $DEAD_RC -eq 0 ]]"
check "(d) log 有 stat 失敗保守等待" "dog_log wd | grep -q 'stat transcript 失敗'"
check "(d) log 是撞頂而非已靜止" "dog_log wd | grep -q '撞頂' && ! dog_log wd | grep -q '已靜止'"
stop_case

echo "— W5 (e) 年輕子行程算輪中 —"
setup_case we
# 以一個真的 bash 當 claude，底下掛年輕的 sleep 子行程
CL=$(bash -c 'bash -c "sleep 600 >/dev/null 2>&1 & wait" >/dev/null 2>&1 & echo $!')
PIDS_TO_CLEAN+=("$CL")
echo "$CL" > "$C_MEM/.claw-we.claude.pid"
sleep 0.5
check "(e) 前置：假 claude 有子行程" "pgrep -P $CL >/dev/null"
start_dog we LIFEOS_WRAP_QUIET_SECS=2 LIFEOS_WRAP_POLL_SECS=1 LIFEOS_WRAP_MAX_WAIT=6
write_transcript "$C_PROJ/s1.jsonl"
sleep 4.5
check "(e) transcript 已靜止但有年輕子行程 → 4.5 秒後還沒殺" "alive $CL"
wait_dead "$CL" 15; DEAD_RC=$?
check "(e) 仍受 MAX_WAIT 約束，撞頂後會殺" "[[ $DEAD_RC -eq 0 ]] && dog_log we | grep -q '撞頂'"
pkill -P "$CL" 2>/dev/null
stop_case

echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"
rm -rf "$SB"
[[ $FAIL -eq 0 ]]
