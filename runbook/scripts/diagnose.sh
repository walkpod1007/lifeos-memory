#!/usr/bin/env bash
# diagnose.sh — Runbook 核心診斷腳本
# 用法：bash diagnose.sh "<錯誤描述關鍵字>"
# 輸出：結構化排障報告

set -euo pipefail

KEYWORD="${1:-}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
MAX_LINES=50   # 每個 log 來源最多顯示行數
CONTEXT_LINES=3  # grep 上下文行數

# ── 顏色（終端支援時）
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Log 搜尋路徑（依優先序）
LOG_DIRS=(
  "$HOME/.claude/logs"
  "$HOME/life-os/logs"
  "$HOME/Library/Logs"
)
TEMP_PATTERNS=(
  "/tmp/claude-*.log"
  "/tmp/gateway-*.log"
)

# ── 錯誤類型分類關鍵字
declare -A ERROR_PATTERNS=(
  ["Gateway/Process"]="gateway.*crash|process.*exit|EADDRINUSE|ECONNREFUSED|spawn"
  ["LINE Webhook"]="line.*webhook|webhook.*line|reply.*token|channelAccess"
  ["AI-CLI"]="codex.*error|glm.*error|mini-agent.*error|429|rate.limit|quota.*exceeded|API.*key"
  ["n8n/Docker"]="n8n|docker.*stop|container.*exit"
  ["Auth/Token"]="token.*expired|unauthorized|401|403|auth.*fail"
  ["Network"]="ETIMEDOUT|ENOTFOUND|timeout|502|503|connection.*refused"
  ["File/Permission"]="ENOENT|EACCES|permission.*denied|no such file"
  ["Script/Shell"]="syntax.*error|command.*not.*found|bad.*substitution"
)

# ── 建議行動對應表
declare -A SUGGEST_ACTIONS=(
  ["Gateway/Process"]="1. openclaw gateway restart\n2. 若仍失敗：openclaw gateway install --force\n3. 確認 port 未被佔用：lsof -i :3000"
  ["LINE Webhook"]="1. 確認 channelAccessToken 未過期\n2. 確認 Cloudflare Tunnel 正常：cloudflared tunnel status\n3. 測試 webhook：curl -X POST <webhook_url>"
  ["AI-CLI"]="1. 等待 rate limit 重置（通常 60 秒）\n2. 確認 codex 登入狀態：codex --version\n3. 改用備用金剛（GLM / mini-agent）"
  ["n8n/Docker"]="1. 重啟 n8n：docker start openclaw-n8n\n2. 確認 Docker 服務：docker ps -a | grep n8n"
  ["Auth/Token"]="1. 重新授權相關服務\n2. 確認 openclaw.json token 設定\n3. 必要時 openclaw gateway restart"
  ["Network"]="1. 確認網路連線\n2. 確認 Cloudflare Tunnel 狀態\n3. 檢查 DNS：nslookup api.line.me"
  ["File/Permission"]="1. 確認路徑存在：ls -la <path>\n2. 修正權限：chmod +x <script>\n3. 確認磁碟空間：df -h ~"
  ["Script/Shell"]="1. 確認腳本語法：bash -n <script>\n2. 確認依賴已安裝\n3. 查看完整錯誤訊息"
)

# ── 輔助函式
log_found=0
found_types=()
all_matches=""

search_log_file() {
  local file="$1"
  local label="$2"
  local result=""

  # 判斷是否為 JSON 格式 log
  local sample
  sample=$(head -1 "$file" 2>/dev/null || true)

  if echo "$sample" | grep -q '^{'; then
    # JSON log：用 jq 展平（若有 jq）
    if command -v jq &>/dev/null; then
      if [ -n "$KEYWORD" ]; then
        result=$(grep -i "$KEYWORD" "$file" 2>/dev/null | tail -$MAX_LINES | \
          jq -r '. | "\(.time // .timestamp // "?") [\(.level // .severity // "?")] \(.msg // .message // .error // .)"' 2>/dev/null || \
          grep -i "$KEYWORD" "$file" 2>/dev/null | tail -$MAX_LINES)
      else
        result=$(grep -iE "error|exception|fatal|warn" "$file" 2>/dev/null | tail -$MAX_LINES | \
          jq -r '. | "\(.time // .timestamp // "?") [\(.level // .severity // "?")] \(.msg // .message // .error // .)"' 2>/dev/null || \
          grep -iE "error|exception|fatal|warn" "$file" 2>/dev/null | tail -$MAX_LINES)
      fi
    else
      if [ -n "$KEYWORD" ]; then
        result=$(grep -i "$KEYWORD" "$file" 2>/dev/null | tail -$MAX_LINES)
      else
        result=$(grep -iE "error|exception|fatal|warn" "$file" 2>/dev/null | tail -$MAX_LINES)
      fi
    fi
  else
    # 純文字 log
    if [ -n "$KEYWORD" ]; then
      result=$(grep -iE "$KEYWORD|error|exception|fatal" "$file" 2>/dev/null | tail -$MAX_LINES || true)
    else
      result=$(grep -iE "error|exception|fatal|warn" "$file" 2>/dev/null | tail -$MAX_LINES || true)
    fi
  fi

  if [ -n "$result" ]; then
    echo ""
    echo "  📄 $label"
    echo "$result" | sed 's/^/    /'
    log_found=1
    all_matches+="$result"$'\n'
  fi
}

