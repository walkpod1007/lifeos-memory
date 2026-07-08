#!/usr/bin/env bash
# install.sh sandbox 測試：假 qmd/crontab 進 PATH、launchd 目錄改道、不啟動排程
# 驗證：macOS 分支（plist 渲染）、Linux 分支（cron 冪等）、claw wrapper 產出、卸載、資料保留
set -u

SB="$(cd "$(dirname "$0")" && pwd)/sandbox"
PACK="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/launchd" "$SB/insbin" "$SB/pack"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# 隔離拷貝（列舉必要項——sandbox 就在 pack 裡，整包 cp -R 會自我遞迴）
cp -R "$PACK/install.sh" "$PACK/memory-harness" "$PACK/memory-cards" "$SB/pack/"

# 假 qmd：記呼叫參數
cat > "$SB/bin/qmd" <<EOF
#!/usr/bin/env bash
echo "QMD:\$*" >> "$SB/qmd.calls"
exit 0
EOF
# 假 crontab：狀態存檔案（-l 印出、- 存 stdin）
cat > "$SB/bin/crontab" <<EOF
#!/usr/bin/env bash
STATE="$SB/crontab.state"
case "\${1:-}" in
    -l) [[ -f "\$STATE" ]] && cat "\$STATE" || exit 1;;
    -)  cat > "\$STATE";;
    *)  exit 1;;
esac
EOF
chmod +x "$SB/bin/"*

MEM="$SB/memroot"
CMD="$SB/claude-md/CLAUDE.md"
COMMON=(env PATH="$SB/bin:$PATH" LIFEOS_MEMORY_ROOT="$MEM"
        LIFEOS_LAUNCHD_DIR="$SB/launchd" LIFEOS_BIN_DIR="$SB/insbin"
        LIFEOS_CLAUDE_MD="$CMD"
        LIFEOS_SKIP_ACTIVATE=1 LIFEOS_SKIP_CLAUDE_CHECK=1)

echo "— I1 macOS 分支安裝 —"
"${COMMON[@]}" LIFEOS_FORCE_OS=Darwin bash "$SB/pack/install.sh" --yes > "$SB/i1.out" 2>&1
RC=$?
check "退出碼 0" "[[ $RC -eq 0 ]]"
check "輸出無 ❌" "! grep -q '❌' '$SB/i1.out'"
check "記憶目錄結構齊全" "[[ -d '$MEM/cards/pitfall' && -d '$MEM/daily' && -d '$MEM/state' && -d '$MEM/handoff' ]]"
check "MEMORY.md 已建" "grep -q '記憶卡索引' '$MEM/MEMORY.md'"
PLIST="$SB/launchd/com.lifeos-memory.realtime-summary.plist"
check "plist 已落檔" "[[ -f '$PLIST' ]]"
check "plist 指向 realtime-summary.sh 絕對路徑" "python3 -c \"import plistlib;p=plistlib.load(open('$PLIST','rb'));exit(0 if p['ProgramArguments'][1]=='$SB/pack/memory-harness/scripts/realtime-summary.sh' else 1)\""
check "plist 帶 LIFEOS_MEMORY_ROOT" "python3 -c \"import plistlib;p=plistlib.load(open('$PLIST','rb'));exit(0 if p['EnvironmentVariables'].get('LIFEOS_MEMORY_ROOT')=='$MEM' else 1)\""
check "無 __SCRIPT_PATH__ 殘留" "! grep -q '__SCRIPT_PATH__' '$PLIST'"
check "claw wrapper 已裝且可執行" "[[ -x '$SB/insbin/claw' ]]"
check "wrapper 匯出記憶目錄並 exec 真 claw" "grep -q 'LIFEOS_MEMORY_ROOT' '$SB/insbin/claw' && grep -q 'scripts/claw' '$SB/insbin/claw'"
check "qmd collection 有接線（路徑在前 --name 在後）" "grep -q 'QMD:collection add $MEM --name memory' '$SB/qmd.calls'"
check "CLAUDE.md 區塊已寫（含 BEGIN/END）" "grep -qF '<!-- BEGIN lifeos-memory -->' '$CMD' && grep -qF '<!-- END lifeos-memory -->' '$CMD'"
check "區塊含 @MEMORY.md 自動載入" "grep -qF \"@$MEM/MEMORY.md\" '$CMD'"

echo "— I2 macOS 卸載（資料保留） —"
echo "- [測試卡](cards/x.md) — 假資料" >> "$MEM/MEMORY.md"
"${COMMON[@]}" LIFEOS_FORCE_OS=Darwin bash "$SB/pack/install.sh" --uninstall > "$SB/i2.out" 2>&1
check "卸載退出碼 0" "[[ $? -eq 0 ]]"
check "plist 已移除" "[[ ! -f '$PLIST' ]]"
check "claw 指令已移除" "[[ ! -e '$SB/insbin/claw' ]]"
check "記憶資料原封不動" "grep -q '測試卡' '$MEM/MEMORY.md'"
check "CLAUDE.md 區塊已移除" "! grep -qF 'BEGIN lifeos-memory' '$CMD'"

