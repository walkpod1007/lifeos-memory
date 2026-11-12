#!/usr/bin/env bash
# skill-vetting 掃描器行為測試
# 驗收重點：
#   1. 只含 MEDIUM 級樣式的樣本 → 退出碼 0
#   2. 含 CRITICAL 級樣式的樣本 → 退出碼 1
#   3. 含字母夾帶（triage / email / message / maintain）的樣本 → 不得出現社交工程那條 finding
# 結尾印 RESULT: PASS=x FAIL=y；FAIL>0 時本腳本退出碼非 0。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_PY="$SCRIPT_DIR/../skill-vetting/scripts/scan.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: 找不到 python3，無法執行掃描器"
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if [ ! -f "$SCAN_PY" ]; then
  echo "FAIL: 找不到掃描器 $SCAN_PY"
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/skill-vetting-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------- 樣本 1：只有 MEDIUM 級樣式 ----------
# MEDIUM 依 scan.py 樣式表挑：os.environ[（env variable access）、
# base64.b64decode（base64 decoding）、requests.get(（HTTP requests）
MED="$SANDBOX/sample-medium"
mkdir -p "$MED"
cat > "$MED/SKILL.md" <<'EOF'
# sample-medium

此樣本只包含 MEDIUM 級寫法，預期掃描器退出碼 0。

```python
import base64
import os
import requests

decoded = base64.b64decode("aGVsbG8=")
home = os.environ["HOME"]
resp = requests.get("https://example.com/api/status")
```
EOF

# ---------- 樣本 2：含 CRITICAL 級樣式 ----------
CRIT="$SANDBOX/sample-critical"
mkdir -p "$CRIT"
cat > "$CRIT/SKILL.md" <<'EOF'
# sample-critical

此樣本含 CRITICAL 級寫法，預期掃描器退出碼 1。

```python
import os

os.system("echo pwned")
```
EOF

# ---------- 樣本 3：字母夾帶，不該命中社交工程樣式 ----------
# triage / email / maintain / message 都含 "ai"，但 "ai" 前面是英文字母，
# 依 (?<![A-Za-z]) 前綴規則不該被視為「對 AI 審查者喊話」。
LET="$SANDBOX/sample-letters"
mkdir -p "$LET"
cat > "$LET/SKILL.md" <<'EOF'
# sample-letters

此樣本只有含 "ai" 字母夾帶的一般用詞，不該被判定為社交工程。

- triage incoming email messages each morning
- maintain a simple queue of follow-ups
- the message body and its detail lines stay plain
- the email instructions must stay short
- maintain should be a simple queue
EOF

run_scan() {
  # 用法：run_scan <dir> <rc 變數名> <輸出檔名>
  local dir="$1" rc_var="$2" out="$3"
  python3 "$SCAN_PY" "$dir" >"$out" 2>&1
  local rc=$?
  eval "$rc_var=$rc"
  return 0
}

# --- 斷言 1：MEDIUM 樣本 rc 0 ---
run_scan "$MED" MED_RC "$SANDBOX/medium.out"
if [ "$MED_RC" -eq 0 ]; then
  pass "MEDIUM 樣本退出碼為 0（實得 $MED_RC）"
else
  fail "MEDIUM 樣本退出碼應為 0，實得 $MED_RC"
  sed 's/^/    /' "$SANDBOX/medium.out"
fi

# MEDIUM 樣本仍應被掃描器看見（照印，只是回 0）
if grep -q "MEDIUM" "$SANDBOX/medium.out"; then
  pass "MEDIUM 樣本的 MEDIUM finding 仍印在報告裡"
else
  fail "MEDIUM 樣本的 MEDIUM finding 沒印在報告裡"
fi

# --- 斷言 2：CRITICAL 樣本 rc 1 ---
run_scan "$CRIT" CRIT_RC "$SANDBOX/critical.out"
if [ "$CRIT_RC" -eq 1 ]; then
  pass "CRITICAL 樣本退出碼為 1（實得 $CRIT_RC）"
else
  fail "CRITICAL 樣本退出碼應為 1，實得 $CRIT_RC"
  sed 's/^/    /' "$SANDBOX/critical.out"
fi

# --- 斷言 3：字母夾帶樣本不得出現社交工程 finding ---
run_scan "$LET" LET_RC "$SANDBOX/letters.out"
if grep -qi "social engineering" "$SANDBOX/letters.out"; then
  fail "字母夾帶樣本誤報社交工程 finding"
  sed 's/^/    /' "$SANDBOX/letters.out"
else
  pass "字母夾帶樣本沒有社交工程 finding"
fi

if [ "$LET_RC" -eq 0 ]; then
  pass "字母夾帶樣本退出碼為 0（實得 $LET_RC）"
else
  fail "字母夾帶樣本退出碼應為 0，實得 $LET_RC"
  sed 's/^/    /' "$SANDBOX/letters.out"
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
