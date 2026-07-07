import http.server
import socketserver
import json
import subprocess
import urllib.request
import urllib.parse
import os

PORT = 18888
DEVICE_NAME = "書房"
QUEUE_PREVIEW_COUNT = 4

# Cache to avoid hitting iTunes API every 3 seconds
_art_cache = {}
# Queue preview cache: only refresh on track change (or stale fallback)
_queue_cache = {
    'track': None,
    'data': {'currentTrack': None, 'totalMatches': 0, 'items': []},
}

def get_hires_art(artist, title):
    key = f"{artist}|{title}"
    if key in _art_cache:
        return _art_cache[key]
    try:
        q = urllib.parse.quote(f"{artist} {title}")
        req = urllib.request.Request(
            f"https://itunes.apple.com/search?term={q}&media=music&limit=1",
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            itunes = json.loads(resp.read())
            if itunes.get('resultCount', 0) > 0:
                art_url = itunes['results'][0].get('artworkUrl100', '')
                hires = art_url.replace('100x100bb', '1200x1200bb')
                _art_cache[key] = hires
                return hires
    except:
        pass
    _art_cache[key] = None
    return None

def run_sonos_json(args):
    result = subprocess.run(
        ['/opt/homebrew/bin/sonos', *args, '--name', DEVICE_NAME, '--format', 'json'],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    )
    return json.loads(result.stdout)

def sonos_album_art_url(device_ip, album_art_uri):
    album_art_uri = (album_art_uri or '').strip()
    if not album_art_uri:
        return ''
    if album_art_uri.startswith(('http://', 'https://')):
        return album_art_uri
    if album_art_uri.startswith('/') and device_ip:
        return f'http://{device_ip}:1400{album_art_uri}'
    return album_art_uri

def normalize_queue_item(entry, device_ip):
    item = entry.get('item', {})
    return {
        'position': entry.get('position'),
        'title': item.get('title', ''),
        'artist': item.get('artist', ''),
        'album': item.get('album', ''),
        'albumArtURL': sonos_album_art_url(device_ip, item.get('albumArtURI')),
    }

def detect_source_label(status):
    uri = (status.get('position', {}) or {}).get('TrackURI', '') or ''
    s = uri.lower()
    if 'spotify' in s:
        return 'Spotify'
    if 'qobuz' in s or 'sid=31' in s:
        return 'Qobuz'
    if 'tidal' in s or 'sid=174' in s:
        return 'TIDAL'
    if 'apple' in s or 'sid=204' in s:
        return 'Apple Music'
    return 'Unknown'

def hydrate_now_playing_from_queue(status):
    """Fill missing nowPlaying fields for services that return sparse transport metadata (e.g. TIDAL)."""
    np = status.get('nowPlaying', {}) or {}
    title = (np.get('title') or '').strip()
    artist = (np.get('artist') or '').strip()
    album = (np.get('album') or '').strip()
    if title and artist:
        return

    device_ip = status.get('device', {}).get('ip', '')
    track_num_raw = status.get('position', {}).get('Track', '')
    try:
        current_track = int(track_num_raw)
    except (TypeError, ValueError):
        return

    try:
        page = run_sonos_json([
            'queue', 'list',
            '--start', str(max(current_track - 1, 0)),
            '--limit', '1',
        ])
    except Exception:
        return

    items = page.get('items', []) or []
    if not items:
        return
    item = (items[0] or {}).get('item', {}) or {}

    if not title:
        np['title'] = item.get('title', '')
    if not artist:
        np['artist'] = item.get('artist', '')
    if not album:
        np['album'] = item.get('album', '')

    art = sonos_album_art_url(device_ip, item.get('albumArtURI', ''))
    if art:
        status['albumArtURL'] = art

    status['nowPlaying'] = np


def build_queue_preview(status):
    device_ip = status.get('device', {}).get('ip', '')
    track_num_raw = status.get('position', {}).get('Track', '')
    try:
        current_track = int(track_num_raw)
    except (TypeError, ValueError):
        return {
            'currentTrack': None,
            'totalMatches': 0,
            'items': [],
        }

    # 只在換歌時更新 Up Next，避免每 3 秒輪詢造成閃爍
    if _queue_cache.get('track') == current_track:
        return _queue_cache.get('data', {
            'currentTrack': current_track,
            'totalMatches': 0,
            'items': [],
        })

    queue_page = run_sonos_json([
        'queue', 'list',
        '--start', str(max(current_track - 1, 0)),
        '--limit', str(QUEUE_PREVIEW_COUNT + 1),
    ])
    queue_items = queue_page.get('items', [])
    upcoming = [
        normalize_queue_item(entry, device_ip)
        for entry in queue_items
        if entry.get('position', 0) > current_track
    ][:QUEUE_PREVIEW_COUNT]

    data = {
        'currentTrack': current_track,
        'totalMatches': queue_page.get('totalMatches', 0),
        'items': upcoming,
    }
    _queue_cache['track'] = current_track
    _queue_cache['data'] = data
    return data

class SonosStatusHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress request logs

    def do_GET(self):
        if self.path.startswith('/assets/'):
            asset_name = self.path.split('/assets/', 1)[1].split('?', 1)[0]
            asset_path = os.path.join(os.path.dirname(__file__), 'assets', os.path.basename(asset_name))
            if os.path.isfile(asset_path):
                self.send_response(200)
                if asset_path.endswith('.png'):
                    self.send_header('Content-type', 'image/png')
                elif asset_path.endswith('.svg'):
                    self.send_header('Content-type', 'image/svg+xml')
                else:
                    self.send_header('Content-type', 'application/octet-stream')
                self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
                self.send_header('Pragma', 'no-cache')
                self.send_header('Expires', '0')
                self.end_headers()
                with open(asset_path, 'rb') as f:
                    self.wfile.write(f.read())
                return
            self.send_response(404)
            self.end_headers()
            return
        if self.path == '/api/status':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Expires', '0')
            self.end_headers()
            try:
                status = run_sonos_json(['status'])
                hydrate_now_playing_from_queue(status)
                np = status.get('nowPlaying', {})
                artist = np.get('artist', '')
                title = np.get('title', '')
                if artist and title:
                    hires = get_hires_art(artist, title)
                    if hires:
                        status['hiresArtURL'] = hires
                status['sourceLabel'] = detect_source_label(status)
                try:
                    status['queuePreview'] = build_queue_preview(status)
                except Exception:
                    status['queuePreview'] = {
                        'currentTrack': None,
                        'totalMatches': 0,
                        'items': [],
                    }
                self.wfile.write(json.dumps(status).encode())
            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode())
        elif self.path == '/gallery':
            self.send_response(200)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Lobster Vertical Art Gallery</title>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                    body { font-family: serif; background: #000; color: #fff; margin: 0; overflow: hidden; height: 100vh; width: 100vw; }
                    #art-container { position: relative; width: 100vw; height: 100vh; display: flex; align-items: center; justify-content: center; background: #000; }
                    #art-image { width: 100%; height: 100%; object-fit: cover; transition: opacity 2s ease-in-out; opacity: 0; }
                    #info-box { position: absolute; bottom: 8%; left: 10%; right: 10%; background: rgba(0,0,0,0.4); padding: 40px; border-radius: 4px; backdrop-filter: blur(20px); border-bottom: 8px solid #fff; text-align: left; }
                    #title { font-size: 4rem; font-weight: bold; margin: 0; line-height: 1.1; text-shadow: 0 5px 15px rgba(0,0,0,0.8); }
                    #artist { font-size: 2.5rem; color: #eee; margin-top: 20px; }
                    #museum { font-size: 1.2rem; color: #aaa; text-transform: uppercase; margin-top: 30px; letter-spacing: 5px; }
                </style>
                <script>
                    // 篩選過的「直向 Portrait」高品質作品
                    const artworks = [
                        { title: "Irises", artist: "Vincent van Gogh", url: "https://images.metmuseum.org/CRDImages/ep/original/DP346474.jpg", museum: "The Met" },
                        { title: "Self-Portrait with a Straw Hat", artist: "Vincent van Gogh", url: "https://images.metmuseum.org/CRDImages/ep/original/DT1502_cropped2.jpg", museum: "The Met" },
                        { title: "Madame Joseph-Michel Ginoux", artist: "Vincent van Gogh", url: "https://images.metmuseum.org/CRDImages/ep/original/DT1396.jpg", museum: "The Met" },
                        { title: "Woman with a Parrot", artist: "Gustave Courbet", url: "https://images.metmuseum.org/CRDImages/ep/original/DT1911.jpg", museum: "The Met" },
                        { title: "The Flowering Orchard", artist: "Vincent van Gogh", url: "https://images.metmuseum.org/CRDImages/ep/original/DP346472.jpg", museum: "The Met" },
                        { title: "Young Woman with a Water Pitcher", artist: "Johannes Vermeer", url: "https://images.metmuseum.org/CRDImages/ep/original/DP355325.jpg", museum: "The Met" }
                    ];

                    async function nextArt() {
                        const art = artworks[Math.floor(Math.random() * artworks.length)];
                        const img = document.getElementById('art-image');
                        
                        img.style.opacity = 0;
                        
                        setTimeout(() => {
                            img.src = art.url;
                            document.getElementById('title').innerText = art.title;
                            document.getElementById('artist').innerText = art.artist;
                            document.getElementById('museum').innerText = art.museum;
                            
                            img.onload = () => {
                                img.style.opacity = 1;
                            };
                        }, 2000);
                    }

                    setInterval(nextArt, 60000); // 每分鐘換一張
                    window.onload = nextArt;
                </script>
            </head>
            <body>
                <div id="art-container">
                    <img id="art-image" src="">
                    <div id="info-box">
                        <div id="title">Gallery</div>
                        <div id="artist">Lobster Portrait Curation</div>
                        <div id="museum">Fine Art Collection</div>
                    </div>
                </div>
            </body>
            </html>
            """
            self.wfile.write(html.encode())
        elif self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Expires', '0')
            self.end_headers()
            html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Sonos Now Playing</title>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@300;400;800&family=Noto+Sans+TC:wght@300;400;800&family=Noto+Sans+JP:wght@300;400;800&display=swap">
                <style>
                    :root {
                        --bg: #000;
                        --panel: rgba(255,255,255,0.05);
                        --panel-border: rgba(255,255,255,0.08);
                        --text-dim: #999;
                        --text-faint: #666;
                        --text-muted: #555;
                        --pending-safe: 54px;
                        --art-size: min(82%, calc(100dvh - var(--pending-safe) - 360px), 760px);
                    }
                    * { box-sizing: border-box; }
                    body {
                        font-family: 'Noto Sans TC', 'Noto Sans KR', 'Noto Sans JP', -apple-system, 'Helvetica Neue', sans-serif;
                        background:
                            radial-gradient(circle at top, rgba(255,255,255,0.08), transparent 30%),
                            radial-gradient(circle at bottom left, rgba(255,255,255,0.06), transparent 26%),
                            var(--bg);
                        color: #fff;
                        margin: 0;
                        min-height: 100vh;
                        overflow: hidden;
                    }
                    #dashboard {
                        min-height: calc(100dvh - var(--pending-safe));
                        width: min(96vw, 1680px);
                        margin: 0 auto;
                        display: grid;
                        grid-template-columns: minmax(0, 1fr) minmax(300px, 34vw);
                        gap: clamp(24px, 3vw, 56px);
                        align-items: center;
                        justify-items: center;
                        padding: clamp(18px, 3vw, 42px);
                    }
                    #main-panel {
                        display: flex;
                        flex-direction: column;
                        align-items: center;
                        justify-content: center;
                        min-width: 0;
                        max-height: calc(100dvh - var(--pending-safe) - 24px);
                        padding-top: clamp(8px, 1.5vh, 18px);
                        padding-bottom: clamp(14px, 2.4vh, 28px);
                    }
                    #art {
                        width: var(--art-size);
                        height: var(--art-size);
                        min-width: 220px;
                        min-height: 220px;
                        max-width: 760px;
                        max-height: 760px;
                        aspect-ratio: 1 / 1;
                        border-radius: 20px;
                        background-size: cover;
                        background-position: center;
                        box-shadow: 0 20px 60px rgba(0,0,0,0.9);
                        opacity: 1;
                        transition: opacity 0.8s ease-in-out;
                    }
                    #info {
                        margin-top: clamp(8px, 2vh, 18px);
                        text-align: center;
                        width: min(80vw, 900px);
                    }
                    #title {
                        font-size: clamp(2.2rem, 5vmin, 5.2rem);
                        font-weight: 800;
                        margin: 0;
                        text-shadow: 0 2px 10px rgba(0,0,0,0.5);
                        letter-spacing: -0.02em;
                        line-height: 1.08;
                        display: -webkit-box;
                        -webkit-line-clamp: 2;
                        -webkit-box-orient: vertical;
                        overflow: hidden;
                    }
                    #artist {
                        font-size: clamp(1.3rem, 3.2vmin, 2.8rem);
                        color: var(--text-dim);
                        margin-top: 6px;
                        font-weight: 300;
                        white-space: nowrap;
                        overflow: hidden;
                        text-overflow: ellipsis;
                    }
                    #album {
                        font-size: clamp(0.95rem, 2.5vmin, 2rem);
                        color: var(--text-faint);
                        margin-top: 4px;
                        font-style: italic;
                        white-space: nowrap;
                        overflow: hidden;
                        text-overflow: ellipsis;
                    }
                    #source {
                        display: none;
                    }
                    .service-line {
                        --icon-box: 26px;
                        --label-size: 1.05rem;
                        margin: 10px auto 0;
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        gap: 8px;
                        padding: 6px 0;
                        border-radius: 999px;
                        background: transparent;
                        border: none;
                    }
                    .service-icon {
                        width: var(--icon-box);
                        height: var(--icon-box);
                        border-radius: 50%;
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        overflow: hidden;
                        color: #fff;
                        flex-shrink: 0;
                        position: relative;
                        top: -1px;
                    }
                    .service-line.tidal .service-icon {
                        width: 32px;
                        height: 18px;
                        border-radius: 4px;
                    }
                    .service-icon img {
                        width: 100%;
                        height: 100%;
                        object-fit: contain;
                        object-position: center center;
                        display: block;
                        transform: none;
                    }
                    .service-line.qobuz .service-icon img {
                        width: 82%;
                        height: 82%;
                        object-position: center center;
                    }
                    .service-icon svg {
                        width: 17px;
                        height: 17px;
                        display: block;
                        color: currentColor;
                    }
                    .service-label {
                        font-size: var(--label-size);
                        line-height: var(--icon-box);
                        letter-spacing: 0.01em;
                        color: #f5f5f5;
                        font-weight: 700;
                    }
                    .service-line.spotify .service-icon { background: transparent; color: #000; }
                    .service-line.qobuz .service-icon {
                        background: transparent;
                        color: #000;
                        border: none;
                        border-radius: 0;
                        overflow: visible;
                    }
                    .service-line.tidal .service-icon { background: #000; color: #fff; border-radius: 4px; }
                    .service-line.applemusic .service-icon { background: linear-gradient(180deg, #ff5e86 0%, #ff2d55 100%); color: #fff; }
                    .service-line.unknown .service-icon { background: #666; color: #fff; }
                    #progress-wrap {
                        width: min(40vmin, 520px, 82vw);
                    }
                    #progress-bar {
                        width: 100%;
                        height: 4px;
                        background: #333;
                        border-radius: 2px;
                        margin-top: clamp(20px, 3vh, 26px);
                        overflow: hidden;
                    }
                    #progress {
                        height: 100%;
                        background: #fff;
                        border-radius: 2px;
                        transition: width 3s linear;
                        width: 0%;
                    }
                    #time {
                        display: flex;
                        justify-content: space-between;
                        align-items: center;
                        width: 100%;
                        margin-top: 8px;
                        font-size: clamp(0.82rem, 1.8vmin, 1.2rem);
                        color: var(--text-muted);
                    }
                    #time-dur { text-align: right; }
                    #meta {
                        margin-top: clamp(10px, 2vh, 18px);
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        flex-wrap: wrap;
                        gap: 18px 28px;
                    }
                    .meta-chip {
                        font-size: clamp(0.9rem, 2vmin, 1.35rem);
                        color: var(--text-muted);
                        display: flex;
                        align-items: center;
                        gap: 10px;
                    }
                    .meta-chip .dot {
                        width: 8px;
                        height: 8px;
                        border-radius: 50%;
                        background: #1DB954;
                        display: inline-block;
                        animation: pulse 2s infinite;
                    }
                    #queue-panel {
                        align-self: stretch;
                        display: flex;
                        flex-direction: column;
                        justify-content: center;
                        min-width: 0;
                        padding: clamp(18px, 2.5vw, 30px);
                        border: 1px solid var(--panel-border);
                        border-radius: 28px;
                        background: var(--panel);
                        backdrop-filter: blur(22px);
                        box-shadow: 0 18px 50px rgba(0,0,0,0.35);
                    }
                    #queue-heading {
                        font-size: clamp(0.85rem, 1.4vmin, 1rem);
                        color: var(--text-muted);
                        text-transform: uppercase;
                        letter-spacing: 0.2em;
                    }
                    #queue-subheading {
                        margin-top: 8px;
                        font-size: clamp(1.15rem, 2.4vmin, 2rem);
                        font-weight: 800;
                    }
                    #queue-list {
                        margin-top: 22px;
                        display: flex;
                        flex-direction: column;
                        gap: 14px;
                    }
                    .queue-item {
                        display: grid;
                        grid-template-columns: 72px minmax(0, 1fr);
                        gap: 18px;
                        align-items: center;
                        padding: 12px 14px;
                        border-radius: 18px;
                        background: rgba(255,255,255,0.04);
                    }
                    .queue-thumb {
                        width: clamp(56px, 5.5vw, 80px);
                        aspect-ratio: 1 / 1;
                        border-radius: 14px;
                        background: rgba(255,255,255,0.06) center / cover no-repeat;
                        box-shadow: inset 0 0 0 1px rgba(255,255,255,0.05);
                    }
                    .queue-copy {
                        min-width: 0;
                        padding-left: 2px;
                    }
                    .queue-title {
                        font-size: clamp(1.1rem, 1.8vmin, 1.5rem);
                        font-weight: 700;
                        white-space: nowrap;
                        overflow: hidden;
                        text-overflow: ellipsis;
                    }
                    .queue-artist {
                        margin-top: 4px;
                        font-size: clamp(0.95rem, 1.4vmin, 1.15rem);
                        color: var(--text-dim);
                        white-space: nowrap;
                        overflow: hidden;
                        text-overflow: ellipsis;
                    }
                    .queue-empty {
                        padding: 18px 0 4px;
                        color: var(--text-faint);
                        font-size: clamp(0.95rem, 1.4vmin, 1.05rem);
                    }
                    @media (min-aspect-ratio: 16/9) {
                        :root { --art-size: min(74%, 56vh, 640px); }
                        #info { margin-top: 4px; }
                        #progress-bar { margin-top: 8px; }
                        #meta { margin-top: 4px; }
                        .meta-chip { font-size: clamp(0.78rem, 1.35vmin, 0.95rem); }
                    }
                    @media (max-aspect-ratio: 4/3) {
                        :root { --art-size: min(84%, 62vh, 700px); }
                        #dashboard { padding-top: 22px; }
                    }
                    @media (max-width: 1100px) {
                        :root { --pending-safe: 66px; }
                        body { overflow: auto; }
                        #dashboard {
                            width: min(94vw, 980px);
                            grid-template-columns: 1fr;
                            grid-template-rows: auto auto;
                            align-items: center;
                            justify-items: center;
                            align-content: center;
                            min-height: 100vh;
                        }
                        #main-panel {
                            padding-bottom: 8px;
                        }
                        #queue-panel {
                            width: min(94vw, 760px);
                            justify-content: flex-start;
                            padding: 14px;
                            border-radius: 18px;
                            overflow: hidden;
                        }
                        #queue-list {
                            margin-top: 12px;
                            display: grid;
                            grid-template-columns: repeat(2, minmax(0, 1fr));
                            gap: 10px;
                            overflow: hidden;
                            padding-bottom: 0;
                        }
                        .queue-item {
                            min-width: 0;
                            grid-template-columns: 52px minmax(0, 1fr);
                            gap: 10px;
                            padding: 9px;
                            border-radius: 12px;
                        }
                        .queue-thumb {
                            width: 52px;
                            border-radius: 10px;
                        }
                    }
                    @media (max-width: 640px) {
                        :root { --art-size: min(92vw, 420px); }
                        #dashboard {
                            padding: 16px;
                            gap: 18px;
                        }
                        #art {
                            border-radius: 18px;
                        }
                        #info {
                            width: 100%;
                        }
                        #progress-wrap {
                            width: min(92vw, 520px);
                        }
                        .queue-item {
                            grid-template-columns: 56px minmax(0, 1fr);
                            gap: 12px;
                            padding: 10px;
                        }
                        .queue-thumb {
                            width: 56px;
                            border-radius: 12px;
                        }
                    }
                    @media (max-width: 1100px) and (max-height: 980px) {
                        :root { --art-size: min(72vw, 50vh, 520px); }
                        #title { font-size: clamp(1.8rem, 4.4vmin, 3.8rem); }
                        #artist { font-size: clamp(1.05rem, 2.7vmin, 2rem); }
                        #album { font-size: clamp(0.82rem, 2vmin, 1.2rem); }
                        #progress-bar { margin-top: 8px; }
                        #meta { margin-top: 6px; }
                        .meta-chip { font-size: clamp(0.8rem, 1.5vmin, 1rem); }
                        #queue-panel { margin-top: 6px; }
                    }
                    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }
                </style>
                <script>
                    let __lastQueueKey = '';
                    let __lastNonEmptyQueue = [];
                    let __lastNonEmptyAt = 0;
                    let __lastNowPlayingKey = '';
                    let __lastSourceLabel = '';
                    let __lastMetaKey = '';
                    function parseTime(t) {
                        if (!t) return 0;
                        const parts = t.split(':').map(Number);
                        return parts[0]*3600 + parts[1]*60 + parts[2];
                    }
                    function fmtTime(t) {
                        if (!t) return '--:--';
                        const parts = t.split(':');
                        if (parts.length === 3 && parts[0] === '0') return parts[1] + ':' + parts[2];
                        return t;
                    }
                    function autoFitText() {
                        const titleEl = document.getElementById('title');
                        const artistEl = document.getElementById('artist');
                        const albumEl = document.getElementById('album');
                        const titleLen = (titleEl.innerText || '').trim().length;
                        const artistLen = (artistEl.innerText || '').trim().length;
                        const albumLen = (albumEl.innerText || '').trim().length;

                        if (titleLen > 54) titleEl.style.fontSize = 'clamp(1.35rem, 3vmin, 2.1rem)';
                        else if (titleLen > 40) titleEl.style.fontSize = 'clamp(1.6rem, 3.6vmin, 2.8rem)';
                        else if (titleLen > 28) titleEl.style.fontSize = 'clamp(1.9rem, 4.3vmin, 3.8rem)';
                        else titleEl.style.fontSize = 'clamp(2.2rem, 5vmin, 5.2rem)';

                        artistEl.style.fontSize = artistLen > 28
                            ? 'clamp(0.95rem, 2.1vmin, 1.5rem)'
                            : 'clamp(1.3rem, 3.2vmin, 2.8rem)';

                        albumEl.style.fontSize = albumLen > 36
                            ? 'clamp(0.78rem, 1.55vmin, 1.05rem)'
                            : 'clamp(0.95rem, 2.5vmin, 2rem)';
                    }
                    function sourceToClass(sourceLabel) {
                        const s = (sourceLabel || '').toLowerCase();
                        if (s.includes('spotify')) return 'spotify';
                        if (s.includes('qobuz')) return 'qobuz';
                        if (s.includes('tidal')) return 'tidal';
                        if (s.includes('apple')) return 'applemusic';
                        return 'unknown';
                    }
                    function sourceToIconImage(sourceLabel) {
                        const s = (sourceLabel || '').toLowerCase();
                        if (s.includes('spotify')) return '/assets/spotify.png?v=1';
                        if (s.includes('qobuz')) return '/assets/qobuz.png?v=1';
                        if (s.includes('tidal')) return '/assets/tidal.png?v=1';
                        if (s.includes('apple')) return '/assets/applemusic.png?v=1';
                        return '';
                    }
                    function sourceToIconSvg(sourceLabel) {
                        const s = (sourceLabel || '').toLowerCase();
                        if (s.includes('tidal')) {
                            return `<svg viewBox="0 0 24 16" aria-hidden="true"><path fill="#ffffff" d="M0 6l3-3 3 3-3 3-3-3zm6 0l3-3 3 3-3 3-3-3zm6 0l3-3 3 3-3 3-3-3zM6 12l3-3 3 3-3 3-3-3z"/></svg>`;
                        }
                        if (s.includes('qobuz')) {
                            return `<svg viewBox="0 0 64 64" aria-hidden="true"><circle cx="30" cy="30" r="26" fill="#ffffff"/><circle cx="30" cy="30" r="21" fill="#000000"/><circle cx="30" cy="30" r="11.5" fill="#ffffff"/><circle cx="30" cy="30" r="2.9" fill="#000000"/><path d="M39 39 L55 55" stroke="#ffffff" stroke-width="8" stroke-linecap="round"/></svg>`;
                        }
                        return '•';
                    }
                    function renderQueue(queuePreview) {
                        const queueList = document.getElementById('queue-list');
                        let items = queuePreview?.items || [];
                        const now = Date.now();

                        if (items.length) {
                            __lastNonEmptyQueue = items;
                            __lastNonEmptyAt = now;
                        } else if (__lastNonEmptyQueue.length && (now - __lastNonEmptyAt) < 30000) {
                            // Samsung TV 偶發 queue API 抖動：30 秒內沿用上一版，避免閃爍
                            items = __lastNonEmptyQueue;
                        }

                        const queueKey = JSON.stringify(items.map(i => [i.title || '', i.artist || '', i.albumArtURL || '']));
                        if (queueKey === __lastQueueKey) return;
                        __lastQueueKey = queueKey;

                        queueList.innerHTML = '';
                        if (!items.length) {
                            const empty = document.createElement('div');
                            empty.className = 'queue-empty';
                            empty.innerText = 'Queue preview unavailable for this source.';
                            queueList.appendChild(empty);
                            return;
                        }
                        items.forEach((item) => {
                            const row = document.createElement('div');
                            row.className = 'queue-item';

                            const thumb = document.createElement('div');
                            thumb.className = 'queue-thumb';
                            if (item.albumArtURL) {
                                thumb.style.backgroundImage = `url('${item.albumArtURL}')`;
                            }

                            const copy = document.createElement('div');
                            copy.className = 'queue-copy';

                            const title = document.createElement('div');
                            title.className = 'queue-title';
                            title.innerText = item.title || item.album || item.artist || 'Unknown Track';

                            const artist = document.createElement('div');
                            artist.className = 'queue-artist';
                            artist.innerText = item.artist || item.album || '';

                            copy.appendChild(title);
                            copy.appendChild(artist);
                            row.appendChild(thumb);
                            row.appendChild(copy);
                            queueList.appendChild(row);
                        });
                    }
                    async function update() {
                        try {
                            const r = await fetch('/api/status');
                            const data = await r.json();
                            if (data.nowPlaying) {
                                const npTitle = data.nowPlaying.title || '';
                                const npArtist = data.nowPlaying.artist || '';
                                const npAlbum = data.nowPlaying.album || '';
                                const nowPlayingKey = `${npTitle}|${npArtist}|${npAlbum}`;
                                if (nowPlayingKey !== __lastNowPlayingKey) {
                                    document.getElementById('title').innerText = npTitle;
                                    document.getElementById('artist').innerText = npArtist;
                                    document.getElementById('album').innerText = npAlbum;
                                    autoFitText();
                                    __lastNowPlayingKey = nowPlayingKey;
                                }

                                const artUrl = data.hiresArtURL || data.albumArtURL;
                                const artEl = document.getElementById('art');
                                if (artUrl) {
                                    const newUrl = `url('${artUrl}')`;
                                    if (artEl.dataset.lastUrl !== newUrl) {
                                        artEl.style.opacity = 0;
                                        setTimeout(() => {
                                            artEl.style.backgroundImage = newUrl;
                                            artEl.dataset.lastUrl = newUrl;
                                            artEl.style.opacity = 1;
                                        }, 250);
                                    }
                                }

                                const serviceLine = document.getElementById('service-line');
                                const serviceIcon = document.getElementById('service-icon');
                                const serviceLabel = document.getElementById('service-label');
                                if (serviceLine && serviceIcon && serviceLabel) {
                                    const sourceLabel = data.sourceLabel || 'Unknown';
                                    if (sourceLabel !== __lastSourceLabel) {
                                        const cls = sourceToClass(sourceLabel);
                                        serviceLine.className = `service-line ${cls}`;
                                        serviceLine.title = sourceLabel;
                                        serviceLine.setAttribute('aria-label', sourceLabel);
                                        const iconImage = sourceToIconImage(sourceLabel);
                                        serviceIcon.innerHTML = iconImage
                                            ? `<img src="${iconImage}" alt="${sourceLabel}" referrerpolicy="no-referrer"/>`
                                            : sourceToIconSvg(sourceLabel);
                                        serviceLabel.innerText = sourceLabel;
                                        __lastSourceLabel = sourceLabel;
                                    }
                                }

                                const state = data.transport?.State || '';
                                const speakerName = data.device?.name || '書房';
                                const volumeVal = String(data.volume || '');
                                const metaKey = `${state}|${speakerName}|${volumeVal}`;
                                if (metaKey !== __lastMetaKey) {
                                    const dot = document.querySelector('#meta .dot');
                                    if (dot) {
                                        dot.style.background = state === 'PLAYING' ? '#1DB954' : '#666';
                                    }
                                    document.getElementById('speaker-name').innerText = speakerName;
                                    document.getElementById('volume-val').innerText = volumeVal;
                                    __lastMetaKey = metaKey;
                                }

                                if (data.position) {
                                    const cur = parseTime(data.position.RelTime);
                                    const dur = parseTime(data.position.TrackDuration);
                                    const pct = dur > 0 ? (cur / dur * 100) : 0;
                                    document.getElementById('progress').style.width = pct + '%';
                                    document.getElementById('time-cur').innerText = fmtTime(data.position.RelTime);
                                    document.getElementById('time-dur').innerText = fmtTime(data.position.TrackDuration);
                                }
                            }
                            renderQueue(data.queuePreview);
                        } catch (e) {}
                    }
                    setInterval(update, 3000);
                    update();
                </script>
            </head>
            <body>
                <div id="dashboard">
                    <section id="main-panel">
                        <div id="art"></div>
                        <div id="info">
                            <div id="title">Sonos</div>
                            <div id="artist">Ready to Play</div>
                            <div id="album"></div>
                        </div>
                        <div id="progress-wrap">
                            <div id="progress-bar"><div id="progress"></div></div>
                            <div id="time"><span id="time-cur">--:--</span><span id="time-dur">--:--</span></div>
                            <div id="service-line" class="service-line unknown" title="Unknown">
                                <span id="service-icon" class="service-icon">•</span>
                                <span id="service-label" class="service-label">Unknown</span>
                            </div>
                        </div>
                        <div id="meta">
                            <div class="meta-chip"><span class="dot"></span> <span id="speaker-name">書房</span></div>
                            <div class="meta-chip">🔊 <span id="volume-val">--</span></div>
                        </div>
                    </section>
                    <aside id="queue-panel">
                        <div id="queue-heading">Dashboard v2</div>
                        <div id="queue-subheading">Up Next</div>
                        <div id="queue-list">
                            <div class="queue-empty">Loading queue preview...</div>
                        </div>
                    </aside>
                </div>
            </body>
            </html>
            """
            self.wfile.write(html.encode())

class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

with ThreadingHTTPServer(("", PORT), SonosStatusHandler) as httpd:
    print(f"Serving at port {PORT}")
    httpd.serve_forever()
