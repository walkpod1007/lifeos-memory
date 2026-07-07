#!/usr/bin/env bash
# fix-tunnel.sh — 診斷並修復 cloudflared LaunchAgent
# 用法: bash fix-tunnel.sh [--check-only]

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
CHECK_ONLY="${1:-}"

echo "=== cloudflared tunnel health check ==="

# 1. 確認 cloudflared 已安裝
if ! command -v cloudflared &>/dev/null; then
  echo "❌ cloudflared 未安裝。安裝方式: brew install cloudflare/cloudflare/cloudflared"
  exit 1
fi
echo "✅ cloudflared: $(cloudflared --version 2>&1 | head -1)"

# 2. 確認 ~/.cloudflared/config.yml 存在
if [[ ! -f "$HOME/.cloudflared/config.yml" ]]; then
  echo "❌ ~/.cloudflared/config.yml 不存在，需先設定 tunnel"
  exit 1
fi

TUNNEL_ID=$(grep '^tunnel:' "$HOME/.cloudflared/config.yml" | awk '{print $2}')
echo "✅ Tunnel ID: $TUNNEL_ID"

# 3. 確認 plist 存在
if [[ ! -f "$PLIST" ]]; then
  echo "⚠️  LaunchAgent plist 不存在，執行 service install..."
  [[ "$CHECK_ONLY" == "--check-only" ]] && exit 1
  cloudflared service install
fi

# 4. 確認 plist 有帶 tunnel run 參數
if ! grep -q 'tunnel' "$PLIST" || ! grep -q 'run' "$PLIST"; then
  echo "⚠️  plist 缺少 tunnel run 參數，修復中..."
  [[ "$CHECK_ONLY" == "--check-only" ]] && { echo "❌ plist 參數有誤"; exit 1; }

  # 備份
  cp "$PLIST" "${PLIST}.bak"

  # 在 cloudflared binary 後面插入 tunnel run
  python3 - "$PLIST" <<'EOF'
import sys, plistlib, pathlib

path = pathlib.Path(sys.argv[1])
with open(path, 'rb') as f:
    pl = plistlib.load(f)

args = pl.get('ProgramArguments', [])
# 確保只有一個 cloudflared binary，後面接 tunnel run
binary = args[0]
pl['ProgramArguments'] = [binary, 'tunnel', 'run']

with open(path, 'wb') as f:
    plistlib.dump(pl, f)
print("plist 修復完成")
EOF

  # 重載
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  sleep 3
fi

# 5. 確認 process 有在跑
if ! pgrep -x cloudflared &>/dev/null; then
  echo "⚠️  cloudflared 沒在跑，嘗試啟動..."
  [[ "$CHECK_ONLY" == "--check-only" ]] && { echo "❌ cloudflared 未執行"; exit 1; }
  launchctl start com.cloudflare.cloudflared 2>/dev/null || launchctl load "$PLIST"
  sleep 3
fi

if pgrep -x cloudflared &>/dev/null; then
  echo "✅ cloudflared 正在執行 (pid $(pgrep -x cloudflared))"
else
  echo "❌ cloudflared 啟動失敗，請查看 ~/Library/Logs/com.cloudflare.cloudflared.err.log"
  exit 1
fi

# 6. 測試 webhook URL（若 config.yml 有 hostname）
HOSTNAME=$(grep 'hostname:' "$HOME/.cloudflared/config.yml" | head -1 | awk '{print $NF}')
if [[ -n "$HOSTNAME" ]]; then
  echo "🔍 測試 https://$HOSTNAME ..."
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://$HOSTNAME" 2>/dev/null || echo "000")
  if [[ "$HTTP" == "200" || "$HTTP" == "302" || "$HTTP" == "404" || "$HTTP" == "401" ]]; then
    echo "✅ 外部連線正常 (HTTP $HTTP)"
  else
    echo "⚠️  外部回應 HTTP $HTTP，tunnel 可能還在建立中（稍等幾秒再試）"
  fi
fi

echo ""
echo "=== 完成 ==="