echo "— I3 Linux 分支：cron 掛載＋冪等 —"
rm -rf "$MEM"; rm -f "$SB/crontab.state"
echo "0 9 * * * /usr/bin/existing-job" > "$SB/crontab.state"   # 既有排程不能被吃掉
"${COMMON[@]}" LIFEOS_FORCE_OS=Linux bash "$SB/pack/install.sh" --yes > "$SB/i3.out" 2>&1
RC=$?
check "Linux 安裝退出碼 0" "[[ $RC -eq 0 ]]"
check "cron 行已掛" "grep -q 'realtime-summary.sh' '$SB/crontab.state'"
check "既有排程未被吃掉" "grep -q 'existing-job' '$SB/crontab.state'"
check "cron 行帶記憶目錄（單引號包住）" "grep -qF \"LIFEOS_MEMORY_ROOT='$MEM'\" '$SB/crontab.state'"
"${COMMON[@]}" LIFEOS_FORCE_OS=Linux bash "$SB/pack/install.sh" --yes > "$SB/i3b.out" 2>&1
check "重跑冪等（僅 1 條）" "[[ \$(grep -c 'lifeos-memory' '$SB/crontab.state') -eq 1 ]]"

echo "— I4 Linux 卸載 —"
"${COMMON[@]}" LIFEOS_FORCE_OS=Linux bash "$SB/pack/install.sh" --uninstall > "$SB/i4.out" 2>&1
check "cron 行已移除" "! grep -q 'lifeos-memory' '$SB/crontab.state'"
check "既有排程仍在" "grep -q 'existing-job' '$SB/crontab.state'"

echo "— I5 紅隊回歸：空白路徑／誤刪防護 —"
# 5a. 記憶目錄含空白：安裝要成功且 cron 行整段被單引號包住
MEM2="$SB/mem root"
rm -f "$SB/crontab.state"
env PATH="$SB/bin:$PATH" LIFEOS_MEMORY_ROOT="$MEM2" LIFEOS_LAUNCHD_DIR="$SB/launchd" \
    LIFEOS_BIN_DIR="$SB/insbin" LIFEOS_CLAUDE_MD="$CMD" LIFEOS_SKIP_ACTIVATE=1 \
    LIFEOS_SKIP_CLAUDE_CHECK=1 LIFEOS_FORCE_OS=Linux \
    bash "$SB/pack/install.sh" --yes > "$SB/i5a.out" 2>&1
check "空白路徑安裝退出碼 0" "[[ $? -eq 0 ]]"
check "空白路徑 cron 行有單引號包住" "grep -qF \"LIFEOS_MEMORY_ROOT='$MEM2'\" '$SB/crontab.state'"
# 5b. 單引號路徑要被拒絕（fail-closed，不寫壞 crontab）
env PATH="$SB/bin:$PATH" LIFEOS_MEMORY_ROOT="$SB/o'brien" LIFEOS_LAUNCHD_DIR="$SB/launchd" \
    LIFEOS_BIN_DIR="$SB/insbin" LIFEOS_CLAUDE_MD="$CMD" LIFEOS_SKIP_ACTIVATE=1 \
    LIFEOS_SKIP_CLAUDE_CHECK=1 LIFEOS_FORCE_OS=Linux \
    bash "$SB/pack/install.sh" --yes > "$SB/i5b.out" 2>&1
check "單引號路徑被拒絕（非 0 退出）" "[[ $? -ne 0 ]]"
check "拒絕訊息有講原因" "grep -q '單引號' '$SB/i5b.out'"
# 5c. 卸載不誤刪：使用者自己含 tag 字串（但非行尾）的 cron 行、無標記的同名 claw 檔都要留下
echo "0 9 * * * /usr/local/bin/backup # lifeos-memory notes" >> "$SB/crontab.state"
printf '#!/bin/sh\necho my own claw\n' > "$SB/insbin/claw"; chmod +x "$SB/insbin/claw"
env PATH="$SB/bin:$PATH" LIFEOS_MEMORY_ROOT="$MEM2" LIFEOS_LAUNCHD_DIR="$SB/launchd" \
    LIFEOS_BIN_DIR="$SB/insbin" LIFEOS_CLAUDE_MD="$CMD" LIFEOS_SKIP_ACTIVATE=1 \
    LIFEOS_SKIP_CLAUDE_CHECK=1 LIFEOS_FORCE_OS=Linux \
    bash "$SB/pack/install.sh" --uninstall > "$SB/i5c.out" 2>&1
check "本包 cron 行已移除" "! grep -q 'realtime-summary.sh' '$SB/crontab.state'"
check "使用者含 tag 字串的行仍在" "grep -q 'lifeos-memory notes' '$SB/crontab.state'"
check "無標記的同名 claw 檔被保留" "grep -q 'my own claw' '$SB/insbin/claw'"
# 5d. CLAUDE.md 備份帶時間戳（不覆蓋舊備份）
check "install 備份帶時間戳" "ls \"$CMD\".bak-lifeos-install.2* >/dev/null 2>&1"

echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
