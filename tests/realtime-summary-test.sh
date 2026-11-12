#!/usr/bin/env bash
# realtime-summary.sh 沙箱測試（假 claude／假 qmd／假 ps，全程在 tests/sandbox-rts 內）
# 驗證：
#   R1 鎖持有者判定（_rts_lock_holder_alive）
#   R2 鎖整合：持有者活著不拆；持有者已死＋鎖齡 >30 分才拆；pid 檔缺失＋新鎖不拆
#   R3 索引 writer／reader 判定（qmd_writer_procs，REALTIME_SUMMARY_LIB_ONLY=1 只載入函式）
#   R4 索引更新防撞整合：writer 在跑→跳過並計數；ps 失敗→跳過（fail-safe）；計數檔寫不進去有 log；每 N 輪警告
#   R5 簡體重抽：前兩趟簡體第三趟繁體→只收第三趟；三趟都簡體→照收並有警告 log；檢查器缺席→略過
set -u

SB="$(cd "$(dirname "$0")" && pwd)/sandbox-rts"
SRC="$(cd "$(dirname "$0")/.." && pwd)/memory-harness/scripts"
rm -rf "$SB"; mkdir -p "$SB/bin"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SPAWNED=()
cleanup() { local p; for p in "${SPAWNED[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done; }
trap cleanup EXIT

RS="$SRC/realtime-summary.sh"
lib() { REALTIME_SUMMARY_LIB_ONLY=1 LIFEOS_MEMORY_ROOT="$SB/libmem" bash -c "source '$RS'; $1"; }

# ── 假 ps：只攔 `-Ao`（行程表快照），其餘轉給真 ps ──
REAL_PS="$(command -v ps)"
cat > "$SB/bin/ps" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "-Ao" ]]; then
        case "\${FAKE_PS_MODE:-real}" in
            fail)  exit 1 ;;
            empty) exit 0 ;;
            fixed) cat "\${FAKE_PS_FILE:?}"; exit 0 ;;
        esac
    fi
done
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SB/bin/ps"

# ── 假 qmd：記下每次被叫的參數 ──
cat > "$SB/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "QMD|$*" >> "${FAKE_QMD_LOG:?}"
[[ "$1" == "collection" && "${2:-}" == "list" ]] && echo "memory"
exit 0
EOF
chmod +x "$SB/bin/qmd"

# ── 假 claude：記 prompt、計次數，依 FAKE_MODE 回簡體／繁體 ──
cat > "$SB/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "${FAKE_CLAUDE_PROMPT:?}"
n=$(cat "${FAKE_CLAUDE_COUNT:?}" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_CLAUDE_COUNT"
simp=0
case "${FAKE_MODE:-trad}" in
    simp-then-trad) [[ "$n" -le 2 ]] && simp=1 ;;
    all-simp)       simp=1 ;;
esac
if [[ "$simp" == "1" ]]; then
    printf 'SUMMARY: 这个项目的进度已经更新\nSLUG: simp-slug\nSTATE:\n## 近况\n[x] 简体近况\n'
else
    printf 'SUMMARY: 這個專案的進度已經更新\nSLUG: trad-slug\nSTATE:\n## 近況\n[x] 繁體近況\n'
fi
EOF
chmod +x "$SB/bin/claude"

spawn_named() {  # 命令列含 realtime-summary.sh 的長睡行程（孤兒化，pid 印到 stdout）
    bash -c 'bash -c "sleep 120; :" realtime-summary.sh >/dev/null 2>&1 & echo $!'
}
spawn_plain() { bash -c 'sleep 120 >/dev/null 2>&1 & echo $!'; }

echo "— R1 鎖持有者判定 —"
P_NAMED=$(spawn_named); P_PLAIN=$(spawn_plain); SPAWNED+=("$P_NAMED" "$P_PLAIN")
sleep 0.3
check "R1 命令列含 realtime-summary.sh 的活行程 → 活著" "lib '_rts_lock_holder_alive $P_NAMED'"
check "R1 活著但命令列不是本腳本（pid 被重用）→ 視為已死" "! lib '_rts_lock_holder_alive $P_PLAIN'"
kill -9 "$P_PLAIN" 2>/dev/null; sleep 0.3
check "R1 已死的 pid → 已死" "! lib '_rts_lock_holder_alive $P_PLAIN'"
check "R1 空字串／非數字 → 已死" "! lib '_rts_lock_holder_alive \"\"' && ! lib '_rts_lock_holder_alive abc'"

