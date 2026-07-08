#!/usr/bin/env bash
# claw sandbox 測試駕駛：假 claude（bash 腳本，寫 ARGS log）＋真 watchdog＋stub gen-handoff
# 驗證：起狗/鎖/pidfile、正常退出不重生＋rc 透傳、狗殺重生塞 resume、
#       stale 標記不採信、重生風暴煞車、同名雙開擋下、真狗整合觸發
set -u

SB="$(cd "$(dirname "$0")" && pwd)/sandbox"
SRC="$(cd "$(dirname "$0")/.." && pwd)/memory-harness/scripts"
rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/scripts" "$SB/work" "$SB/memory" "$SB/home/.claude/projects"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

FAKE_LOG="$SB/claude-args.log"

# 假 claude：記 ARGS 後睡（exec 模式可被 TERM 直殺；非 exec 模式可控 rc）
cat > "$SB/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'ARGS|%s\n' "\$*" >> "$FAKE_LOG"
if [[ "\${FAKE_EXEC_SLEEP:-1}" == "1" ]]; then
    exec sleep "\${FAKE_LIFE:-300}"
else
    sleep "\${FAKE_LIFE:-300}"
    exit "\${FAKE_RC:-0}"
fi
EOF
chmod +x "$SB/bin/claude"

cp "$SRC/claw" "$SRC/watchdog.sh" "$SB/scripts/"
cat > "$SB/scripts/gen-handoff.sh" <<'EOF'
#!/usr/bin/env bash
echo "CALLED_WITH:$1" >> "$(dirname "$0")/gen-handoff.calls"
exit 0
EOF
chmod +x "$SB/scripts/"*

MEM="$SB/memory"
ENVV=(env PATH="$SB/bin:$PATH" LIFEOS_MEMORY_ROOT="$MEM" CLAUDE_HOME="$SB/home/.claude"
     LIFEOS_TOKEN_THRESHOLD=1000 LIFEOS_CHECK_INTERVAL=1
     CLAW_RESPAWN_DELAY=0 CLAW_FAST_DEATH_SECS=60 CLAW_MAX_FAST_DEATHS=3)
run_claw() {  # run_claw <輸出檔> [claw 參數…]（於 $SB/work 執行，背景）
    # pid 走全域 CLAW_PID，不能 echo $! 給 $() 接——命令替換會等背景子孫關閉
    # pipe 才 EOF，等於同步等 claw 跑完，所有「活著期間」的檢查全部失真
    local out="$1"; shift
    ( cd "$SB/work" && "${ENVV[@]}" bash "$SB/scripts/claw" "$@" > "$out" 2>&1 ) &
    CLAW_PID=$!
}
pidfile(){ echo "$MEM/.claw-${1}.claude.pid"; }
mark()   { echo "$MEM/.watchdog-${1}.respawn"; }

echo "— C1/C2 正常退出：起狗、鎖、pidfile；不重生、rc 透傳、清乾淨 —"
: > "$FAKE_LOG"
FAKE_EXEC_SLEEP=0 FAKE_LIFE=4 FAKE_RC=7 run_claw "$SB/c1.out" alpha; W1=$CLAW_PID
sleep 1.5
check "claw 鎖已建立" "[[ -d '$MEM/.claw-alpha.lock.d' ]]"
check "pidfile 已寫且進程活著" "kill -0 \$(cat '$(pidfile alpha)') 2>/dev/null"
DOG1=$(pgrep -f "watchdog.sh alpha" | head -1)
check "狗已掛上" "[[ -n '$DOG1' ]] && kill -0 $DOG1"
check "首世無 resume prompt" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 1 && ! grep -q '自動 resume' '$FAKE_LOG'"
wait "$W1"; RC1=$?
check "正常退出不重生（僅 1 次 ARGS）" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 1"
check "rc 透傳（7）" "[[ $RC1 -eq 7 ]]"
sleep 1
check "退出後鎖已清" "[[ ! -d '$MEM/.claw-alpha.lock.d' ]]"
check "退出後狗已收" "! kill -0 $DOG1 2>/dev/null"

echo "— C3 狗殺重生：標記＋殺 → 塞 resume prompt 重生 —"
: > "$FAKE_LOG"
run_claw "$SB/c3.out" beta; W2=$CLAW_PID
sleep 1.5
P1=$(cat "$(pidfile beta)")
touch "$(mark beta)"
kill -TERM "$P1"
sleep 2
check "已重生（2 次 ARGS）" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 2"
check "重生帶 resume prompt" "grep -q '自動 resume' '$FAKE_LOG'"
check "resume 指向 handoff 路徑" "grep -q 'handoff/work.md' '$FAKE_LOG'"
check "標記已被消化" "[[ ! -f '$(mark beta)' ]]"
P2=$(cat "$(pidfile beta)" 2>/dev/null || echo "")
check "新世 pidfile 更新" "[[ -n '$P2' && '$P2' != '$P1' ]] && kill -0 $P2"
# 無標記殺掉 → claw 收工
kill -TERM "$P2"
sleep 1.5
check "無標記被殺 → 不重生收工" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 2 && grep -q '非狗所殺' '$SB/c3.out'"
wait "$W2" 2>/dev/null

