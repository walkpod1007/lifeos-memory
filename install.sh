#!/usr/bin/env bash
# install.sh — lifeos-memory 一鍵安裝
#
# 用法：
#   ./install.sh              # 互動安裝（只問一題：記憶目錄放哪）
#   ./install.sh --yes        # 全用預設值，不問
#   ./install.sh --uninstall  # 卸載排程與 claw 指令（記憶資料不動）
#
# 做五件事：
#   1. 依賴檢查：claude CLI / python3 / timeout（macOS 要 coreutils）/ 可選 qmd
#   2. 建記憶目錄結構（~/lifeos-memory：cards/ daily/ state/ handoff/ + MEMORY.md）
#   3. 掛排程：realtime-summary 每 10 分鐘跑一次（macOS 用 launchd、Linux 用 cron）
#   4. 裝 claw 指令
#   5. 寫 CLAUDE.md 開機區塊（BEGIN/END 標記、先備份、卸載整塊移除）＋ 冒煙測試
#
# 測試/進階用環境變數（一般使用者不用理）：
#   LIFEOS_MEMORY_ROOT       記憶根目錄（跳過互動提問）
#   LIFEOS_LAUNCHD_DIR       plist 安裝目錄，預設 ~/Library/LaunchAgents
#   LIFEOS_BIN_DIR           claw 指令安裝目錄，預設 ~/.local/bin
#   LIFEOS_CLAUDE_MD         開機區塊寫入的檔案，預設 ~/.claude/CLAUDE.md
#   LIFEOS_SKIP_CLAUDEMD=1   不寫開機區塊（改手動接線，見 README）
#   LIFEOS_SKIP_ACTIVATE=1   只落檔不啟動排程（sandbox 測試用）
#   LIFEOS_SKIP_CLAUDE_CHECK=1  跳過 claude 登入冒煙測試
#   LIFEOS_FORCE_OS          強制 OS 分支（Darwin|Linux，測試用）

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$ROOT/memory-harness/scripts"
TEMPLATE="$ROOT/memory-harness/templates/com.lifeos-memory.realtime-summary.plist"
LABEL="com.lifeos-memory.realtime-summary"
CRON_TAG="# lifeos-memory"

OS="${LIFEOS_FORCE_OS:-$(uname -s)}"
LAUNCHD_DIR="${LIFEOS_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
BIN_DIR="${LIFEOS_BIN_DIR:-$HOME/.local/bin}"
PLIST_DST="$LAUNCHD_DIR/$LABEL.plist"
CLAUDE_MD="${LIFEOS_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
BLOCK_BEGIN="<!-- BEGIN lifeos-memory -->"
BLOCK_END="<!-- END lifeos-memory -->"

YES=0; UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)     YES=1;;
        --uninstall)  UNINSTALL=1;;
        *) echo "未知參數：${arg}（可用 --yes / --uninstall）"; exit 1;;
    esac
done

