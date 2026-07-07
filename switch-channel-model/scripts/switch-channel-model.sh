#!/bin/bash
# switch-channel-model.sh - 切換 channel session 的 model 並重啟 supervisor
#
# 為什麼存在：safe-restart 只 SIGTERM inner claude，supervisor (bash compound while loop)
# 會用 in-memory 舊指令重拉。換 model 必須砍 tmux + 重 spawn supervisor 本身。
#
# 用法：bash switch-channel-model.sh <channel> <model>
# 退出碼：0=成功 / 1=驗證失敗 / 2=supervisor 不存在 / 3=用法/白名單錯
set -u

CHANNEL="${1:-}"
NEW_MODEL="${2:-}"
CHANNEL_WHITELIST="claude-line claude-line-talk claude-line-ita claude-line-note claude-line-ptcg claude-line-recipe claude-remote"
MODEL_WHITELIST="claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-sonnet-5 claude-fable-5 claude-sonnet-4-6 claude-haiku-4-5-20251001"
LOG="$HOME/.claude/switch-channel-model.log"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] [$CHANNEL] $*" | tee -a "$LOG"; }

if [ -z "$CHANNEL" ] || [ -z "$NEW_MODEL" ]; then
  echo "Usage: $0 <channel> <model>" >&2
  echo "  channels: $CHANNEL_WHITELIST" >&2
  echo "  models:   $MODEL_WHITELIST" >&2
  exit 3
fi

VALID_CHANNEL=""
for c in $CHANNEL_WHITELIST; do
  [ "$CHANNEL" = "$c" ] && VALID_CHANNEL=1 && break
done
[ -z "$VALID_CHANNEL" ] && { echo "Error: unknown channel '$CHANNEL'" >&2; exit 3; }

VALID_MODEL=""
for m in $MODEL_WHITELIST; do
  [ "$NEW_MODEL" = "$m" ] && VALID_MODEL=1 && break
done
[ -z "$VALID_MODEL" ] && { echo "Error: unknown model '$NEW_MODEL'" >&2; exit 3; }

SUPERVISOR_SCRIPT="$HOME/life-os/scripts/${CHANNEL}.sh"
[ -f "$SUPERVISOR_SCRIPT" ] || { log "ERROR: supervisor script not found: $SUPERVISOR_SCRIPT"; exit 2; }

# SLUG = channel 去掉 'claude-' 前綴；用於 ws/<slug>/ 與 mcp-<slug>.json 對應
SLUG="${CHANNEL#claude-}"

log "=== START switch $CHANNEL → $NEW_MODEL ==="

# Step 1: drain — 寫 handoff 但**不殺** inner claude（避免 supervisor 用舊 model 重拉）
# 三件套：gen-handoff (Haiku 寫 4 段) → realtime-summary (snapshot to daily) → session-end hook (冷儲存)
log "step1 drain (handoff/snapshot/hook 但保留 claude alive)..."
# 2026-06-30 dir-fix：channel transcript 自 ~6/15 搬到 CLAUDE_CONFIG_DIR；掃舊+新兩目錄取最新
PROJ_DIR="$HOME/.claude/projects/-Users-<user>-Documents-life-os-ws-${SLUG}"
PROJ_DIR_CH="$HOME/.claude/channels/line/claude-config/projects/-Users-<user>-Documents-life-os-ws-${SLUG}"
TRANSCRIPT=""
TRANSCRIPT=$(ls -t "$PROJ_DIR"/*.jsonl "$PROJ_DIR_CH"/*.jsonl 2>/dev/null | head -1)

GEN_HANDOFF="$HOME/life-os/scripts/gen-handoff.sh"
if [ -x "$GEN_HANDOFF" ] && [ -n "$TRANSCRIPT" ]; then
  timeout 150 bash "$GEN_HANDOFF" "$TRANSCRIPT" "$CHANNEL" >> "$LOG" 2>&1 \
    && log "step1a ✓ gen-handoff" \
    || log "step1a ⚠️ gen-handoff rc=$?"
else
  log "step1a SKIP gen-handoff (no script or transcript)"
fi

REALTIME="$HOME/life-os/scripts/realtime-summary.sh"
if [ -x "$REALTIME" ]; then
  timeout 60 bash "$REALTIME" >> "$LOG" 2>&1 || log "step1b ⚠️ realtime rc=$?"
fi

HOOK="$HOME/life-os/hooks/claude-hook-session-end.sh"
if [ -x "$HOOK" ] && [ -n "$TRANSCRIPT" ]; then
  printf '{"transcript_path": "%s"}\n' "$TRANSCRIPT" | timeout 30 bash "$HOOK" >> "$LOG" 2>&1 \
    || log "step1c ⚠️ hook rc=$?"
fi
log "step1 ✓ drain 完成（claude 仍在跑，準備被 step3 砍）"

# Step 2: sed 改 supervisor script 的 --model
# anchor 限制在「cd ... && [command ]claude --model」這種 supervisor 啟動模式那一行，避免誤改註解或其他 claude 呼叫
log "step2 sed --model → $NEW_MODEL"
sed -i.bak -E '/^[[:space:]]*#/! s|^(.*cd .* && (command )?claude .*--model )[^ ]+|\1'"${NEW_MODEL}"'|' "$SUPERVISOR_SCRIPT"

# Step 3: 殺整個 tmux session（含 supervisor + claude）
log "step3 tmux kill-session -t $CHANNEL"
tmux kill-session -t "$CHANNEL" 2>/dev/null || log "step3 (no tmux session)"

# Step 4: 清 supervisor pid file（避免 wrap_or_skip 認 stale guard）
rm -f "$HOME/.claude/${CHANNEL}-supervisor.pid"

# Step 5: 立即 spawn 新 supervisor（不等 watchdog 5min cron）
log "step5 spawn supervisor..."
nohup bash "$SUPERVISOR_SCRIPT" >/dev/null 2>&1 &
disown
sleep 6

# Step 6: 驗證新 process 用新 model
# MCP config 路徑規則：mcp-<slug>.json，例 claude-line-talk → mcp-line-talk.json
# claude-remote 沒有 mcp-config flag，用 --remote-control-session-name-prefix 當特徵 anchor
log "step6 verify..."
case "$CHANNEL" in
  claude-remote)
    PID=$(pgrep -f "claude .*--model ${NEW_MODEL}.*--remote-control-session-name-prefix" 2>/dev/null | head -1)
    ;;
  *)
    PID=$(pgrep -f "claude .*--model ${NEW_MODEL}.*mcp-${SLUG}\.json" 2>/dev/null | head -1)
    ;;
esac

if [ -n "$PID" ]; then
  log "step6 ✓ PID=$PID"
  echo "OK $CHANNEL now running $NEW_MODEL (PID=$PID)"
  exit 0
else
  log "step6 ⚠️ pgrep no match for $NEW_MODEL on $CHANNEL"
  exit 1
fi
