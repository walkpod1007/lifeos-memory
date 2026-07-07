#!/usr/bin/env bash
# Version: 1.0
# Last modified: 2026-03-16
# Status: active
# Level: B
# music-apple.sh — Apple Music search + play + browse via Sonos UPnP
# Usage:
#   music-apple.sh auth
#   music-apple.sh search "query"
#   music-apple.sh play "query" [--name "書房"]
#   music-apple.sh recommend              — 列出個人推薦播放清單
#   music-apple.sh playlist <playlist_id> [--name "書房"]  — 播放指定播放清單

set -euo pipefail

ENV_FILE="$HOME/.claude/.env"
DEFAULT_SPEAKER="書房"
SONOS="/opt/homebrew/bin/sonos"

# Load tokens
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

DEV_TOKEN="${APPLE_MUSIC_DEV_TOKEN:-}"
USER_TOKEN="${APPLE_MUSIC_USER_TOKEN:-}"

require_auth() {
  if [[ -z "$DEV_TOKEN" || -z "$USER_TOKEN" ]]; then
    echo "Apple Music tokens not configured. Run: music-apple.sh auth"
    exit 1
  fi
}

apple_api() {
  local url="$1"
  curl -sf \
    -H "Authorization: Bearer $DEV_TOKEN" \
    -H "Music-User-Token: $USER_TOKEN" \
    -H "Origin: https://music.apple.com" \
    -H "Referer: https://music.apple.com/" \
    "$url"
}

get_speaker_ip() {
  local speaker="$1"
  "$SONOS" discover --format json 2>/dev/null | python3 -c "
import json,sys
devs=json.load(sys.stdin)
for d in devs:
    if d.get('name','')=='$speaker':
        print(d['ip']); break
" 2>/dev/null
}