say()  { echo "▸ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
die()  { echo "  ❌ $*"; exit 1; }

# ─────────────────────────── 卸載 ───────────────────────────
if [[ "$UNINSTALL" == "1" ]]; then
    say "卸載 lifeos-memory 排程與指令（記憶資料不會動）"
    if [[ "$OS" == "Darwin" ]]; then
        if [[ -z "${LIFEOS_SKIP_ACTIVATE:-}" ]]; then
            launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
                || launchctl remove "$LABEL" 2>/dev/null || true
        fi
        [[ -f "$PLIST_DST" ]] && rm -f "$PLIST_DST" && ok "已移除 $PLIST_DST"
    else
        if command -v crontab >/dev/null 2>&1; then
            # 只刪「行尾恰為 tag」的行——grep -vF 會誤刪使用者自己含該字串的排程
            _cron=$(crontab -l 2>/dev/null | awk -v tag="$CRON_TAG" 'substr($0, length($0)-length(tag)+1) != tag' || true)
            printf '%s\n' "$_cron" | crontab - 2>/dev/null || true
            ok "已移除 crontab 裡的 lifeos-memory 排程"
        fi
    fi
    # 只刪本包產生的 wrapper（認檔內識別標記）——同名檔可能是使用者自己的東西
    if [[ -L "$BIN_DIR/claw" ]]; then
        warn "$BIN_DIR/claw 是 symlink，非本包產生（本包裝的是一般檔），保留不動"
    elif [[ -f "$BIN_DIR/claw" ]]; then
        if grep -qF "lifeos-memory 產生的 wrapper" "$BIN_DIR/claw" 2>/dev/null; then
            rm -f "$BIN_DIR/claw" && ok "已移除 $BIN_DIR/claw"
        else
            warn "$BIN_DIR/claw 缺本包識別標記，可能是你自己的檔案，保留不動"
        fi
    fi
    if [[ -f "$CLAUDE_MD" ]] && grep -qF "$BLOCK_BEGIN" "$CLAUDE_MD"; then
        _bak="$CLAUDE_MD.bak-lifeos-uninstall.$(date +%Y%m%d%H%M%S)"
        cp "$CLAUDE_MD" "$_bak" \
            || { warn "備份失敗，保守起見不動 ${CLAUDE_MD}（自己刪 BEGIN/END lifeos-memory 區塊）"; exit 0; }
        python3 - "$CLAUDE_MD" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as f:
    text = f.read()
new = re.sub(
    r"\n?<!-- BEGIN lifeos-memory -->.*?<!-- END lifeos-memory -->\n?",
    "\n", text, flags=re.S,
)
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PYEOF
        if grep -qF "$BLOCK_BEGIN" "$CLAUDE_MD"; then
            warn "區塊移除失敗——$CLAUDE_MD 請手動刪 BEGIN/END lifeos-memory 區塊（備份在 ${_bak}）"
        else
            ok "CLAUDE.md 開機區塊已移除（備份：${_bak}）"
        fi
    fi
    say "完成。記憶目錄（daily/handoff/cards）原封不動，要清自己刪。"
    exit 0
fi

# ─────────────────────── 1. 依賴檢查 ───────────────────────
say "檢查依賴"

command -v python3 >/dev/null 2>&1 && ok "python3" \
    || die "缺 python3（macOS: xcode-select --install；Linux: apt install python3）"

if command -v claude >/dev/null 2>&1; then
    ok "claude CLI"
else
    die "缺 claude CLI——先裝 Claude Code：https://claude.com/claude-code（npm i -g @anthropic-ai/claude-code）"
fi

TIMEOUT_BIN=""
for _tb in timeout gtimeout /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
    command -v "$_tb" >/dev/null 2>&1 && TIMEOUT_BIN="$_tb" && break
done
if [[ -n "$TIMEOUT_BIN" ]]; then
    ok "timeout（${TIMEOUT_BIN}）"
else
    if [[ "$OS" == "Darwin" ]]; then
        die "缺 timeout——跑：brew install coreutils"
    else
        die "缺 timeout（coreutils）——用套件管理器裝 coreutils"
    fi
fi

HAS_QMD=0
if command -v qmd >/dev/null 2>&1; then
    HAS_QMD=1
    ok "qmd（向量回搜已就緒）"
else
    warn "沒裝 qmd——記憶照常寫入，只是回搜用 grep。要語意搜尋：npm i -g @tobilu/qmd"
fi

# ─────────────────── 2. 記憶目錄 ───────────────────
DEFAULT_ROOT="${LIFEOS_MEMORY_ROOT:-$HOME/lifeos-memory}"
MEMORY_ROOT="$DEFAULT_ROOT"
if [[ "$YES" != "1" && -z "${LIFEOS_MEMORY_ROOT:-}" && -t 0 ]]; then
    printf '記憶目錄放哪？[預設 %s] ' "$DEFAULT_ROOT"
    read -r _ans || _ans=""
    [[ -n "$_ans" ]] && MEMORY_ROOT="${_ans/#\~/$HOME}"
fi

# 排程行會把路徑放進 crontab（由 /bin/sh 解析），單引號/換行無法安全引用——直接拒絕
case "$MEMORY_ROOT$ROOT" in
    *"'"*) die "路徑含單引號（'），排程無法安全掛載——換個路徑";;
esac
if [[ "$MEMORY_ROOT$ROOT" == *$'\n'* ]]; then
    die "路徑含換行，排程無法安全掛載——換個路徑"
fi

say "建立記憶目錄：$MEMORY_ROOT"
mkdir -p "$MEMORY_ROOT/cards/pitfall" "$MEMORY_ROOT/daily" "$MEMORY_ROOT/state" \
         "$MEMORY_ROOT/handoff" "$MEMORY_ROOT/.logs" "$MEMORY_ROOT/.checkpoints" \
    || die "建不了 $MEMORY_ROOT"
if [[ ! -f "$MEMORY_ROOT/MEMORY.md" ]]; then
    cat > "$MEMORY_ROOT/MEMORY.md" <<'EOF'
# MEMORY.md — 記憶卡索引（session 開場讀這份）

