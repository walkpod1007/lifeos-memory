#!/bin/bash
# line-health/check.sh — LINE 健檢 SOP v1
# 每段獨立執行，印 ✅/⚠️/❌ + 一行說明

set -uo pipefail

echo "=== LINE 健檢 v1 / $(date '+%Y-%m-%d %H:%M:%S') ==="
echo ""

# Step 1: tmux session 是否存在
echo "[1/9] tmux sessions"
EXPECTED_SESSIONS="claude-line claude-line-note claude-line-talk claude-line-ita claude-line-recipe claude-line-ptcg"
for s in $EXPECTED_SESSIONS; do
  if tmux has-session -t "$s" 2>/dev/null; then
    echo "  ✅ $s"
  else
    echo "  ❌ $s — 缺 tmux session（跑 supervisor script 重啟）"
  fi
done

# Step 2: 每個 session 底下有沒有 claude binary 跑
echo ""
echo "[2/9] claude binaries"

# 遞迴抓某 PID 的所有 descendants（避免只挖兩層而漏掉深巢狀的 supervisor → claude）
get_descendants() {
  local parent=$1
  local kids
  kids=$(pgrep -P "$parent" 2>/dev/null) || return 0
  for k in $kids; do
    echo "$k"
    get_descendants "$k"
  done
}

for s in $EXPECTED_SESSIONS; do
  pane_pid=$(tmux list-panes -t "$s" -F "#{pane_pid}" 2>/dev/null | head -1)
  if [ -z "$pane_pid" ]; then
    echo "  ⏭️  $s — session 不存在跳過"
    continue
  fi
  has_claude=0
  # pane_pid 本身可能就是 claude（若 supervisor 直接 exec claude），所以把 pane_pid 也納入檢查
  for c in $pane_pid $(get_descendants "$pane_pid"); do
    # 接受 "claude ..."、"/path/to/claude"、"claude" 無參數三種情境
    if ps -p "$c" -o command= 2>/dev/null | grep -qE "(^|/)claude([[:space:]]|$)"; then
      has_claude=1
      break
    fi
  done
  if [ "$has_claude" = "1" ]; then
    echo "  ✅ $s"
  else
    echo "  ⚠️  $s — 沒 claude binary（supervisor 可能死了）"
  fi
done

# Step 3: claude session pane 是否 ready（看到 ❯ cursor 或 claude UI）
echo ""
echo "[3/9] claude session pane 狀態"
for s in $EXPECTED_SESSIONS; do
  if ! tmux has-session -t "$s" 2>/dev/null; then continue; fi
  # 抓全 pane（-S - 從 scrollback 起點）而不是只看尾部——claude UI 的 prompt（❯）
  # 在「---」分隔線和 footer 之間，tail 視窗太小會落在 footer 而看不到 prompt
  last=$(tmux capture-pane -t "$s" -p -S - 2>/dev/null)
  if echo "$last" | grep -q "❯"; then
    echo "  ✅ $s — 有 prompt"
  elif echo "$last" | grep -qE "No such file|error|Error"; then
    echo "  ⚠️  $s — pane 有錯誤訊息（看 tmux capture-pane）"
  else
    echo "  ⚠️  $s — pane 無 prompt（可能還在 boot 或 hang）"
  fi
done

# Step 4: line-lobster webhook process + port 3001
echo ""
echo "[4/9] line-lobster webhook (port 3001)"
# lsof 在 macOS 常在 /usr/sbin（不在 brew PATH），先 fallback 找；都找不到改用 /health curl
LSOF_BIN=$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)
if pgrep -f "line-lobster/webhook.ts" >/dev/null; then
  if [ -x "$LSOF_BIN" ] && "$LSOF_BIN" -iTCP:3001 -sTCP:LISTEN -P 2>/dev/null | grep -q LISTEN; then
    echo "  ✅ webhook.ts running, port 3001 listening"
  elif curl -sS -o /dev/null -m 3 http://localhost:3001/health 2>/dev/null; then
    echo "  ✅ webhook.ts running, /health 回應正常（lsof 不可用，改用 curl 判斷）"
  else
    echo "  ❌ webhook.ts running BUT port 3001 not listening"
  fi
else
  echo "  ❌ webhook.ts not running — 要重啟 line-lobster"
fi