echo "— R2 鎖整合 —"
old_lock() {  # old_lock <記憶目錄> [pid]  造一個 2 小時前的鎖目錄（pid 檔先寫、最後才回溯目錄時間，否則寫檔會更新目錄 mtime）
    mkdir -p "$1/.realtime-summary.lock.d"
    [[ -n "${2:-}" ]] && echo "$2" > "$1/.realtime-summary.lock.d/pid"
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S')" "$1/.realtime-summary.lock.d"
}
run_rs() {  # run_rs <記憶目錄> <輸出檔> [env…]
    local m="$1" o="$2"; shift 2
    env HOME="$SB/home" CLAUDE_HOME="$SB/home/.claude" LIFEOS_MEMORY_ROOT="$m" LIFEOS_QMD_COLLECTION= \
        LIFEOS_WATCH=no-such-proj PATH="$SB/bin:$PATH" "$@" bash "$RS" > "$o" 2>&1
}
mkdir -p "$SB/home/.claude/projects"
# L1：鎖齡 >30 分鐘，但持有者 pid 是活的 → 不拆
M="$SB/l1"; old_lock "$M" "$P_NAMED"
run_rs "$M" "$SB/l1.out"; RC=$?
check "R2 齡>30 分但持有者活著：rc 0、說 busy、鎖目錄與 pid 檔都在" "[[ $RC -eq 0 ]] && grep -q 'holder pid=$P_NAMED alive' '$SB/l1.out' && [[ -d '$M/.realtime-summary.lock.d' && \$(cat '$M/.realtime-summary.lock.d/pid') == '$P_NAMED' ]]"
# L2：持有者已死＋齡>30 分 → 拆
M="$SB/l2"; old_lock "$M" 999999
run_rs "$M" "$SB/l2.out"; RC=$?
check "R2 持有者已死＋齡>30 分：強拆並跑完（說 stale、結束後鎖已清）" "[[ $RC -eq 0 ]] && grep -q 'stale' '$SB/l2.out' && [[ ! -d '$M/.realtime-summary.lock.d' ]]"
# L3：pid 檔缺失＋新鎖 → 不拆
M="$SB/l3"; mkdir -p "$M/.realtime-summary.lock.d"
run_rs "$M" "$SB/l3.out"; RC=$?
check "R2 pid 檔缺失＋新鎖：不拆（busy、鎖目錄還在）" "[[ $RC -eq 0 ]] && grep -q 'busy, skip' '$SB/l3.out' && [[ -d '$M/.realtime-summary.lock.d' ]]"
# L4：pid 檔缺失＋舊鎖 → 拆
M="$SB/l4"; old_lock "$M"
run_rs "$M" "$SB/l4.out"; RC=$?
check "R2 pid 檔缺失＋齡>30 分：強拆" "[[ $RC -eq 0 ]] && grep -q 'stale' '$SB/l4.out' && [[ ! -d '$M/.realtime-summary.lock.d' ]]"
# L5：活著但不是本腳本的 pid（重用）＋舊鎖 → 拆
P_PLAIN2=$(spawn_plain); SPAWNED+=("$P_PLAIN2"); sleep 0.2
M="$SB/l5"; old_lock "$M" "$P_PLAIN2"
run_rs "$M" "$SB/l5.out"; RC=$?
check "R2 pid 被別的行程重用＋齡>30 分：視為持有者已死，強拆" "[[ $RC -eq 0 ]] && grep -q 'stale' '$SB/l5.out'"
# L6：正常跑時鎖內有 pid 檔，結束後清乾淨
M="$SB/l6"; run_rs "$M" "$SB/l6.out"
check "R2 正常跑完：鎖目錄（含 pid 檔）清乾淨" "[[ ! -e '$M/.realtime-summary.lock.d' ]]"
kill -9 "$P_NAMED" "$P_PLAIN2" 2>/dev/null

echo "— R3 索引 writer／reader 判定 —"
wp() { printf '%s\n' "$1" | lib 'qmd_writer_procs'; }
check "R3 旗標在前：node qmd.js --index x embed → writer" "[[ -n \"\$(wp '101 node /opt/qmd/qmd.js --index x embed')\" ]]"
check "R3 一般：qmd update -c memory → writer" "[[ -n \"\$(wp '102 /usr/local/bin/qmd update -c memory')\" ]]"
check "R3 qmd embed -c search → writer（reader 字樣在 writer 後面不放行）" "[[ -n \"\$(wp '103 /usr/local/bin/qmd embed -c search')\" ]]"
check "R3 qmd search embed things → reader（關鍵字帶 embed 不算 writer）" "[[ -z \"\$(wp '104 node /opt/qmd/qmd.js search embed things')\" ]]"
check "R3 qmd query / status → reader" "[[ -z \"\$(wp '105 qmd query hello')\" && -z \"\$(wp '106 qmd status')\" ]]"
check "R3 embedding-report 逐 token 全等，不算 writer" "[[ -z \"\$(wp '107 qmd embedding-report')\" ]]"
check "R3 不是 qmd 的行程（grep qmd embed）不算" "[[ -z \"\$(wp '108 grep qmd embed')\" ]]"
check "R3 bun 跑 qmd.js update → writer" "[[ -n \"\$(wp '109 bun /opt/qmd/qmd.js update')\" ]]"