一卡一行，格式：`- [卡片標題](cards/xxx.md) — 一句鉤子`。
內文永遠放卡片檔，這裡只放索引。

EOF
    ok "MEMORY.md 索引已建立"
else
    ok "MEMORY.md 已存在，不動"
fi

# ─────────────────── 3. 掛排程 ───────────────────
SUMMARY_SH="$SCRIPTS/realtime-summary.sh"
chmod +x "$SCRIPTS"/*.sh "$SCRIPTS/claw" 2>/dev/null || true

if [[ "$OS" == "Darwin" ]]; then
    say "掛 launchd 排程（每 10 分鐘摘要一次）"
    mkdir -p "$LAUNCHD_DIR"
    python3 - "$TEMPLATE" "$PLIST_DST" "$SUMMARY_SH" "$MEMORY_ROOT" <<'PYEOF'
import plistlib, sys
tpl, dst, script, memroot = sys.argv[1:5]
with open(tpl, 'rb') as f:
    p = plistlib.load(f)
p['ProgramArguments'] = ['/bin/bash', script]
env = p.get('EnvironmentVariables', {})
env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
env['LIFEOS_MEMORY_ROOT'] = memroot
p['EnvironmentVariables'] = env
# log 進使用者自己的記憶目錄——固定 /tmp 檔名可被同機他人預放 symlink
p['StandardOutPath'] = memroot + '/.logs/realtime-summary.out'
p['StandardErrorPath'] = memroot + '/.logs/realtime-summary.err'
with open(dst, 'wb') as f:
    plistlib.dump(p, f)
PYEOF
    [[ -f "$PLIST_DST" ]] || die "plist 產出失敗"
    ok "plist 已落檔：$PLIST_DST"
    if [[ -z "${LIFEOS_SKIP_ACTIVATE:-}" ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null \
           || launchctl load -w "$PLIST_DST" 2>/dev/null; then
            ok "launchd 已啟動"
        else
            warn "launchctl 啟動失敗——手動跑：launchctl bootstrap gui/\$(id -u) $PLIST_DST"
        fi
    else
        warn "LIFEOS_SKIP_ACTIVATE=1：只落檔，未啟動排程"
    fi
else
    say "掛 cron 排程（每 10 分鐘摘要一次）"
    command -v crontab >/dev/null 2>&1 || die "缺 crontab——裝 cron 或改用 systemd timer 手動掛"
    # 路徑一律單引號（上面已擋含單引號/換行的路徑）；log 進記憶目錄，不用可預測的 /tmp 檔名
    CRON_LINE="*/10 * * * * LIFEOS_MEMORY_ROOT='$MEMORY_ROOT' /bin/bash '$SUMMARY_SH' >>'$MEMORY_ROOT/.logs/cron.log' 2>&1 $CRON_TAG"
    _cron=$(crontab -l 2>/dev/null | awk -v tag="$CRON_TAG" 'substr($0, length($0)-length(tag)+1) != tag' || true)
    if [[ -n "$_cron" ]]; then
        printf '%s\n%s\n' "$_cron" "$CRON_LINE" | crontab - || die "crontab 寫入失敗"
    else
        printf '%s\n' "$CRON_LINE" | crontab - || die "crontab 寫入失敗"
    fi
    ok "cron 已掛：$(crontab -l | grep -cF "$CRON_TAG") 條"
    warn "WSL 使用者注意：確認 cron 服務有在跑（service cron status）"
fi

# ─────────────────── 4. 裝 claw 指令 ───────────────────
say "安裝 claw 指令 → $BIN_DIR/claw"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/claw" <<EOF
#!/usr/bin/env bash
# lifeos-memory 產生的 wrapper（./install.sh 重跑會更新）
export LIFEOS_MEMORY_ROOT="\${LIFEOS_MEMORY_ROOT:-$MEMORY_ROOT}"
exec bash "$SCRIPTS/claw" "\$@"
EOF
chmod +x "$BIN_DIR/claw"
ok "claw 已安裝"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR 不在 PATH——在 shell rc 加：export PATH=\"$BIN_DIR:\$PATH\"";;
esac

# ─────────────────── 5. CLAUDE.md 開機區塊 ───────────────────
# 制度是行為不是檔案：沒有這塊，Claude 不會主動讀記憶（索引載入靠這裡的 @include）
INSTALL_BLOCK=1
[[ -n "${LIFEOS_SKIP_CLAUDEMD:-}" ]] && INSTALL_BLOCK=0
if [[ "$INSTALL_BLOCK" == "1" && "$YES" != "1" && -t 0 ]]; then
    printf '把開機指令區塊寫進 %s？沒有它 Claude 不會主動用記憶 [Y/n] ' "$CLAUDE_MD"
    read -r _ans || _ans=""
    case "$_ans" in [Nn]*) INSTALL_BLOCK=0;; esac