# Step 5: cloudflared process + connector 創建時間
echo ""
echo "[5/9] cloudflared tunnel"
if pgrep -f "cloudflared.*tunnel" >/dev/null; then
  echo "  ✅ cloudflared process up"
  if command -v cloudflared >/dev/null 2>&1; then
    # 抓 connector created time（如果近 10 分鐘內，可能是剛重連的訊號）
    if info=$(cloudflared tunnel info e4c124fc-a28f-49c9-be15-56d2e49e9cce 2>/dev/null | grep -E '^[0-9a-f]{8}' | tail -1) && [ -n "$info" ]; then
      echo "$info" | sed 's/^/      /'
      # 解析 CREATED 欄位（col 2，ISO 8601 UTC），計算 connector 存在多久
      created=$(echo "$info" | awk '{print $2}' | tr -d '[:space:]')
      if [ -n "$created" ]; then
        if ! command -v python3 >/dev/null 2>&1; then
          echo "  ⚠️  python3 不存在，無法計算 connector age"
        else
          age_min=$(python3 -c "
import sys
from datetime import datetime, timezone
try:
    t = datetime.strptime('$created', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - t).total_seconds() / 60
    print(int(age))
except Exception:
    print(-1)
" 2>/dev/null)
          if [[ "$age_min" =~ ^-?[0-9]+$ ]] && [ "$age_min" -ge 0 ] && [ "$age_min" -lt 60 ]; then
            echo "      ⚠️  connector 在 $age_min 分鐘前才建立——近期可能有斷線重連"
          elif [[ "$age_min" =~ ^-?[0-9]+$ ]] && [ "$age_min" -ge 60 ]; then
            echo "      ✅ connector 已穩定 $age_min 分鐘"
          else
            echo "      ⚠️  connector CREATED 時間解析失敗（created=$created）"
          fi
        fi
      else
        echo "      ⚠️  connector 列缺少 CREATED 欄位，無法計算 age"
      fi
    else
      echo "  ⚠️  cloudflared CLI 取不到 tunnel info（認證失效或 tunnel UUID 不對）"
    fi
  else
    echo "  ⚠️  cloudflared CLI 不在 PATH（process up 但無法查 connector 細節）"
  fi
else
  echo "  ❌ cloudflared down — sudo launchctl kickstart -k system/com.cloudflare.cloudflared"
fi

# Step 6: 公開 webhook URL 可達性（用 HEAD 探測，POST-only endpoint 預期回 405）
echo ""
echo "[6/9] webhook 公開 URL（HEAD 對 POST-only endpoint。code：405=路由+後端都通、530=tunnel 斷、502/503=後端壞）"
for host in <YOUR_DOMAIN> <YOUR_DOMAIN>; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -m 5 -I "https://$host/line/webhook" 2>/dev/null)
  case "$code" in
    405) echo "  ✅ $host → $code (HEAD 被拒 = endpoint 通到後端)" ;;
    530) echo "  ❌ $host → $code (Cloudflare error 1033 — tunnel 沒設 hostname routing 或 connector 斷)" ;;
    502|503) echo "  ❌ $host → $code (ingress 過了但後端死)" ;;
    000) echo "  ❌ $host → 連不上（DNS / 網路 / timeout）" ;;
    *) echo "  ⚠️  $host → $code（非預期）" ;;
  esac
done

# Step 7: queue 狀態
echo ""
echo "[7/9] queue 狀態（pending=0 表示已被 claude 讀完，>0 表示有訊息卡住）"
health=$(curl -sS http://localhost:3001/health 2>/dev/null)
if [ -n "$health" ]; then
  echo "$health" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k, v in data.get('pending', {}).items():
    name = k.split('/')[-1]
    flag = '✅' if v == 0 else '⚠️ '
    print(f'  {flag} {name}: {v}')
" 2>/dev/null || echo "  ⚠️  health endpoint 回應但解析失敗"
else
  echo "  ❌ /health 不回（webhook server 死或 port 不通）"
fi

# Step 8: invalid signature 計數（過去 1 小時 vs 全部）
echo ""
echo "[8/9] webhook log 異常"
LOG=/tmp/line-lobster.log
if [ -f "$LOG" ]; then
  # grep -c 在 pipefail 下無 match 會 exit 1，用 || true 保 expr 成立，再用 :- 補預設
  total=$(grep -c "invalid signature" "$LOG" 2>/dev/null || true)
  recent=$(tail -200 "$LOG" 2>/dev/null | grep -c "invalid signature" || true)
  cooldown=$(tail -200 "$LOG" 2>/dev/null | grep -c "notify skipped" || true)
  echo "  invalid signature: 全部 ${total:-0} / 末 200 行 ${recent:-0}"
  echo "  notify skipped (cooldown): 末 200 行 ${cooldown:-0}"
  echo "  最後 5 條訊息流向："
  grep -E "queued →|invalid signature" "$LOG" 2>/dev/null | tail -5 | sed 's/^/      /' || true
else
  echo "  ⚠️  $LOG 不存在"
fi

# Step 9: runtime 目錄結構（不再算 queue 檔——那是 step 7 的事）
echo ""
echo "[9/9] runtime 目錄結構"
RUNTIME=$HOME/.claude/channels/line/runtime
if [ -d "$RUNTIME" ]; then
  echo "  ✅ $RUNTIME 存在"
  if [ -w "$RUNTIME" ]; then
    echo "  ✅ runtime 可寫"
  else
    echo "  ❌ runtime 不可寫（webhook 寫不進 queue 檔 / cooldown 檔）"
  fi
  if [ -d "$RUNTIME/media" ]; then
    echo "  ✅ media/ 子目錄存在"
    if [ -w "$RUNTIME/media" ]; then
      echo "  ✅ media/ 可寫"
    else
      echo "  ❌ media/ 不可寫（收圖會失敗）"
    fi
  else
    echo "  ⚠️  media/ 子目錄不存在（首次收圖會自動建，但缺它代表還沒收過圖）"
  fi
else
  echo "  ❌ $RUNTIME 不存在（supervisor 啟動會報錯，跑 mkdir -p 補）"
fi

echo ""
echo "=== 健檢完成 ==="
echo ""
echo "解讀指南："
echo "  全 ✅ → LINE 系統正常，問題可能在 LINE 平台或 channel secret"
echo "  Step 5/6 ❌ → cloudflared 斷線或 hostname routing 沒設"
echo "  Step 4 ❌ → line-lobster webhook 死，重啟 webhook.ts"
echo "  Step 1/2 ❌ → channel session 死，跑 safe-restart"
echo "  Step 8 invalid signature 暴增 → LINE 平台 retry 或 channel secret 錯"