echo "— C4 stale 標記不採信 —"
: > "$FAKE_LOG"
run_claw "$SB/c4.out" gamma; W3=$CLAW_PID
sleep 1.5
P3=$(cat "$(pidfile gamma)")
touch -t "$(date -v-11M '+%Y%m%d%H%M.%S')" "$(mark gamma)" 2>/dev/null || touch -d '11 minutes ago' "$(mark gamma)"
kill -TERM "$P3"
sleep 1.5
check "stale 標記 → 不重生" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 1 && grep -q '非狗所殺' '$SB/c4.out'"
wait "$W3" 2>/dev/null

echo "— C5 重生風暴煞車 —"
: > "$FAKE_LOG"
( while true; do touch "$(mark delta)"; sleep 0.1; done ) & TOUCHER=$!
# FAKE_LIFE=1（非 0）：claude 得活過 toucher 的 0.1s 週期，死時標記才在場
FAKE_EXEC_SLEEP=0 FAKE_LIFE=1 FAKE_RC=0 run_claw "$SB/c5.out" delta; W4=$CLAW_PID
wait "$W4"; RC4=$?
kill "$TOUCHER" 2>/dev/null
rm -f "$(mark delta)"
check "3 次快死後煞車（3 次 ARGS）" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 3"
check "煞車退出碼=1 且有說明" "[[ $RC4 -eq 1 ]] && grep -q '停止重生' '$SB/c5.out'"

echo "— C6 同名雙開擋下 —"
: > "$FAKE_LOG"
run_claw "$SB/c6a.out" solo; W5=$CLAW_PID
sleep 1.5
( cd "$SB/work" && "${ENVV[@]}" bash "$SB/scripts/claw" solo > "$SB/c6b.out" 2>&1 )
RC6=$?
check "第二個 claw 被擋（rc=1）" "[[ $RC6 -eq 1 ]] && grep -q '已有 claw 在跑' '$SB/c6b.out'"
kill -TERM "$(cat "$(pidfile solo)")" 2>/dev/null
wait "$W5" 2>/dev/null

echo "— C7 真狗整合：jsonl 超門檻 → handoff → 殺 → 重生 —"
: > "$FAKE_LOG"; rm -f "$SB/scripts/gen-handoff.calls"
PROJ_KEY=$(printf '%s' "$SB/work" | sed 's#[/.]#-#g')
PROJ_DIR="$SB/home/.claude/projects/$PROJ_KEY"
mkdir -p "$PROJ_DIR"
run_claw "$SB/c7.out" omega; W6=$CLAW_PID
sleep 2
P7=$(cat "$(pidfile omega)")
J="$PROJ_DIR/session1.jsonl"
printf '{"type":"mode","mode":"default","sessionId":"s1"}\n' > "$J"
printf '{"message":{"usage":{"input_tokens":900,"cache_read_input_tokens":300,"cache_creation_input_tokens":0}}}\n' >> "$J"
sleep 5
check "真狗呼叫 gen-handoff（pinned jsonl）" "grep -q \"CALLED_WITH:$J\" '$SB/scripts/gen-handoff.calls' 2>/dev/null"
check "舊世 claude 被狗殺" "! kill -0 $P7 2>/dev/null"
check "claw 重生新世（2 次 ARGS＋resume）" "grep -c 'ARGS' '$FAKE_LOG' | grep -qx 2 && grep -q '自動 resume' '$FAKE_LOG'"
check "claw 還活著" "kill -0 $W6 2>/dev/null"
DOG7=$(pgrep -f "watchdog.sh omega" | head -1)
check "狗還活著" "[[ -n '$DOG7' ]]"
# 收尾：TERM claw → EXIT trap 清狗清鎖（用 claw 鎖裡的 $$，不賭子 shell 是否 implicit-exec）
kill -TERM "$(cat "$MEM/.claw-omega.lock.d/pid" 2>/dev/null)" 2>/dev/null
sleep 1.5
check "TERM claw → 鎖已清" "[[ ! -d '$MEM/.claw-omega.lock.d' ]]"
check "TERM claw → 狗已收" "! kill -0 $DOG7 2>/dev/null"
kill -9 "$(cat "$(pidfile omega)" 2>/dev/null)" 2>/dev/null   # 假 claude 不陪葬屬預期，手動清
wait 2>/dev/null

echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
