#!/bin/bash
# line-session-check/check.sh — Batch session health check with restart recommendations
# Outputs structured results; calling session (Opus) handles restart decisions.
set -uo pipefail

SESSIONS="claude-line claude-line-ita claude-line-note claude-line-talk claude-line-recipe claude-line-ptcg"
TOKEN_THRESHOLD=140  # k tokens — sessions above this get flagged

RESTART_LIST=""
RESPAWN_LIST=""

echo "=== LINE Session Check / $(date '+%Y-%m-%d %H:%M:%S') ==="
echo ""

# ── Infrastructure quick-check ──
echo "── Infrastructure ──"

if pgrep -f "cloudflared.*tunnel" >/dev/null 2>&1; then
  echo "  ✅ cloudflared tunnel running"
else
  echo "  ❌ cloudflared tunnel NOT running"
fi

health_code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:3001/health 2>/dev/null)
if [ "$health_code" = "200" ]; then
  echo "  ✅ webhook server healthy (port 3001)"
else
  echo "  ❌ webhook server unhealthy (HTTP $health_code)"
fi

pending_json=$(curl -s -m 3 http://localhost:3001/health 2>/dev/null)
pending_total=0
if [ -n "$pending_json" ]; then
  pending_total=$(echo "$pending_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(sum(data.get('pending', {}).values()))
" 2>/dev/null || echo 0)
fi
if [ "$pending_total" -gt 0 ] 2>/dev/null; then
  echo "  ⚠️  queue pending total: $pending_total"
else
  echo "  ✅ queue pending: 0"
fi

echo ""
echo "── Sessions ──"

get_descendants() {
  # ps 而非 pgrep -P：macOS pgrep 會漏掉改寫過 process title 的 node/claude
  # （實案 2026-07-05：claude-line 的 claude 65201 ps 看得到、pgrep 看不到 → 誤報 no claude process）
  local parent=$1
  local kids
  kids=$(ps -axo pid=,ppid= 2>/dev/null | awk -v p="$parent" '$2 == p {print $1}') || return 0
  for k in $kids; do
    echo "$k"
    get_descendants "$k"
  done
}

for sess in $SESSIONS; do
  status_icon="✅"
  status_parts=""
  needs_action=""

  # 1. tmux session exists?
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "  $sess | ❌ tmux session missing"
    RESPAWN_LIST="${RESPAWN_LIST:+$RESPAWN_LIST }$sess"
    continue
  fi

  # 2. claude process alive?
  pane_pid=$(tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1)
  has_claude=0
  claude_pid=""
  if [ -n "$pane_pid" ]; then
    for c in $pane_pid $(get_descendants "$pane_pid"); do
      if ps -p "$c" -o command= 2>/dev/null | grep -qE "(^|/)claude([[:space:]]|$)"; then
        has_claude=1
        claude_pid=$c
        break
      fi
    done
  fi

  if [ "$has_claude" = "0" ]; then
    echo "  $sess | ❌ no claude process"
    RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }$sess"
    continue
  fi
  status_parts="alive"

  # 3. Capture pane for token count + errors
  pane_text=$(tmux capture-pane -t "$sess" -p -S - 2>/dev/null)

  # ── Token count: JSONL primary, pane fallback ──
  token_source=""
  token_k=""
  token_num=""

  # Determine project slug for transcript path
  case "$sess" in
    claude-line)      slug_suffix="" ;;
    claude-line-ita)  slug_suffix="-ita" ;;
    claude-line-note) slug_suffix="-note" ;;
    claude-line-talk) slug_suffix="-talk" ;;
    claude-line-recipe) slug_suffix="-recipe" ;;
    claude-line-ptcg) slug_suffix="-ptcg" ;;
    *)                slug_suffix="" ;;
  esac
  base_slug="-Users-<user>-Documents-life-os-ws-line${slug_suffix}"
  proj_dir="$HOME/.claude/channels/line/claude-config/projects/${base_slug}"

  claude_start_time=""
  if [ -n "$claude_pid" ]; then
    claude_start_time=$(LC_ALL=C ps -p "$claude_pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi

  # 4 candidate project directories (matching token-watchdog.sh strategy)
  alt_slug="-Users-<user>-life-os-ws-line${slug_suffix}"
  candidate_dirs=""
  if [ -d "$HOME/.claude/projects" ]; then
    candidate_dirs="${candidate_dirs:+$candidate_dirs }$HOME/.claude/projects/${base_slug}"
    candidate_dirs="${candidate_dirs:+$candidate_dirs }$HOME/.claude/projects/${alt_slug}"
  fi
  if [ -d "$HOME/.claude/channels/line/claude-config/projects" ]; then
    candidate_dirs="${candidate_dirs:+$candidate_dirs }$HOME/.claude/channels/line/claude-config/projects/${base_slug}"
  fi
  if [ -d "$HOME/.claude/channels/line/claude-config/projects" ]; then
    # non-Documents variant
    candidate_dirs="${candidate_dirs:+$candidate_dirs }$HOME/.claude/channels/line/claude-config/projects/${alt_slug}"
  fi

  token_from_jsonl=""
  # Convert lstart to epoch seconds (python strptime: C-locale, same as token-watchdog;
  # BSD `date -j -f` fails here — %a/%b are locale-dependent and LANG is zh_TW)
  start_epoch=""
  if [ -n "$claude_start_time" ]; then
    start_epoch=$(python3 -c 'from datetime import datetime; import sys; print(int(datetime.strptime(sys.argv[1], "%a %b %d %H:%M:%S %Y").timestamp()))' "$claude_start_time" 2>/dev/null || echo "")
  fi

  # Collect ALL current-incarnation JSONLs (birthtime >= claude start), then let
  # python compute best last-usage across them — same multi-file strategy as
  # token-watchdog.sh; avoids missing a fat file when the newest one is empty/partial.
  filtered_jsonls=()
  if [ -n "$start_epoch" ]; then
    for candidate in $candidate_dirs; do
      [ -d "$candidate" ] || continue
      for jsonl in "$candidate"/*.jsonl; do
        [ -f "$jsonl" ] || continue
        birthtime=$(stat -f %B "$jsonl" 2>/dev/null || echo 0)
        case "$birthtime" in ''|*[!0-9]*) birthtime=0 ;; esac
        if [ "$birthtime" -ge "$start_epoch" ]; then
          filtered_jsonls+=("$jsonl")
        fi
      done
    done
  fi

  if [ "${#filtered_jsonls[@]}" -gt 0 ]; then
      token_from_jsonl=$(python3 - "${filtered_jsonls[@]}" << 'PYEOF'
import json, sys

best_total = 0
for filepath in sys.argv[1:]:
    last_total = 0
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            for line in f:
                try:
                    d = json.loads(line)
                    u = (d.get('message') or {}).get('usage') or d.get('usage') or {}
                    total = (
                        u.get('input_tokens', 0) +
                        u.get('cache_read_input_tokens', 0) +
                        u.get('cache_creation_input_tokens', 0)
                    )
                    if total > 0:
                        last_total = total
                except:
                    continue
    except:
        pass
    if last_total > best_total:
        best_total = last_total
print(best_total)
PYEOF
      )
      token_from_jsonl=$(echo "$token_from_jsonl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$token_from_jsonl" ] && [ "$token_from_jsonl" -gt 0 ] 2>/dev/null; then
        token_num="$token_from_jsonl"
        token_k=$(awk "BEGIN {printf \"%.1f\", $token_num / 1000}")
        token_source="jsonl"
      fi
  fi

  # Fallback: pane grep (value is in k units — convert to raw tokens so the
  # threshold comparison below works on one unit)
  if [ -z "$token_source" ]; then
    token_str=$(echo "$pane_text" | grep -oE '[0-9]+(\.[0-9]+)?k tokens' | tail -1)
    if [ -n "$token_str" ]; then
      token_k=$(echo "$token_str" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
      token_num=$(awk "BEGIN {printf \"%d\", ${token_k:-0} * 1000}")
      token_source="pane"
    fi
  fi

  # Update status_parts
  if [ -n "$token_k" ]; then
    status_parts="$status_parts | tokens: ${token_k}k tokens (${token_source})"
    if [ -n "$token_num" ] && [ "$token_num" -gt $((TOKEN_THRESHOLD * 1000)) ]; then
      status_icon="⚠️"
      needs_action="tokens_high"
    fi
  else
    status_parts="$status_parts | tokens: n/a (no-transcript)"
  fi

  # Error detection
  error_line=""
  if echo "$pane_text" | grep -qiE 'Operation not permitted|SIGTERM|panic|fatal'; then
    error_line=$(echo "$pane_text" | grep -iE 'Operation not permitted|SIGTERM|panic|fatal' | tail -1 | head -c 80)
    status_icon="⚠️"
    needs_action="${needs_action:+$needs_action,}error"
  fi

  # Idle state
  if echo "$pane_text" | grep -q "❯"; then
    status_parts="$status_parts | idle"
  else
    status_parts="$status_parts | busy/boot"
  fi

  # Rating prompt (session finished but stuck at rating)
  if echo "$pane_text" | grep -qE 'How is Claude doing'; then
    status_parts="$status_parts | rating-prompt"
  fi

  echo "  $sess | $status_icon $status_parts"
  if [ -n "$error_line" ]; then
    echo "    └─ error: $error_line"
  fi

  if [ -n "$needs_action" ]; then
    RESTART_LIST="${RESTART_LIST:+$RESTART_LIST }$sess"
  fi
done

echo ""
echo "── Summary ──"
if [ -z "$RESTART_LIST" ] && [ -z "$RESPAWN_LIST" ]; then
  echo "  ✅ All sessions healthy"
else
  [ -n "$RESTART_LIST" ] && echo "  ⚠️  RESTART needed: $RESTART_LIST"
  [ -n "$RESPAWN_LIST" ] && echo "  ❌ RESPAWN needed: $RESPAWN_LIST"
fi

echo ""
echo "RESTART_LIST=${RESTART_LIST}"
echo "RESPAWN_LIST=${RESPAWN_LIST}"