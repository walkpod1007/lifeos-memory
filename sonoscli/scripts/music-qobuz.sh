#!/usr/bin/env bash
# Version: 1.0
# Last modified: 2026-03-16
# Status: active
# Level: B
# music-qobuz.sh — Qobuz search + play via Sonos UPnP
# Usage:
#   music-qobuz.sh auth
#   music-qobuz.sh search "query"
#   music-qobuz.sh play "query" [--name "書房"]
#   music-qobuz.sh queue "query" [--name "書房"] [--limit 8]

set -euo pipefail

ENV_FILE="$HOME/.claude/.env"
DEFAULT_SPEAKER="書房"
SONOS="/opt/homebrew/bin/sonos"

QOBUZ_API="https://www.qobuz.com/api.json/0.2"
# Public Qobuz app_id extracted from web player (read-only, no secret needed for search)
QOBUZ_APP_ID="${QOBUZ_APP_ID:-285473059}"

# Load tokens
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

QOBUZ_TOKEN="${QOBUZ_USER_AUTH_TOKEN:-}"

require_auth() {
  if [[ -z "$QOBUZ_TOKEN" ]]; then
    echo "Qobuz token 未設定。請執行: music-qobuz.sh auth"
    exit 1
  fi
}

cmd_auth() {
  echo "=== Qobuz Token 設定 ==="
  echo ""
  echo "方法一（推薦）：從瀏覽器抓取 token"
  echo "  1. 在 Chrome 開啟 https://play.qobuz.com"
  echo "  2. 登入 Qobuz 帳號"
  echo "  3. 開啟開發者工具 → Network 分頁"
  echo "  4. 播放任一首歌"
  echo "  5. 搜尋 X-User-Auth-Token header"
  echo "  6. 複製該 token 值"
  echo ""
  echo "方法二：直接 API 登入（需要 email + password）"
  echo ""

  read -rp "選擇方式 [1=瀏覽器抓取, 2=帳密登入]: " choice

  local auth_token=""

  if [[ "$choice" == "2" ]]; then
    read -rp "Qobuz Email: " qobuz_email
    read -rsp "Qobuz Password: " qobuz_password
    echo ""

    echo "登入中..."
    local login_response
    login_response=$(curl -sf \
      -X POST "$QOBUZ_API/user/login" \
      -H "X-App-Id: $QOBUZ_APP_ID" \
      -d "email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$qobuz_email'))")" \
      -d "password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$qobuz_password'))")" \
      -d "app_id=$QOBUZ_APP_ID") || { echo "登入失敗"; exit 1; }

    auth_token=$(echo "$login_response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('user_auth_token',''))
" 2>/dev/null || echo "")

    if [[ -z "$auth_token" ]]; then
      echo "登入失敗，請確認帳密是否正確"
      exit 1
    fi
    echo "登入成功"
  else
    read -rp "請貼上 X-User-Auth-Token: " auth_token
    if [[ -z "$auth_token" ]]; then
      echo "Token 不可為空"
      exit 1
    fi
  fi

  touch "$ENV_FILE"
  sed -i '' '/^QOBUZ_USER_AUTH_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  sed -i '' '/^QOBUZ_APP_ID=/d' "$ENV_FILE" 2>/dev/null || true
  echo "QOBUZ_USER_AUTH_TOKEN=$auth_token" >> "$ENV_FILE"
  echo "QOBUZ_APP_ID=$QOBUZ_APP_ID" >> "$ENV_FILE"
  echo "Token 已儲存至 $ENV_FILE"
}

cmd_search() {
  require_auth
  local query="$1"
  if [[ -z "$query" ]]; then
    echo "Usage: music-qobuz.sh search \"query\""
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local url="$QOBUZ_API/track/search?query=${encoded_query}&limit=10"

  local response
  response=$(curl -sf \
    -H "X-App-Id: $QOBUZ_APP_ID" \
    -H "X-User-Auth-Token: $QOBUZ_TOKEN" \
    "$url") || { echo "API 請求失敗（token 可能過期，請重新 auth）"; exit 1; }

  local count
  count=$(echo "$response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len(d.get('tracks',{}).get('items',[])))
" 2>/dev/null || echo 0)

  if [[ "$count" -eq 0 ]]; then
    echo "找不到「$query」的結果"
    exit 0
  fi

  echo "Qobuz 搜尋結果：$query"
  echo ""
  echo "$response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tracks=d.get('tracks',{}).get('items',[])
for i,t in enumerate(tracks,1):
    name=t.get('title','?')
    artist=t.get('performer',{}).get('name','?')
    album=t.get('album',{}).get('title','?')
    tid=t.get('id','?')
    hi_res='Hi-Res' if t.get('hires') else ('FLAC' if t.get('streamable') else '?')
    print(f'{i}. {name}')
    print(f'   {artist} — {album}')
    print(f'   ID: {tid}  格式: {hi_res}')
    print()
"
}

cmd_play() {
  require_auth
  local query=""
  local speaker="$DEFAULT_SPEAKER"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) speaker="$2"; shift 2 ;;
      *) query="$1"; shift ;;
    esac
  done

  if [[ -z "$query" ]]; then
    echo "Usage: music-qobuz.sh play \"query\" [--name \"書房\"]"
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local url="$QOBUZ_API/track/search?query=${encoded_query}&limit=1"

  local response
  response=$(curl -sf \
    -H "X-App-Id: $QOBUZ_APP_ID" \
    -H "X-User-Auth-Token: $QOBUZ_TOKEN" \
    "$url") || { echo "API 請求失敗"; exit 1; }

  local track_id display_name display_artist display_album uri meta
  local parsed
  parsed=$(echo "$response" | python3 -c "
import json,sys,xml.sax.saxutils as sx

d=json.load(sys.stdin)
items=d.get('tracks',{}).get('items',[])
if not items:
    print('__NOTFOUND__')
    sys.exit(0)

t=items[0]
track_id=str(t.get('id','')).strip()
if not track_id:
    print('__NOTFOUND__')
    sys.exit(0)

title=t.get('title') or 'Unknown Title'
artist=(t.get('performer') or {}).get('name') or 'Unknown Artist'
album=(t.get('album') or {}).get('title') or 'Unknown Album'
track_no=str(t.get('track_number') or 0)
cover=(t.get('album') or {}).get('image', {}) or {}
art=cover.get('large') or cover.get('small') or ''

uri=f'x-sonos-http:track%3a{track_id}%3a7.flac?sid=31&flags=8232&sn=18'

meta=(
    '<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" '
    'xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" '
    'xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" '
    'xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">'
    f'<item id=\"00030020track%3a{track_id}%3a7.flac\" parentID=\"\" restricted=\"true\">'
    f'<dc:title>{sx.escape(title)}</dc:title>'
    f'<dc:creator>{sx.escape(artist)}</dc:creator>'
    f'<upnp:artist>{sx.escape(artist)}</upnp:artist>'
    f'<upnp:album>{sx.escape(album)}</upnp:album>'
    f'<upnp:albumArtURI>{sx.escape(art)}</upnp:albumArtURI>'
    f'<upnp:originalTrackNumber>{track_no}</upnp:originalTrackNumber>'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    f'<res protocolInfo=\"sonos.com-http:*:audio/flac:*\">{sx.escape(uri)}</res>'
    '<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON7943_</desc>'
    '</item></DIDL-Lite>'
)

print(track_id)
print(title)
print(artist)
print(album)
print(uri)
print(meta)
")

  if [[ "$parsed" == "__NOTFOUND__" || -z "$parsed" ]]; then
    echo "找不到「$query」的結果"
    exit 1
  fi

  track_id=$(echo "$parsed" | sed -n '1p')
  display_name=$(echo "$parsed" | sed -n '2p')
  display_artist=$(echo "$parsed" | sed -n '3p')
  display_album=$(echo "$parsed" | sed -n '4p')
  uri=$(echo "$parsed" | sed -n '5p')
  meta=$(echo "$parsed" | sed -n '6p')

  echo "正在播放：$display_name — $display_artist"
  echo "專輯: $display_album"
  echo "URI: $uri"
  echo "喇叭: $speaker"
  echo ""

  local speaker_ip
  speaker_ip=$($SONOS discover --format json 2>/dev/null | python3 -c "
import json,sys
devs=json.load(sys.stdin)
for d in devs:
    if d.get('name','')=='$speaker':
        print(d['ip'])
        break
" 2>/dev/null)

  if [[ -z "$speaker_ip" ]]; then
    echo "找不到喇叭: $speaker"
    exit 1
  fi

  python3 -c "
import soco
s=soco.SoCo('$speaker_ip')
uri='$uri'
meta='''$meta'''
s.avTransport.SetAVTransportURI([('InstanceID',0),('CurrentURI',uri),('CurrentURIMetaData',meta)])
s.play()
print('播放成功')
" 2>&1 || echo "播放失敗（可能是 URI 格式或 token 問題）"
}

cmd_queue() {
  require_auth
  local query=""
  local speaker="$DEFAULT_SPEAKER"
  local limit=8

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) speaker="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) query="$1"; shift ;;
    esac
  done

  if [[ -z "$query" ]]; then
    echo "Usage: music-qobuz.sh queue \"query\" [--name \"書房\"] [--limit 8]"
    exit 1
  fi

  local speaker_ip
  speaker_ip=$($SONOS discover --format json 2>/dev/null | python3 -c "
import json,sys
devs=json.load(sys.stdin)
for d in devs:
    if d.get('name','')=='$speaker':
        print(d['ip'])
        break
" 2>/dev/null)

  if [[ -z "$speaker_ip" ]]; then
    echo "找不到喇叭: $speaker"
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")
  local url="$QOBUZ_API/track/search?query=${encoded_query}&limit=${limit}"

  local response
  response=$(curl -sf \
    -H "X-App-Id: $QOBUZ_APP_ID" \
    -H "X-User-Auth-Token: $QOBUZ_TOKEN" \
    "$url") || { echo "API 請求失敗"; exit 1; }

  python3 - <<PY
import json, xml.sax.saxutils as sx
import soco

data=json.loads('''$response''')
items=data.get('tracks',{}).get('items',[])
if not items:
    print('找不到結果')
    raise SystemExit(1)

s=soco.SoCo('$speaker_ip')
s.stop(); s.clear_queue()

count=0
for t in items:
    tid=str(t.get('id') or '').strip()
    if not tid:
        continue
    title=t.get('title') or 'Unknown Title'
    artist=(t.get('performer') or {}).get('name') or 'Unknown Artist'
    album=(t.get('album') or {}).get('title') or 'Unknown Album'
    trno=str(t.get('track_number') or 0)
    cover=((t.get('album') or {}).get('image') or {})
    art=cover.get('large') or cover.get('small') or ''
    uri=f'x-sonos-http:track%3a{tid}%3a7.flac?sid=31&flags=8232&sn=18'
    meta=(
      '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
      'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
      'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
      f'<item id="00030020track%3a{tid}%3a7.flac" parentID="" restricted="true">'
      f'<dc:title>{sx.escape(title)}</dc:title>'
      f'<dc:creator>{sx.escape(artist)}</dc:creator>'
      f'<upnp:artist>{sx.escape(artist)}</upnp:artist>'
      f'<upnp:album>{sx.escape(album)}</upnp:album>'
      f'<upnp:albumArtURI>{sx.escape(art)}</upnp:albumArtURI>'
      f'<upnp:originalTrackNumber>{trno}</upnp:originalTrackNumber>'
      '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
      f'<res protocolInfo="sonos.com-http:*:audio/flac:*">{sx.escape(uri)}</res>'
      '<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON7943_</desc>'
      '</item></DIDL-Lite>'
    )
    s.avTransport.AddURIToQueue([
      ('InstanceID',0),('EnqueuedURI',uri),('EnqueuedURIMetaData',meta),('DesiredFirstTrackNumberEnqueued',0),('EnqueueAsNext',0)
    ])
    count += 1

if count == 0:
    print('沒有可入隊曲目')
    raise SystemExit(1)

s.playmode='NORMAL'
s.play_from_queue(0)

# Hard acceptance gate
q=list(s.get_queue())[:3]
bad=False
for t in q:
    title=(getattr(t,'title',None) or '').strip()
    if (not title) or title.lower().startswith('unknown') or ('沒有內容' in title):
        bad=True
current=(s.get_current_track_info().get('title') or '').strip()
if (not current) or bad:
    print('FAIL_FALLBACK: metadata_missing')
    raise SystemExit(2)

print(f'排入 {count} 首，現正播放：{current}')
PY
}

CMD="${1:-}"
shift || true

case "$CMD" in
  auth)   cmd_auth ;;
  search) cmd_search "${1:-}" ;;
  play)   cmd_play "$@" ;;
  queue)  cmd_queue "$@" ;;
  *)
    echo "Usage: music-qobuz.sh <auth|search|play|queue>"
    echo "  auth                設定 Qobuz token"
    echo "  search \"query\"      搜尋曲目"
    echo "  play \"query\"        播放第一個結果 [--name 喇叭名稱]"
    echo "  queue \"query\"       建立多首佇列 [--name 喇叭名稱] [--limit 8]"
    exit 1
    ;;
esac
