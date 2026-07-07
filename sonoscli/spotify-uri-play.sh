#!/usr/bin/env bash
# spotify-uri-play.sh — Spotify URI 解析與分組播放輔助腳本
# Usage: spotify-uri-play.sh [OPTIONS] <uri-or-link> [uri2 uri3 ...]
#
# OPTIONS:
#   --room <name>     Target speaker/room name (required)
#   --ip <ip>         Target speaker IP (alternative to --room)
#   --party           Join all speakers to this room before playing
#   --search <query>  Search Spotify and play first result
#   --enqueue-only    Add to queue without starting playback
#   --debug           Enable debug output
#   -h, --help        Show this help

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
ROOM=""
SPEAKER_IP=""
PARTY_MODE=false
ENQUEUE_ONLY=false
SEARCH_QUERY=""
DEBUG=false
URIS=()

# ── helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[spotify-uri-play] $*" >&2; }
dbg()  { $DEBUG && echo "[DEBUG] $*" >&2 || true; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
  grep '^#' "$0" | sed 's/^# \{0,2\}//' | head -20
  exit 0
}

# ── Spotify URI normaliser ───────────────────────────────────────────────────
# Accepts:
#   spotify:track:XXXX
#   spotify:album:XXXX
#   spotify:playlist:XXXX
#   https://open.spotify.com/track/XXXX
#   https://open.spotify.com/track/XXXX?si=...
normalise_uri() {
  local input="$1"

  # Already a spotify: URI
  if [[ "$input" =~ ^spotify:(track|album|playlist|artist|show|episode):[A-Za-z0-9]+ ]]; then
    echo "$input"
    return 0
  fi

  # HTTPS share link → extract type and ID
  if [[ "$input" =~ ^https?://open\.spotify\.com/([a-z]+)/([A-Za-z0-9]+) ]]; then
    local kind="${BASH_REMATCH[1]}"
    local id="${BASH_REMATCH[2]}"
    echo "spotify:${kind}:${id}"
    return 0
  fi

  # bare ID with type prefix hint (e.g. track:XXXX)
  if [[ "$input" =~ ^(track|album|playlist|show|episode):([A-Za-z0-9]+)$ ]]; then
    echo "spotify:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    return 0
  fi

  die "Cannot parse Spotify URI/link: $input"
}

# ── speaker target flags ─────────────────────────────────────────────────────
target_flags() {
  if [[ -n "$SPEAKER_IP" ]]; then
    echo "--ip $SPEAKER_IP"
  elif [[ -n "$ROOM" ]]; then
    echo "--name $ROOM"
  else
    die "Specify --room <name> or --ip <ip>"
  fi
}

# ── arg parse ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --room)       ROOM="$2"; shift 2 ;;
    --ip)         SPEAKER_IP="$2"; shift 2 ;;
    --party)      PARTY_MODE=true; shift ;;
    --enqueue-only) ENQUEUE_ONLY=true; shift ;;
    --search)     SEARCH_QUERY="$2"; shift 2 ;;
    --debug)      DEBUG=true; shift ;;
    -h|--help)    usage ;;
    --)           shift; URIS+=("$@"); break ;;
    -*)           die "Unknown option: $1" ;;
    *)            URIS+=("$1"); shift ;;
  esac
done

# ── validate ─────────────────────────────────────────────────────────────────
[[ -z "$ROOM" && -z "$SPEAKER_IP" ]] && die "Must specify --room <name> or --ip <ip>"
[[ ${#URIS[@]} -eq 0 && -z "$SEARCH_QUERY" ]] && die "Must provide at least one Spotify URI/link or --search <query>"

# ── party mode: group all rooms ───────────────────────────────────────────────
if $PARTY_MODE; then
  target=$(target_flags)
  log "Party mode: joining all speakers to $ROOM..."
  # shellcheck disable=SC2086
  sonos group party $target
fi

# ── search mode ──────────────────────────────────────────────────────────────
if [[ -n "$SEARCH_QUERY" ]]; then
  target=$(target_flags)
  log "Searching Spotify: $SEARCH_QUERY"
  if $ENQUEUE_ONLY; then
    # shellcheck disable=SC2086
    sonos search spotify "$SEARCH_QUERY" --enqueue $target
  else
    # shellcheck disable=SC2086
    sonos search spotify "$SEARCH_QUERY" --open $target
  fi
  exit 0
fi

# ── normalise all URIs ───────────────────────────────────────────────────────
NORMALISED=()
for raw in "${URIS[@]}"; do
  uri=$(normalise_uri "$raw")
  dbg "Normalised: $raw → $uri"
  NORMALISED+=("$uri")
done

# ── play / enqueue ───────────────────────────────────────────────────────────
target=$(target_flags)
first=true

for uri in "${NORMALISED[@]}"; do
  log "$(if $ENQUEUE_ONLY; then echo 'Enqueue'; else echo 'Play'; fi): $uri → ${ROOM:-$SPEAKER_IP}"

  if $ENQUEUE_ONLY; then
    # shellcheck disable=SC2086
    sonos enqueue "$uri" $target
  else
    if $first; then
      # First URI: open (enqueue + start playback)
      # shellcheck disable=SC2086
      sonos open "$uri" $target
      first=false
    else
      # Subsequent URIs: enqueue only (don't interrupt playback)
      # shellcheck disable=SC2086
      sonos enqueue "$uri" $target
    fi
  fi
done

log "Done."
