#!/bin/bash
# Version: 1.0
# Last modified: 2026-03-11
# Status: active
# Level: B
# music-gen.sh — Loudly AI 音樂生成腳本（零 Push 架構）
# 用法：bash music-gen.sh "<描述>" [duration_seconds]
# 結果：存入 pending-result.json（type=audio_card）
# 由下一則使用者訊息攜帶 reply token 輸出，零 Push

set -euo pipefail

PROMPT="${1:-}"
DURATION="${2:-60}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PENDING_SCRIPT="$SCRIPTS_DIR/pending-result.sh"
SECRET_HELPER="$SCRIPTS_DIR/openclaw-secret.sh"

log() { echo "[$(date +%H:%M:%S)] [MUSIC-GEN] $*"; }

# 讀 API Key
LOUDLY_API_KEY="$("$SECRET_HELPER" loudly-api-key 2>/dev/null || echo "")"

if [[ -z "$LOUDLY_API_KEY" ]]; then
  log "❌ 找不到 LOUDLY_API_KEY（~/.claude/.env）"
  exit 1
fi

if [[ -z "$PROMPT" ]]; then
  log "❌ 需要描述參數"
  exit 1
fi

# 確保 duration 在範圍內
if (( DURATION < 30 )); then DURATION=30; fi
if (( DURATION > 420 )); then DURATION=420; fi

log "生成中... prompt='$PROMPT' duration=${DURATION}s"

# 呼叫 Loudly API
RESPONSE=$(curl -s --max-time 120 \
  --request POST \
  --url "https://soundtracks.loudly.com/api/ai/prompt/songs" \
  --header "API-KEY: $LOUDLY_API_KEY" \
  --header "Accept: application/json" \
  --header "Content-Type: multipart/form-data" \
  --form "prompt=$PROMPT" \
  --form "duration=$DURATION" 2>&1)

if [[ -z "$RESPONSE" ]]; then
  log "❌ API 回傳空結果"
  exit 1
fi

# 解析回應
PARSED=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    if 'music_file_path' not in d:
        print('ERROR:' + json.dumps(d), file=sys.stderr)
        sys.exit(1)
    print(json.dumps({
        'id': d.get('id', ''),
        'title': d.get('title', 'AI Music'),
        'music_url': d['music_file_path'],
        'duration_ms': d.get('duration', 0),
        'bpm': d.get('bpm', 0),
        'key': d.get('key', {}).get('name', ''),
    }, ensure_ascii=False))
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" "$RESPONSE" 2>&1)

if echo "$PARSED" | grep -q "^ERROR:"; then
  log "❌ API 錯誤: $PARSED"
  exit 1
fi

TITLE=$(echo "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
MUSIC_URL=$(echo "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin)['music_url'])")
DURATION_MS=$(echo "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin)['duration_ms'])")
BPM=$(echo "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin)['bpm'])")
KEY_NAME=$(echo "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")

DURATION_SEC=$((DURATION_MS / 1000))
CAPTION="${PROMPT:0:40}"

log "✅ 生成完成: $TITLE (${DURATION_SEC}s, ${BPM}bpm, $KEY_NAME)"
log "   URL: $MUSIC_URL"

# 存備查
echo "$PARSED" > /tmp/line-last-music.json
log "已存 /tmp/line-last-music.json"

# 下載音檔 + 歸檔 + 複製到 public-audio
GEN_AUDIO_DIR="$HOME/life-os/media/generated-audio"
PUB_AUDIO_DIR="$HOME/life-os/media/public-audio"
mkdir -p "$GEN_AUDIO_DIR" "$PUB_AUDIO_DIR"
TODAY_TAG=$(TZ=Asia/Taipei date '+%Y-%m-%d')
SAFE_TITLE=$(echo "$TITLE" | tr ' /:' '-' | head -c 40)
AUDIO_FILE="${TODAY_TAG}_${SAFE_TITLE}.mp3"
curl -s -L "$MUSIC_URL" -o "$GEN_AUDIO_DIR/$AUDIO_FILE" 2>/dev/null
if [[ -f "$GEN_AUDIO_DIR/$AUDIO_FILE" ]] && [[ -s "$GEN_AUDIO_DIR/$AUDIO_FILE" ]]; then
  cp "$GEN_AUDIO_DIR/$AUDIO_FILE" "$PUB_AUDIO_DIR/$AUDIO_FILE"
  MUSIC_URL="https://<YOUR_DOMAIN>/public-audio/$AUDIO_FILE"
  log "📁 已歸檔 + 公開連結: $MUSIC_URL"
else
  log "⚠️ 音檔下載失敗，使用原始 URL"
fi

# 寫入 pending-result
PENDING_JSON=$(python3 -c "
import json, sys
print(json.dumps({
    'type': 'audio_card',
    'title': sys.argv[1],
    'caption': sys.argv[2],
    'url': sys.argv[3],
    'duration': sys.argv[4],
    'bpm': sys.argv[5],
    'key': sys.argv[6],
    'source': 'Loudly AI'
}, ensure_ascii=False))
" "$TITLE" "$CAPTION" "$MUSIC_URL" "$DURATION_SEC" "$BPM" "$KEY_NAME")

bash "$PENDING_SCRIPT" write "$PENDING_JSON"
log "✅ pending-result 已寫入"

# Push 音樂連結給使用者
LINE_TOKEN=$(grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env | cut -d= -f2 2>/dev/null || echo "")
LINE_USER="${LINE_PUSH_USER:-<LINE_USER_ID>}"
if [ -n "$LINE_TOKEN" ]; then
  curl -s -X POST "https://api.line.me/v2/bot/message/push" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LINE_TOKEN" \
    -d "{\"to\":\"$LINE_USER\",\"messages\":[{\"type\":\"text\",\"text\":\"🎵 $TITLE\\n$CAPTION\\n$MUSIC_URL\"}]}" \
    > /dev/null 2>&1 && log "📤 Push 音樂已送出" || log "WARN: Push 失敗"
  bash "$PENDING_SCRIPT" clear 2>/dev/null
fi