echo "— R4 索引更新防撞整合 —"
mkdir -p "$SB/ps"
printf '201 /bin/bash something-else\n202 node /opt/qmd/qmd.js --index x embed\n' > "$SB/ps/writer.txt"
printf '201 /bin/bash something-else\n203 node /opt/qmd/qmd.js search embed things\n' > "$SB/ps/reader.txt"
printf '201 /bin/bash something-else\n204 /usr/bin/python3 foo.py\n' > "$SB/ps/clean.txt"
rs_idx() {  # rs_idx <名> <ps模式> [env…]  → 記憶目錄 $SB/<名>，qmd 呼叫記錄 $SB/<名>.qmd
    local n="$1" mode="$2"; shift 2
    : > "$SB/$n.qmd"
    env HOME="$SB/home" CLAUDE_HOME="$SB/home/.claude" LIFEOS_MEMORY_ROOT="$SB/$n" LIFEOS_QMD_COLLECTION=memory \
        LIFEOS_WATCH=no-such-proj PATH="$SB/bin:$PATH" FAKE_QMD_LOG="$SB/$n.qmd" FAKE_PS_MODE="$mode" \
        FAKE_PS_FILE="$SB/ps/${FAKE_PS_NAME:-writer}.txt" "$@" bash "$RS" > "$SB/$n.out" 2>&1
}
rs_idx i1 fixed
check "R4 writer 在跑：不起 qmd update/embed" "! grep -q 'QMD|update' '$SB/i1.qmd' && ! grep -q 'QMD|embed' '$SB/i1.qmd'"
check "R4 writer 在跑：log 有跳過說明" "grep -q '既有 qmd update/embed 執行中' '$SB/i1/.logs/realtime-summary.log'"
check "R4 writer 在跑：連續跳過計數 = 1" "[[ \$(cat '$SB/i1/.checkpoints/index-skip.count') -eq 1 ]]"
rs_idx i1 fixed
check "R4 再跳一輪：計數 = 2" "[[ \$(cat '$SB/i1/.checkpoints/index-skip.count') -eq 2 ]]"
FAKE_PS_NAME=reader rs_idx i1 fixed
check "R4 只有 reader：放行（起了 update 與 embed）" "grep -q 'QMD|update' '$SB/i1.qmd' && grep -q 'QMD|embed' '$SB/i1.qmd'"
check "R4 放行後計數檔清掉" "[[ ! -e '$SB/i1/.checkpoints/index-skip.count' ]]"
rs_idx i2 fail
check "R4 ps 失敗：fail-safe 跳過（不起 qmd）並留 log" "! grep -q 'QMD|update' '$SB/i2.qmd' && grep -q '行程表快照失敗或為空' '$SB/i2/.logs/realtime-summary.log'"
check "R4 ps 失敗也計入連續跳過" "[[ \$(cat '$SB/i2/.checkpoints/index-skip.count') -eq 1 ]]"
rs_idx i3 empty
check "R4 ps 回空：同樣 fail-safe 跳過" "! grep -q 'QMD|update' '$SB/i3.qmd' && grep -q '行程表快照失敗或為空' '$SB/i3/.logs/realtime-summary.log'"
# 每 N 輪警告
rs_idx i4 fixed LIFEOS_INDEX_SKIP_WARN_EVERY=2
check "R4 第 1 輪（N=2）：還沒有警告" "! grep -q '已連續跳過' '$SB/i4/.logs/realtime-summary.log'"
rs_idx i4 fixed LIFEOS_INDEX_SKIP_WARN_EVERY=2
check "R4 第 2 輪（N=2）：log 出現連續跳過警告" "grep -q '已連續跳過 2 輪' '$SB/i4/.logs/realtime-summary.log'"
# 計數檔寫不進去要出聲
RO="$(mktemp -d "$SB/ro-XXXXXX")"; chmod 555 "$RO"
rs_idx i5 fixed LIFEOS_INDEX_SKIP_COUNT_FILE="$RO/sub/count"
if [[ -w "$RO" ]]; then
    ok "R4 計數檔不可寫（此環境造不出唯讀目錄，略過）"
