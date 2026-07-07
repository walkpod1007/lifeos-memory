#!/usr/bin/env bash
# Version: 1.0
# Last modified: 2026-03-16
# Status: active
# Level: B
# music-tidal.sh — TIDAL search + play via Sonos UPnP
# Usage:
#   music-tidal.sh auth
#   music-tidal.sh search "query"
#   music-tidal.sh play "query" [--name "書房"]

set -euo pipefail

ENV_FILE="$HOME/.claude/.env"
DEFAULT_SPEAKER="書房"
SONOS="/opt/homebrew/bin/sonos"

# TIDAL API v1 (legacy, no OAuth needed for search with token)
TIDAL_API="https://api.tidal.com/v1"
TIDAL_COUNTRY="HU"
TIDAL_CLIENT_ID="${TIDAL_CLIENT_ID:-fX2JxdmntZWK0ixT}"

# Load tokens
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

TIDAL_TOKEN="${TIDAL_ACCESS_TOKEN:-}"
TIDAL_USER_ID="${TIDAL_USER_ID:-}"

require_auth() {
  if [[ -z "$TIDAL_TOKEN" ]]; then
    echo "TIDAL token 未設定。請執行: music-tidal.sh auth"
    exit 1
  fi
}

cmd_auth() {
  echo "=== TIDAL Device Auth ==="
  echo ""

  # Step 1: Request device code
  local device_resp
  device_resp=$(curl -sf -X POST "https://auth.tidal.com/v1/oauth2/device_authorization" \
    -d "client_id=${TIDAL_CLIENT_ID}&scope=r_usr+w_usr+offline_access") || { echo "Device auth 請求失敗"; exit 1; }

  local device_code user_code verify_url
  device_code=$(echo "$device_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['deviceCode'])")
  user_code=$(echo "$device_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['userCode'])")
  verify_url=$(echo "$device_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['verificationUriComplete'])")

  echo "請在瀏覽器打開：$verify_url"
  echo "然後登入你的 TIDAL 帳號"
  echo ""
  read -rp "完成後按 Enter..."

  # Step 2: Exchange for token
  local token_resp
  token_resp=$(curl -sf -X POST "https://auth.tidal.com/v1/oauth2/token" \
    -d "client_id=${TIDAL_CLIENT_ID}&client_secret=${TIDAL_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code&scope=r_usr+w_usr+offline_access") || { echo "Token 交換失敗（可能尚未完成登入）"; exit 1; }

  local access_token refresh_token user_id
  access_token=$(echo "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
  refresh_token=$(echo "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('refresh_token',''))")
  user_id=$(echo "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('user_id',''))")

  touch "$ENV_FILE"
  sed -i '' '/^TIDAL_ACCESS_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  sed -i '' '/^TIDAL_REFRESH_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  sed -i '' '/^TIDAL_USER_ID=/d' "$ENV_FILE" 2>/dev/null || true
  sed -i '' '/^TIDAL_CLIENT_ID=/d' "$ENV_FILE" 2>/dev/null || true
  echo "TIDAL_ACCESS_TOKEN=$access_token" >> "$ENV_FILE"
  [[ -n "$refresh_token" ]] && echo "TIDAL_REFRESH_TOKEN=$refresh_token" >> "$ENV_FILE"
  [[ -n "$user_id" ]] && echo "TIDAL_USER_ID=$user_id" >> "$ENV_FILE"
  echo "TIDAL_CLIENT_ID=${TIDAL_CLIENT_ID}" >> "$ENV_FILE"

  echo "Token 已儲存"
  [[ -n "$user_id" ]] && echo "User ID: $user_id"
}

cmd_refresh() {
  local refresh_token="${TIDAL_REFRESH_TOKEN:-}"
  if [[ -z "$refresh_token" ]]; then
    echo "無 refresh token，請重新執行: music-tidal.sh auth"
    exit 1
  fi

  local token_resp
  token_resp=$(curl -sf -X POST "https://auth.tidal.com/v1/oauth2/token" \
    -d "client_id=${TIDAL_CLIENT_ID}&client_secret=${TIDAL_CLIENT_ID}&refresh_token=${refresh_token}&grant_type=refresh_token&scope=r_usr+w_usr+offline_access") || { echo "Token refresh 失敗"; exit 1; }

  local access_token new_refresh
  access_token=$(echo "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
  new_refresh=$(echo "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('refresh_token',''))")

  sed -i '' '/^TIDAL_ACCESS_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  echo "TIDAL_ACCESS_TOKEN=$access_token" >> "$ENV_FILE"
  if [[ -n "$new_refresh" ]]; then
    sed -i '' '/^TIDAL_REFRESH_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
    echo "TIDAL_REFRESH_TOKEN=$new_refresh" >> "$ENV_FILE"
  fi

  TIDAL_TOKEN="$access_token"
  echo "Token 已刷新"
}

require_auth() {
  if [[ -z "$TIDAL_TOKEN" ]]; then
    echo "TIDAL token 未設定。請執行: music-tidal.sh auth"
    exit 1
  fi

  # Auto-refresh if token expires within 10 minutes
  local exp
  exp=$(echo "$TIDAL_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('exp',0))" 2>/dev/null || echo 0)
  local now
  now=$(date +%s)
  if [[ $((exp - now)) -lt 600 ]] && [[ -n "${TIDAL_REFRESH_TOKEN:-}" ]]; then
    echo "Token 即將過期，自動 refresh..."
    cmd_refresh
  elif [[ $((exp - now)) -lt 0 ]]; then
    echo "Token 已過期。有 refresh token 請執行: music-tidal.sh refresh，否則重新 auth"
    exit 1
  fi
}

cmd_search() {
  require_auth
  local query="$1"
  if [[ -z "$query" ]]; then
    echo "Usage: music-tidal.sh search \"query\""
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local url="$TIDAL_API/search/tracks?query=${encoded_query}&limit=10&countryCode=$TIDAL_COUNTRY"

  local response
  response=$(curl -sf \
    -H "Authorization: Bearer $TIDAL_TOKEN" \
    -H "X-Tidal-Token: $TIDAL_CLIENT_ID" \
    "$url") || { echo "API 請求失敗（token 可能過期）"; exit 1; }

  local count
  count=$(echo "$response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len(d.get('items',[])))
" 2>/dev/null || echo 0)

  if [[ "$count" -eq 0 ]]; then
    echo "找不到「$query」的結果"
    exit 0
  fi

  echo "TIDAL 搜尋結果：$query"
  echo ""
  echo "$response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i,t in enumerate(d.get('items',[]),1):
    name=t.get('title','?')
    artist=', '.join(a.get('name','') for a in t.get('artists',[]))
    album=t.get('album',{}).get('title','?')
    tid=t.get('id','?')
    quality='Hi-Res' if t.get('audioModes',[''])[0]=='SONY_360RA' else ('MQA' if t.get('audioQuality','')=='HI_RES' else t.get('audioQuality',''))
    print(f'{i}. {name}')
    print(f'   {artist} — {album}')
    print(f'   ID: {tid}  品質: {quality}')
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
    echo "Usage: music-tidal.sh play \"query\" [--name \"書房\"]"
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local url="$TIDAL_API/search/tracks?query=${encoded_query}&limit=1&countryCode=$TIDAL_COUNTRY"

  local response
  response=$(curl -sf \
    -H "Authorization: Bearer $TIDAL_TOKEN" \
    -H "X-Tidal-Token: $TIDAL_CLIENT_ID" \
    "$url") || { echo "API 請求失敗"; exit 1; }

  local track_id display_name display_artist uri meta
  local parsed
  parsed=$(echo "$response" | python3 -c "
import json,sys,urllib.parse,xml.sax.saxutils as sx

d=json.load(sys.stdin)
items=d.get('items',[])
if not items:
    print('__NOTFOUND__')
    sys.exit(0)

t=items[0]
track_id=str(t.get('id','')).strip()
if not track_id:
    print('__NOTFOUND__')
    sys.exit(0)

title=t.get('title') or 'Unknown Title'
artists=t.get('artists') or []
artist=', '.join(a.get('name','') for a in artists if a.get('name')) or 'Unknown Artist'
album=(t.get('album') or {}).get('title') or 'Unknown Album'
track_no=str(t.get('trackNumber') or 0)
cover=(t.get('album') or {}).get('cover') or ''
art=''
if cover:
    art='https://resources.tidal.com/images/{}/640x640.jpg'.format(cover.replace('-', '/'))

uri=f'x-sonos-http:track%2f{track_id}.flac?sid=174&flags=8232&sn=3'
res=uri

title_x=sx.escape(title)
artist_x=sx.escape(artist)
album_x=sx.escape(album)
art_x=sx.escape(art)
res_x=sx.escape(res)

meta=(
    '<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" '
    'xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" '
    'xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" '
    'xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">'
    f'<item id=\"00030020track%2f{track_id}\" parentID=\"\" restricted=\"true\">'
    f'<dc:title>{title_x}</dc:title>'
    f'<dc:creator>{artist_x}</dc:creator>'
    f'<upnp:artist>{artist_x}</upnp:artist>'
    f'<upnp:album>{album_x}</upnp:album>'
    f'<upnp:albumArtURI>{art_x}</upnp:albumArtURI>'
    f'<upnp:originalTrackNumber>{track_no}</upnp:originalTrackNumber>'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    f'<res protocolInfo=\"sonos.com-http:*:audio/flac:*\">{res_x}</res>'
    '<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON44551_X_#Svc44551-0-Token</desc>'
    '</item></DIDL-Lite>'
)

print(track_id)
print(title)
print(artist)
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
  uri=$(echo "$parsed" | sed -n '4p')
  meta=$(echo "$parsed" | sed -n '5p')

  echo "正在播放：$display_name — $display_artist"
  echo "URI: $uri"
  echo "喇叭: $speaker"
  echo ""

  # Use UPnP SetAVTransportURI + Play (sonos open only supports Spotify)
  local speaker_ip
  speaker_ip=$("$SONOS" discover --format json 2>/dev/null | python3 -c "
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
" 2>&1 || echo "播放失敗"
}

CMD="${1:-}"
shift || true

case "$CMD" in
  auth)    cmd_auth ;;
  refresh) cmd_refresh ;;
  search)  cmd_search "${1:-}" ;;
  play)    cmd_play "$@" ;;
  *)
    echo "Usage: music-tidal.sh <auth|refresh|search|play>"
    echo "  auth              設定 TIDAL token（需瀏覽器）"
    echo "  refresh           用 refresh token 更新 access token"
    echo "  search \"query\"    搜尋曲目"
    echo "  play \"query\"      播放第一個結果 [--name 喇叭名稱]"
    exit 1
    ;;
esac