play_track_on_sonos() {
  local track_id="$1" title="$2" speaker_ip="$3"
  local uri="x-sonos-http:song%3A${track_id}.mp4?sid=204&flags=8232&sn=0"
  local safe_title
  safe_title=$(echo "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  local meta="<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"10032020song%3a${track_id}\" parentID=\"\" restricted=\"true\"><dc:title>${safe_title}</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON52231_</desc></item></DIDL-Lite>"
  python3 -c "
import soco
s=soco.SoCo('${speaker_ip}')
s.avTransport.SetAVTransportURI([('InstanceID',0),('CurrentURI','${uri}'),('CurrentURIMetaData','''${meta}''')])
s.play()
" 2>&1
}

enqueue_track_on_sonos() {
  local track_id="$1" title="$2" speaker_ip="$3"
  local uri="x-sonos-http:song%3A${track_id}.mp4?sid=204&flags=8232&sn=0"
  local safe_title
  safe_title=$(echo "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  local meta="<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"10032020song%3a${track_id}\" parentID=\"\" restricted=\"true\"><dc:title>${safe_title}</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON52231_</desc></item></DIDL-Lite>"
  python3 -c "
import soco
s=soco.SoCo('${speaker_ip}')
s.avTransport.AddURIToQueue([('InstanceID',0),('EnqueuedURI','${uri}'),('EnqueuedURIMetaData','''${meta}'''),('DesiredFirstTrackNumberEnqueued',0),('EnqueueAsNext',0)])
" 2>&1
}

cmd_auth() {
  echo "=== Apple Music Token 設定 ==="
  echo ""
  echo "步驟 1：在 Chrome/Safari 開啟 https://music.apple.com 並登入"
  echo "步驟 2：F12 開開發者工具 → Console"
  echo "步驟 3：貼上 MusicKit.getInstance().developerToken"
  echo "步驟 4：貼上 MusicKit.getInstance().musicUserToken"
  echo ""
  read -rp "請貼上 developerToken: " dev_token
  read -rp "請貼上 musicUserToken: " user_token

  if [[ -z "$dev_token" || -z "$user_token" ]]; then
    echo "Token 不可為空"
    exit 1
  fi

  touch "$ENV_FILE"
  sed -i '' '/^APPLE_MUSIC_DEV_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  sed -i '' '/^APPLE_MUSIC_USER_TOKEN=/d' "$ENV_FILE" 2>/dev/null || true
  echo "APPLE_MUSIC_DEV_TOKEN=$dev_token" >> "$ENV_FILE"
  echo "APPLE_MUSIC_USER_TOKEN=$user_token" >> "$ENV_FILE"
  echo "Token 已儲存"
}

cmd_search() {
  require_auth
  local query="$1"
  if [[ -z "$query" ]]; then
    echo "Usage: music-apple.sh search \"query\""
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local response
  response=$(apple_api "https://api.music.apple.com/v1/catalog/tw/search?term=${encoded_query}&types=songs&limit=10") \
    || { echo "API 請求失敗（token 可能過期）"; exit 1; }

  echo "$response" | python3 -c "
import json,sys
data=json.load(sys.stdin)
songs=data.get('results',{}).get('songs',{}).get('data',[])
if not songs: print('找不到結果'); sys.exit()
for i,s in enumerate(songs,1):
    a=s['attributes']
    print(f\"{i}. {a['name']}\")
    print(f\"   {a['artistName']} — {a['albumName']}\")
    print(f\"   ID: {s['id']}\")
    print()
"
}

cmd_play() {
  require_auth
  local query="" speaker="$DEFAULT_SPEAKER"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) speaker="$2"; shift 2 ;;
      *) query="$1"; shift ;;
    esac
  done

  if [[ -z "$query" ]]; then
    echo "Usage: music-apple.sh play \"query\" [--name 喇叭]"
    exit 1
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

  local response
  response=$(apple_api "https://api.music.apple.com/v1/catalog/tw/search?term=${encoded_query}&types=songs&limit=1") \
    || { echo "API 請求失敗"; exit 1; }

  local track_info
  track_info=$(echo "$response" | python3 -c "
import json,sys
data=json.load(sys.stdin)
songs=data.get('results',{}).get('songs',{}).get('data',[])
if not songs: print('NOTFOUND|||'); sys.exit()
s=songs[0]; a=s['attributes']
print(f\"{s['id']}|||{a['name']}|||{a['artistName']}\")
")

  local track_id display_name display_artist
  IFS='|||' read -r track_id _ display_name _ display_artist <<< "$track_info"

  if [[ "$track_id" == "NOTFOUND" || -z "$track_id" ]]; then
    echo "找不到「$query」"; exit 1
  fi

  local speaker_ip
  speaker_ip=$(get_speaker_ip "$speaker")
  if [[ -z "$speaker_ip" ]]; then echo "找不到喇叭: $speaker"; exit 1; fi

  echo "正在播放：$display_name — $display_artist"
  echo "喇叭: $speaker"
  play_track_on_sonos "$track_id" "$display_name" "$speaker_ip" && echo "播放成功" || echo "播放失敗"
}

cmd_recommend() {
  require_auth
  local response
  response=$(apple_api "https://api.music.apple.com/v1/me/recommendations") \
    || { echo "API 請求失敗"; exit 1; }

  echo "$response" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for group in data.get('data',[]):
    title=group.get('attributes',{}).get('title',{}).get('stringForDisplay','N/A')
    items=group.get('relationships',{}).get('contents',{}).get('data',[])
    playlists=[i for i in items if i.get('type')=='playlists']
    if not playlists: continue
    print(f'【{title}】')
    for p in playlists[:3]:
        a=p.get('attributes',{})
        name=a.get('name','?')
        pid=p.get('id','')
        desc=(a.get('description',{}) or {}).get('short','')[:40]
        art=a.get('artwork',{}).get('url','').replace('{w}','300').replace('{h}','300')
        print(f'  {name}')
        print(f'    id={pid}')
        if desc: print(f'    {desc}')
        if art: print(f'    art={art}')
        print()
"
}

cmd_playlist() {
  require_auth
  local playlist_id="" speaker="$DEFAULT_SPEAKER" limit=25
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) speaker="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) playlist_id="$1"; shift ;;
    esac
  done

  if [[ -z "$playlist_id" ]]; then
    echo "Usage: music-apple.sh playlist <playlist_id> [--name 喇叭] [--limit 25]"
    exit 1
  fi

  # Fetch playlist info + tracks
  local response
  response=$(apple_api "https://api.music.apple.com/v1/catalog/tw/playlists/${playlist_id}?include=tracks") 2>/dev/null
  # If catalog fails, try personal library endpoint
  if [[ -z "$response" ]]; then
    response=$(apple_api "https://api.music.apple.com/v1/me/library/playlists/${playlist_id}?include=tracks")
  fi
  if [[ -z "$response" ]]; then
    # Try personalized playlist (pl.pm-*)
    response=$(apple_api "https://api.music.apple.com/v1/me/recommendations?limit=25") || { echo "API 請求失敗"; exit 1; }
    # Find the playlist in recommendations
    local playlist_data
    playlist_data=$(echo "$response" | python3 -c "
import json,sys
data=json.load(sys.stdin)
pid='$playlist_id'
for group in data.get('data',[]):
    for item in group.get('relationships',{}).get('contents',{}).get('data',[]):
        if item.get('id')==pid:
            print(json.dumps(item))
            sys.exit()
print('')
")
    if [[ -z "$playlist_data" ]]; then
      echo "找不到播放清單: $playlist_id"; exit 1
    fi
    # Get tracks from the playlist href
    local href
    href=$(echo "$playlist_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('href',''))")
    response=$(apple_api "https://api.music.apple.com${href}?include=tracks") || { echo "API 請求失敗"; exit 1; }
  fi

  # Parse tracks
  local tracks_json
  tracks_json=$(echo "$response" | python3 -c "
import json,sys
data=json.load(sys.stdin)
items=data.get('data',[])
if not items: print('[]'); sys.exit()
pl=items[0]
name=pl.get('attributes',{}).get('name','?')
tracks=pl.get('relationships',{}).get('tracks',{}).get('data',[])
result=[]
for t in tracks[:${limit}]:
    a=t.get('attributes',{})
    catalog_id=t.get('id','')
    # For library tracks, playParams has catalogId
    pp=a.get('playParams',{})
    cid=pp.get('catalogId') or pp.get('id') or catalog_id
    result.append({'id':str(cid),'title':a.get('name','?'),'artist':a.get('artistName','?')})
print(json.dumps({'name':name,'tracks':result}))
")

  local pl_name
  pl_name=$(echo "$tracks_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  local track_count
  track_count=$(echo "$tracks_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['tracks']))")

  if [[ "$track_count" -eq 0 ]]; then
    echo "播放清單是空的"; exit 1
  fi

  local speaker_ip
  speaker_ip=$(get_speaker_ip "$speaker")
  if [[ -z "$speaker_ip" ]]; then echo "找不到喇叭: $speaker"; exit 1; fi

  echo "播放清單：$pl_name（$track_count 首）"
  echo "喇叭: $speaker"

  # Clear queue, add all tracks, play
  python3 -c "
import soco, json

speaker = soco.SoCo('${speaker_ip}')
speaker.clear_queue()

data = json.loads('''${tracks_json}''')
tracks = data['tracks']
added = 0
for t in tracks:
    tid = t['id']
    title = t['title'].replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('\"','&quot;')
    uri = f'x-sonos-http:song%3A{tid}.mp4?sid=204&flags=8232&sn=0'
    meta = f'<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"10032020song%3a{tid}\" parentID=\"\" restricted=\"true\"><dc:title>{title}</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON52231_</desc></item></DIDL-Lite>'
    try:
        speaker.avTransport.AddURIToQueue([('InstanceID',0),('EnqueuedURI',uri),('EnqueuedURIMetaData',meta),('DesiredFirstTrackNumberEnqueued',0),('EnqueueAsNext',0)])
        added += 1
    except: pass

if added:
    speaker.play_from_queue(0)
    print(f'已加入 {added} 首，開始播放')
else:
    print('無法加入任何曲目')
" 2>&1
}

CMD="${1:-}"
shift || true

case "$CMD" in
  auth)      cmd_auth ;;
  search)    cmd_search "${1:-}" ;;
  play)      cmd_play "$@" ;;
  recommend) cmd_recommend ;;
  playlist)  cmd_playlist "$@" ;;
  *)
    echo "Usage: music-apple.sh <auth|search|play|recommend|playlist>"
    echo "  auth                     設定 Apple Music token"
    echo "  search \"query\"           搜尋曲目"
    echo "  play \"query\"             播放第一個結果 [--name 喇叭]"
    echo "  recommend                列出個人推薦播放清單"
    echo "  playlist <id>            播放指定播放清單 [--name 喇叭] [--limit 25]"
    exit 1
    ;;
esac