else
    check "R4 計數檔寫不進去：log 出聲而不是靜默" "grep -q '計數檔寫不進去' '$SB/i5/.logs/realtime-summary.log'"
fi
chmod 755 "$RO"
check "R4 連跑兩次之後主流程沒被計數檔問題弄壞（rc 0、無 qmd 寫入）" "! grep -q 'QMD|update' '$SB/i5.qmd'"
# 固定快照、無 writer → 放行（不讀宿主真行程表，宿主有 qmd 在跑也不會假紅）
FAKE_PS_NAME=clean rs_idx i6 fixed
check "R4 固定快照、無 writer：放行" "grep -q 'QMD|update' '$SB/i6.qmd'"

echo "— R5 簡體重抽 —"
mk_session() {  # mk_session <名> → 設 R_HOME，內含一條活躍 jsonl
    R_HOME="$SB/$1/home"; local d="$R_HOME/.claude/projects/-home-u-rproj"
    mkdir -p "$d"
    python3 - "$d/aaaa1111-0000.jsonl" <<'PYEOF'
import json, sys
rows = [
 {"type":"user","message":{"role":"user","content":"請幫我更新進度"}},
 {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好，已經處理。"}]}},
]
open(sys.argv[1],"w",encoding="utf-8").write("\n".join(json.dumps(r,ensure_ascii=False) for r in rows)+"\n")
PYEOF
}
rs_sum() {  # rs_sum <名> <模式> [script] → 記憶目錄 $SB/<名>/mem
    local n="$1" mode="$2" script="${3:-$RS}"
    mk_session "$n"
    echo 0 > "$SB/$n.count"
    env HOME="$R_HOME" CLAUDE_HOME="$R_HOME/.claude" LIFEOS_MEMORY_ROOT="$SB/$n/mem" LIFEOS_QMD_COLLECTION= \
        LIFEOS_SUMMARY_RETRY_UNIT=0 PATH="$SB/bin:$PATH" FAKE_MODE="$mode" \
        FAKE_CLAUDE_COUNT="$SB/$n.count" FAKE_CLAUDE_PROMPT="$SB/$n.prompt" bash "$script" > "$SB/$n.out" 2>&1
}
daily_cat() { cat "$SB/$1"/mem/daily/*/*.md 2>/dev/null; }
rs_sum s1 simp-then-trad
check "R5 prompt 明寫台灣慣用繁體、禁止簡體" "grep -q '台灣慣用繁體' '$SB/s1.prompt' && grep -q '禁止簡體' '$SB/s1.prompt'"
check "R5 前兩趟簡體：共呼叫 3 次" "[[ \$(cat '$SB/s1.count') -eq 3 ]]"
check "R5 只收第三趟（daily 檔含繁體、不含簡体字）" "daily_cat s1 | grep -q '這個專案的進度' && ! daily_cat s1 | grep -q '这个'"
check "R5 前兩趟各留一行重抽 log" "[[ \$(grep -c '驗到簡體字，重抽一次' '$SB/s1/mem/.logs/realtime-summary.log') -eq 2 ]]"
rs_sum s2 all-simp
check "R5 三趟都簡體：共呼叫 3 次" "[[ \$(cat '$SB/s2.count') -eq 3 ]]"
check "R5 三趟都簡體：照收（只重試不否決）" "daily_cat s2 | grep -q '这个项目'"
check "R5 三趟都簡體：留警告 log" "grep -q '三趟都驗到簡體字，照收' '$SB/s2/mem/.logs/realtime-summary.log'"
rs_sum s3 trad
check "R5 第一趟就繁體：只呼叫 1 次、無重抽 log" "[[ \$(cat '$SB/s3.count') -eq 1 ]] && ! grep -q '重抽' '$SB/s3/mem/.logs/realtime-summary.log' 2>/dev/null"
mkdir -p "$SB/lonely"; cp "$RS" "$SB/lonely/"
rs_sum s4 all-simp "$SB/lonely/realtime-summary.sh"
check "R5 檢查器缺席：略過閘門（1 次呼叫、照收、無簡體 log）" "[[ \$(cat '$SB/s4.count') -eq 1 ]] && daily_cat s4 | grep -q '这个项目' && ! grep -q '簡體' '$SB/s4/mem/.logs/realtime-summary.log' 2>/dev/null"

echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"
rm -rf "$SB"
[[ $FAIL -eq 0 ]]