fi

if [[ "$INSTALL_BLOCK" == "1" ]]; then
    say "寫入 CLAUDE.md 開機區塊：$CLAUDE_MD"
    if [[ -f "$CLAUDE_MD" ]] && grep -qF "$BLOCK_BEGIN" "$CLAUDE_MD"; then
        ok "區塊已存在，不重複寫（要更新先 --uninstall 再裝）"
    else
        mkdir -p "$(dirname "$CLAUDE_MD")" || die "建不了 $(dirname "$CLAUDE_MD")"
        if [[ -f "$CLAUDE_MD" ]]; then
            _bak="$CLAUDE_MD.bak-lifeos-install.$(date +%Y%m%d%H%M%S)"
            cp "$CLAUDE_MD" "$_bak" || die "備份失敗，不動 $CLAUDE_MD"
            ok "原檔已備份：$_bak"
        fi
        cat >> "$CLAUDE_MD" <<EOF

$BLOCK_BEGIN
## Life-OS Memory（lifeos-memory 安裝區塊；./install.sh --uninstall 會整塊移除）
@$MEMORY_ROOT/MEMORY.md
- 上一行已自動載入記憶卡索引；接續舊工作先看 $MEMORY_ROOT/handoff/ 對應專案的交接檔
- 遇錯或似曾相識的問題：先搜 $MEMORY_ROOT/cards/pitfall/ 的坑卡再動手
- 一卡一事實：值得跨 session 記住的事實寫獨立卡片檔進 $MEMORY_ROOT/cards/，並在 MEMORY.md 加一行索引；使用者的糾正與偏好也要記卡（附 Why＋How to apply）
- Session 收尾或被要求交接：以 SUMMARY／CURRENT／NEXT／LESSON 四節覆寫 $MEMORY_ROOT/handoff/ 的專案交接檔
$BLOCK_END
EOF
        ok "區塊已寫入（BEGIN/END 標記，卸載可乾淨移除）"
    fi
else
    warn "跳過 CLAUDE.md 區塊——記得手動在 CLAUDE.md 加：@$MEMORY_ROOT/MEMORY.md，否則 Claude 不會主動用記憶"
fi

# ─────────────────── 6. 冒煙測試 ───────────────────
say "冒煙測試"

for _s in "$SCRIPTS/realtime-summary.sh" "$SCRIPTS/gen-handoff.sh" "$SCRIPTS/watchdog.sh" "$SCRIPTS/claw"; do
    bash -n "$_s" || die "語法錯誤：$_s"
done
ok "四支腳本語法全過"

if [[ -z "${LIFEOS_SKIP_CLAUDE_CHECK:-}" ]]; then
    _out=$("$TIMEOUT_BIN" 60 claude -p "只回兩個字母：OK" --model haiku 2>/dev/null || echo "")
    if [[ -n "$_out" ]]; then
        ok "claude CLI 可呼叫（登入態正常）"
    else
        warn "claude -p 沒回應——可能沒登入，先跑一次 claude 完成登入，摘要層才動得起來"
    fi
fi

if [[ "$HAS_QMD" == "1" ]]; then
    # qmd 語法：路徑在前、--name 給名字（name 在前會被當相對路徑吃掉，指到 cwd）
    if qmd collection add "$MEMORY_ROOT" --name memory 2>/dev/null; then
        ok "qmd collection「memory」已建立"
    else
        warn "qmd collection 建立失敗或已存在——手動確認：qmd collection add $MEMORY_ROOT --name memory"
    fi
fi

# ─────────────────── 完成 ───────────────────
echo
say "安裝完成 🎉 之後這樣用："
cat <<EOF

  1. 到任何專案目錄，用  claw  代替  claude  開工作 session
     （token 撞 150000 門檻會自動：寫 handoff → 斷頭 → 重生新 session 接續工作）
  2. 每 10 分鐘，對話自動摘要進  $MEMORY_ROOT/daily/
  3. 記憶開機接線：安裝時已寫進 CLAUDE.md 開機區塊（若剛才選了跳過，
     手動在 CLAUDE.md 加一行  @$MEMORY_ROOT/MEMORY.md）
  4. 記憶卡寫法（讓 Claude 記事實、記踩過的坑）見 memory-cards/SKILL.md

  卸載：./install.sh --uninstall（記憶資料不會被刪）
EOF