classify_errors() {
  local matches="$1"
  found_types=()

  for type in "${!ERROR_PATTERNS[@]}"; do
    if echo "$matches" | grep -iEq "${ERROR_PATTERNS[$type]}"; then
      found_types+=("$type")
    fi
  done

  # 若關鍵字本身可以提示類型
  if [ -n "$KEYWORD" ]; then
    case "$KEYWORD" in
      *gateway*|*process*) found_types+=("Gateway/Process") ;;
      *line*|*webhook*) found_types+=("LINE Webhook") ;;
      *codex*|*glm*|*429*|*rate*) found_types+=("AI-CLI") ;;
      *n8n*|*docker*) found_types+=("n8n/Docker") ;;
      *token*|*auth*|*401*|*403*) found_types+=("Auth/Token") ;;
      *timeout*|*502*|*503*|*network*) found_types+=("Network") ;;
      *permission*|*enoent*) found_types+=("File/Permission") ;;
    esac
  fi

  # 去重
  local -A seen=()
  local unique=()
  for t in "${found_types[@]}"; do
    if [ -z "${seen[$t]+x}" ]; then
      seen[$t]=1
      unique+=("$t")
    fi
  done
  found_types=("${unique[@]}")
}

# ════════════════════════════════════════
# 主程式開始
# ════════════════════════════════════════

echo ""
echo "${BOLD}${CYAN}=== 🔍 Runbook 診斷報告 ===${RESET}"
echo "時間：$TIMESTAMP"
if [ -n "$KEYWORD" ]; then
  echo "關鍵字：${BOLD}$KEYWORD${RESET}"
else
  echo "關鍵字：（未指定，掃描所有 ERROR/WARN）"
fi
echo ""

# ── 掃描 Log 目錄
echo "${BOLD}【Log 掃描】${RESET}"

for dir in "${LOG_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    while IFS= read -r -d '' file; do
      size=$(wc -l < "$file" 2>/dev/null || echo 0)
      if [ "$size" -gt 0 ]; then
        rel_path="${file/$HOME/\~}"
        search_log_file "$file" "$rel_path"
      fi
    done < <(find "$dir" -maxdepth 3 -type f \( -name "*.log" -o -name "*.txt" \) -newer /tmp -print0 2>/dev/null || \
              find "$dir" -maxdepth 3 -type f \( -name "*.log" -o -name "*.txt" \) -print0 2>/dev/null)
  fi
done

# 掃描 /tmp 暫存 log
for pattern in "${TEMP_PATTERNS[@]}"; do
  for file in $pattern; do
    [ -f "$file" ] && search_log_file "$file" "/tmp/$(basename "$file")"
  done
done

if [ "$log_found" -eq 0 ]; then
  echo "  ${YELLOW}⚠️  未找到相關 Log${RESET}"
  echo "  可能原因："
  echo "    - Log 目錄尚未建立（系統首次啟動）"
  echo "    - 錯誤發生時間較早，Log 已 rotate"
  echo "    - 關鍵字未命中任何 log 行"
  echo ""
  echo "  手動補查："
  echo "    log show --predicate 'process == \"node\"' --last 1h | grep -i claude"
fi

echo ""

# ── 錯誤類型分類
echo "${BOLD}【錯誤類型】${RESET}"
classify_errors "$all_matches"

if [ "${#found_types[@]}" -gt 0 ]; then
  for t in "${found_types[@]}"; do
    echo "  ${RED}▶ $t${RESET}"
  done
else
  echo "  ${GREEN}✓ 未偵測到已知錯誤模式${RESET}"
  if [ -n "$KEYWORD" ]; then
    echo "  （關鍵字 \"$KEYWORD\" 無命中，可能是新型錯誤或拼寫不符）"
  fi
fi

echo ""

# ── 建議行動
echo "${BOLD}【建議行動】${RESET}"

if [ "${#found_types[@]}" -gt 0 ]; then
  step=1
  for t in "${found_types[@]}"; do
    echo "  ${BOLD}▸ $t：${RESET}"
    if [ -n "${SUGGEST_ACTIONS[$t]+x}" ]; then
      echo -e "${SUGGEST_ACTIONS[$t]}" | sed "s/^/    /"
    fi
    echo ""
  done
else
  echo "  1. 確認 Gateway 狀態：openclaw gateway status"
  echo "  2. 重啟 Gateway：openclaw gateway restart"
  echo "  3. 查看更多 log：tail -100 ~/.claude/logs/*.log"
  echo "  4. 若問題持續，提供完整錯誤訊息再次執行診斷"
fi

# ── Gateway 快速健檢
echo "${BOLD}【系統快速健檢】${RESET}"

# Gateway 狀態
gw_status=$(openclaw gateway status 2>&1 | head -3 || echo "無法取得")
echo "  Gateway：$gw_status"

# n8n Docker
if command -v docker &>/dev/null; then
  n8n_status=$(docker ps --filter "name=openclaw-n8n" --format "{{.Status}}" 2>/dev/null || echo "docker 未連線")
  if [ -n "$n8n_status" ]; then
    echo "  n8n：$n8n_status"
  else
    echo "  n8n：${YELLOW}container 未運行${RESET}"
  fi
fi

# Cloudflare Tunnel
if command -v cloudflared &>/dev/null; then
  cf_status=$(cloudflared tunnel list 2>&1 | grep -c "HEALTHY" || echo "0")
  echo "  Cloudflare Tunnel：$cf_status 個正常"
fi

echo ""
echo "${BOLD}${CYAN}=== 報告結束 ===${RESET}"
echo ""
