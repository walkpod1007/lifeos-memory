---
name: sonoscli
description: Sonos 音響控制：播放/暫停/切歌/調音量/查播放清單。觸發：放音樂、播某歌、暫停、下一首、音量調高、now playing、sonos
homepage: https://sonoscli.sh
metadata: {"clawdbot":{"emoji":"🔊"},"openclaw":{"emoji":"🔊","requires":{"bins":["sonos"]},"install":[{"id":"go","kind":"go","module":"github.com/steipete/sonoscli/cmd/sonos@latest","bins":["sonos"],"label":"Install sonoscli (go)"}]}}
---

# Sonos CLI

Use `sonos` to control Sonos speakers on the local network.

## Quick start

- `sonos discover`
- `sonos status --name "Kitchen"`
- `sonos play|pause|stop --name "Kitchen"`
- `sonos volume set 15 --name "Kitchen"`

## Common tasks

- Grouping: `sonos group status|join|unjoin|party|solo`
- Favorites: `sonos favorites list|open`
- Queue: `sonos queue list|play|clear`
- Spotify search (via SMAPI): `sonos smapi search --service "Spotify" --category tracks "query"`

## Spotify 播放（重要）

Spotify 帳號認證已完成。如果讀不到認證資訊，可重新認證。

### 播放規則（強制）

1. **禁止直接載入別人的播放清單** — 會失敗
2. **正確做法**：搜尋單曲 → 用 `sonos enqueue` 或 `--enqueue` 一首一首插入
3. 參考別人的曲單時，逐首搜尋後加入，不要整包載入

### 播放指令（專輯/播放清單/單曲皆可）

```bash
# 專輯：直接播整張
sonos open spotify:album:5sJtW03dyXYGzd7WRqT4Zk --name "書房"

# 播放清單：直接播整個
sonos open spotify:playlist:58Hcwmlbdqvblk9exbrh2z --name "書房"

# 單曲
sonos open spotify:track:6NmXV4o6bmp704aPGyTVVG --name "書房"

# 分享連結也可接受
sonos open "https://open.spotify.com/track/6NmXV4o6bmp704aPGyTVVG" --name "書房"
```

### 瀏覽自己的音樂庫（SMAPI browse）

```bash
# 瀏覽根目錄
sonos smapi browse --service "Spotify" --name "書房"

# 瀏覽自己的專輯
sonos smapi browse --service "Spotify" --name "書房" --id "your_albums"

# 瀏覽自己的播放清單
sonos smapi browse --service "Spotify" --name "書房" --id "playlists"

# 瀏覽自己的歌曲
sonos smapi browse --service "Spotify" --name "書房" --id "your_songs"
```

### 建立自訂佇列

```bash
# 1. 清空佇列
sonos queue clear --name "書房"

# 2. 第一首：搜尋並開始播放（--open）
sonos search spotify "Bill Evans Waltz for Debby" --open --name "書房"

# 3. 後續：搜尋並加入佇列（--enqueue，不中斷播放）
sonos search spotify "Miles Davis So What" --enqueue --name "書房"
sonos search spotify "Chet Baker My Funny Valentine" --enqueue --name "書房"

# 4. 或用已知 URI 加入佇列
sonos enqueue spotify:track:XXXXXXX --name "書房"

# 5. 確認佇列
sonos queue list --name "書房"
```

### 分組播放（Spotify URI 解析 + Group）

```bash
# 使用內建腳本 spotify-uri-play.sh（見本目錄）

# 播放到單一房間
./spotify-uri-play.sh --room "書房" "spotify:track:6NmXV4o6bmp704aPGyTVVG"

# 播放並同步到多房間（Party Mode）
./spotify-uri-play.sh --room "客廳" --party "spotify:track:6NmXV4o6bmp704aPGyTVVG"

# 批次播放多個 URI
./spotify-uri-play.sh --room "書房" \
  "spotify:track:AAA" \
  "spotify:track:BBB" \
  "spotify:track:CCC"

# 搜尋並加入多個房間
./spotify-uri-play.sh --room "書房" --search "Miles Davis Kind of Blue"
```

### URI 格式支援

| 格式 | 範例 |
|------|------|
| Spotify URI - track | `spotify:track:6NmXV4o6bmp704aPGyTVVG` |
| Spotify URI - album | `spotify:album:XXXXXX` |
| Spotify URI - playlist | `spotify:playlist:XXXXXX` |
| 分享連結 | `https://open.spotify.com/track/XXXXXX` |

### ⚠️ 已知問題

- **搜尋路徑教訓 (2026-03-16)**：點歌時**禁止**使用 `sonos search spotify`（需要 `SPOTIFY_CLIENT_ID` Web API 憑證，環境缺失）。**必須**改用 `sonos smapi search --service "Spotify" --category tracks "query"`，走 Sonos 已認證的 SMAPI。
- `sonos open` 支援 `spotify:album:` / `spotify:playlist:` / `spotify:track:` 三種 URI，可直接播整張專輯或播放清單，不需一首一首加。
- `favorites open` 專輯/藝人/播放清單類會回 error 714（UPnP 容器 URI 不相容）。單曲類 OK。workaround：用 `sonos open <URI>` 直接播。
- `queue add` 子指令不存在，用 `sonos enqueue` 代替
- **`sonos enqueue` 只支援 Spotify URI**（2026-03-20 實測）。Qobuz/TIDAL/Apple Music URI 會報 `currently only Spotify refs are supported`。非 Spotify 平台必須用 soco `add_uri_to_queue()` 或 `avTransport.AddURIToQueue`
- `sonos play spotify "..."` 不是有效指令，用 `sonos open` 代替
- Apple Music / TIDAL / Qobuz 的 SMAPI 認證流程有 bug，已改用替代方案（見下方多平台播放）
- 封面圖需中轉（mzstatic.com 直連在 LINE Flex hero 載入過慢），存 Vault Inbox 取公開 URL
- `[[media_player:]]` 無按鈕模式依賴本機 patch（`patch-openclaw-media-player.sh`），升級 OpenClaw 後需重跑

## 多平台播放（Qobuz / TIDAL / Apple Music / Amazon Music）

### 平台優先順序（強制）
Qobuz → TIDAL → Apple Music → Amazon Music → Spotify

### 播放規則（強制）
1. **預設以整張專輯為單位播放**（全部歌曲加入 queue），除非使用者指定某首歌
2. 專輯播放流程：API 搜尋 → 取專輯全曲目 → clear queue → AddURIToQueue 逐首加入 → play_from_queue(0)
3. 單曲播放：直接 play_uri

### Qobuz 多首佇列播放（強制規則）

`music-qobuz.sh play` 是單首播放。多首佇列必須使用 `avTransport.AddURIToQueue` 並附 `EnqueuedURIMetaData`（DIDL XML）。

禁止：`speaker.add_uri_to_queue(uri)` 裸 URI 直接入隊（會導致 Unknown Track / 沒有內容）。

```python
import soco
speaker = [s for s in soco.discover() if s.player_name == "書房"][0]
speaker.clear_queue()
for tid, uri, meta_xml in tracks:
    speaker.avTransport.AddURIToQueue([
        ("InstanceID", 0),
        ("EnqueuedURI", uri),
        ("EnqueuedURIMetaData", meta_xml),
        ("DesiredFirstTrackNumberEnqueued", 0),
        ("EnqueueAsNext", 0),
    ])
speaker.play_from_queue(0)
```

硬性驗收：
- queue 前 3 首不得為 `Unknown Track` / `沒有內容`
- current track title 不可空字串
- **`get_current_track_info()` 返回空 title 不算通過**，必須改用 `sonos status --name "書房"` 確認實際曲名顯示
- 任一條件不符，立即視為失敗並重建 queue（不得回報成功）

⚠️ 實測踩坑（2026-03-26）：
- sn=2 會導致 Sonos App 顯示「沒有內容」，必須使用 sn=18
- item id 必須為 `00030020track%3a{id}%3a7.flac`，缺少 `00030020` 前綴 Sonos 找不到 metadata
- **禁止手刻 DIDL XML**：直接複製 `~/life-os/skills/sonoscli/scripts/music-qobuz.sh` 裡的 Python 段當模板，不要自己從頭寫

### 腳本
| 平台 | 腳本 | 用法 |
|------|------|------|
| Qobuz | `~/life-os/skills/sonoscli/scripts/music-qobuz.sh` | `music-qobuz.sh play "query" --name "書房"`（⚠️ 單首用，多首用 soco） |
| TIDAL | `~/life-os/skills/sonoscli/scripts/music-tidal.sh` | `music-tidal.sh play "query" --name "書房"` |
| Apple Music | `~/life-os/skills/sonoscli/scripts/music-apple.sh` | `music-apple.sh play "query" --name "書房"` |
| Amazon Music | SMAPI 直接搜尋（見下方） | `sonos smapi search --service "Amazon Music" --category tracks "query" --name "書房"` |

### Amazon Music 播放

認證方式：SMAPI DeviceLink（已完成，JP 帳號）。Token 由 sonoscli 內部管理，無需 `.env` 設定。

```bash
# 搜尋單曲
sonos smapi search --service "Amazon Music" --category tracks "Euiju Cheong" --name "書房"

# 瀏覽根目錄
sonos smapi browse --service "Amazon Music" --name "書房"
```

⚠️ Amazon Music 無對應 CLI 腳本（music-amazon.sh），走 SMAPI 層操作。
⚠️ 認證到期需重新走 DeviceLink 流程：`sonos smapi auth --service "Amazon Music" --name "書房"`

### URI 格式速查
| 平台 | URI 格式 | desc |
|------|---------|------|
| Qobuz | `x-sonos-http:track%3a{id}%3a7.flac?sid=31&flags=8232&sn=18` | `SA_RINCON7943_` |
| TIDAL | `x-sonos-http:track%2f{id}.flac?sid=174&flags=8232&sn=3` | `SA_RINCON44551_X_#Svc44551-0-Token` |
| Apple Music | `x-sonosapi-hls-static:song%3a{id}?sid=204&flags=8232&sn=16` | 無需 desc |

### 專輯播放（加入 queue）
用 soco Python 的 `avTransport.AddURIToQueue` 逐首加入：
```python
s.avTransport.AddURIToQueue([
    ("InstanceID", 0),
    ("EnqueuedURI", uri),
    ("EnqueuedURIMetaData", meta_xml),
    ("DesiredFirstTrackNumberEnqueued", 0),
    ("EnqueueAsNext", 0),
])
```
⚠️ Apple Music 的 meta XML 不需要 `<desc>` tag，但需要 `<res>` tag 包含完整 URI。

### Token 存放
`~/.claude/.env`：
- `QOBUZ_APP_ID`, `QOBUZ_USER_AUTH_TOKEN`
- `TIDAL_ACCESS_TOKEN`, `TIDAL_REFRESH_TOKEN`, `TIDAL_CLIENT_ID`
- `APPLE_MUSIC_DEV_TOKEN`, `APPLE_MUSIC_USER_TOKEN`

Amazon Music：Token 由 sonoscli 內部管理，不在 `.env`。

### 平台認證狀態
| 平台 | 認證方式 | 狀態 | 帳號 |
|------|---------|------|------|
| Qobuz | 直接 API（music-qobuz.sh） | ✅ 有效 | — |
| TIDAL | OAuth（music-tidal.sh auth） | ✅ 有效（2026-03-29 重新認證） | — |
| Apple Music | 直接 API（music-apple.sh） | ✅ 有效 | — |
| Amazon Music | SMAPI DeviceLink | ✅ 有效（2026-03-29 認證） | JP 帳號 |
| Spotify | SMAPI（僅搜尋可用） | ✅ 認證中 | — |
| YouTube Music | SMAPI | ❌ Google 封鎖，無法用 | — |

### 平台選擇 UI
使用者可透過 LINE buttons 選擇平台：
```
[[buttons: 🎵 播歌平台選擇 | 選一個平台來點歌 | 🟣 Qobuz (Hi-Res):action=music_platform&platform=qobuz, 🔵 TIDAL (Lossless):action=music_platform&platform=tidal, 🍎 Apple Music:action=music_platform&platform=apple]]
```

### 音質要求（強制）

播放品質必須為最高等級。不使用 MP3 格式。
確認 Spotify Connect 輸出為 HiFi / Lossless（如果 Spotify 帳號支援）。
Sonos 端設定：確保 Audio Quality 設為 High / Lossless。

### 視覺回饋 (LINE)

Agent 在執行播放指令後，用純文字 + Quick Reply 泡泡回傳播放狀態（全程走 Reply，零 Push）：

```
🎵 {曲名}
🎤 {歌手}
📀 {專輯或播放清單名} · ▶️ Playing / ⏸ 已暫停
[[quick_replies: ⏮ 上一首, ▶️ 播放, ⏸ 暫停, ⏭ 下一首]]
```

**規則：**
- 播放狀態用 `sonos status --name "書房"` 取得
- 封面圖：iTunes API 拿高清封面 → 存 Vault Inbox/album-art/（快取，重複歌不重抓）
- 公開 URL：`https://<YOUR_DOMAIN>/90_System/Inbox/album-art/{artist}-{album}.jpg`
- 使用 `[[media_player: 曲名 | 歌手 | 來源 | vault封面URL]]`（4 參數，無按鈕）
- ⚠️ 不要帶第 5 個參數（playing/paused），否則會出現醜按鈕
- 禁止使用 curl Push 送 Flex（浪費 Push 額度）
- 此功能依賴 patch：`bash ~/life-os/scripts/patch-openclaw-media-player.sh`（升級 OpenClaw 後需重跑）

**封面中轉範例：**
```bash
# iTunes 高清封面
ART_URL=$(python3 -c "
import urllib.request, urllib.parse, json
q = urllib.parse.quote('${ARTIST} ${ALBUM}')
url = f'https://itunes.apple.com/search?term={q}&media=music&entity=album&limit=1'
resp = urllib.request.urlopen(url, timeout=5)
data = json.loads(resp.read())
if data['resultCount'] > 0:
    print(data['results'][0]['artworkUrl100'].replace('100x100bb', '600x600bb'))
")
# 快取到 Vault（重複歌不重抓）
SAFE_NAME=$(echo "${ARTIST}-${ALBUM}" | tr ' /:' '-' | tr '[:upper:]' '[:lower:]' | head -c 60)
VAULT_ART="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/90_System/Inbox/album-art/${SAFE_NAME}.jpg"
if [[ ! -f "$VAULT_ART" ]]; then
  curl -sL "$ART_URL" -o "$VAULT_ART"
fi
COVER_URL="https://<YOUR_DOMAIN>/90_System/Inbox/album-art/${SAFE_NAME}.jpg"
```

## 播放清單管理（Sonos 原生清單）

使用 `playlist-manager.sh` 管理 Sonos 系統播放清單（不含串流服務清單）。

### 子指令

```bash
# 列出所有清單
bash ~/life-os/scripts/playlist-manager.sh list [--name "書房"]

# 把目前 queue 存成清單
bash ~/life-os/scripts/playlist-manager.sh save "清單名稱" [--name "書房"]

# 播放指定清單
bash ~/life-os/scripts/playlist-manager.sh play "清單名稱" [--name "書房"]
```

### 觸發關鍵字

| 使用者說 | 執行 |
|---------|------|
| 列出清單 / 我的清單 / 有哪些清單 | `playlist-manager.sh list` |
| 存成清單「名稱」/ 存下來叫「名稱」 | `playlist-manager.sh save "名稱"` |
| 放清單「名稱」/ 播放清單「名稱」 | `playlist-manager.sh play "名稱"` |

### 平台升級（v2 待做）

現有清單平台狀態：
- 星際異攻隊3：全 Qobuz ✅
- 日本動漫：全 TIDAL（目標升 Qobuz）
- 蛋堡：TIDAL×2 + Apple Music×1 + Qobuz×1
- 張國榮：全 Amazon Music（36 首）

**中文曲目搜尋注意事項（重要）：**
Qobuz/TIDAL 索引用拉丁字符，純漢字搜尋命中率低。必須雙軌搜尋：
- 藝人：漢字 + 英文名（例如 張國榮 → Leslie Cheung）
- 歌名：漢字 + 拼音（用 `pypinyin` 套件轉換）
- 已知對照：需手建中英藝人對照表

v2 實作時需要：`pypinyin`、藝人對照表、搜尋結果人工確認機制（避免換錯歌）

---

### LINE 回應格式

**list：**
```
🎵 播放清單（共 N 個）
1. 爵士夜
2. 晨間輕音樂
[[quick_replies: 放清單 爵士夜, 放清單 晨間輕音樂]]
```

**save：**
```
✅ 已儲存為「爵士夜」（共 N 首）
```

**play：**
```
▶️ 正在播放「爵士夜」
```
（接著呼叫 `sonos status --name "書房"` 取得曲目資訊，走現有播放狀態回饋流程）

## Notes

- If SSDP fails, specify `--ip <speaker-ip>`.
- Spotify Web API search requires `SPOTIFY_CLIENT_ID/SECRET`.
- If there is an error, check the troubleshooting section and offer advice if there is a decent match.

## Troubleshooting

### `sonos discover` - `no route to host`

- On error `Error: write udp4 0.0.0.0:64326->239.255.255.250:1900: sendto: no route to host (Command exited with code 1)`
  - The `sendto: no route to host` should stay consistent
- On Mac OS: Settings -> Privacy & Security -> Local Network needs to be enabled for the host parent process (`node` for launchd, `Terminal` for direct).
- Alternative: use `sandbox` (docker) with network access allowed.

### `sonos discover` - `bind: operation not permitted`

- On error `Error: listen udp4 0.0.0.0:0: bind: operation not permitted`
- Likely running in a sandbox without network access (e.g., Codex CLI).

---

## Now Playing TV Dashboard

三星 TV 瀏覽器即時顯示 Sonos 正在播放的封面、歌名、歌手、進度條。

### 架構
- Python HTTP server（port 18888）
- 前端每 3 秒 fetch `/api/status`
- 高解析封面：iTunes Search API → 1200×1200（Sonos 原生只有 600×600）
- 記憶體快取，同一首歌不重複查詢

### 端點
| Path | 說明 |
|------|------|
| `/` | Now Playing 主頁面（黑底大封面+資訊） |
| `/api/status` | JSON API（含 hiresArtURL） |
| `/gallery` | 美術館模式（Met Museum 名畫輪播） |

### TV 網址
http://<LAN_IP>:18888

### 已知修正
- 2026-07: 專輯封面改為 1:1 正方形（`min(88vw,55vh)` + `aspect-ratio:1/1`），修正原本非正方形溢出問題

### 品牌資產來源與路徑（強制）

來源 icon 一律使用官方網域資產，禁止用對話截圖裁切當正式檔。

| 服務 | 官方來源 URL | 本機路徑 |
|------|--------------|----------|
| Spotify | `https://open.spotifycdn.com/cdn/images/favicon32.b64ecc03.png` | `~/life-os/skills/sonoscli/assets/spotify.png` |
| TIDAL | `https://tidal.com/favicon.ico` | `~/life-os/skills/sonoscli/assets/tidal.png` |
| Qobuz | `https://play.qobuz.com/apple-touch-icon.png` | `~/life-os/skills/sonoscli/assets/qobuz.png` |
| Apple Music | `https://music.apple.com/favicon.ico` | `~/life-os/skills/sonoscli/assets/applemusic.png` |

Dashboard 讀取路徑：`/assets/<name>.png`（由 `sonos-now-playing-server.py` 提供，no-cache）。

### Server 檔案
`~/life-os/skills/sonoscli/sonos-now-playing-server.py`

### launchd 常駐
plist 路徑：`~/Library/LaunchAgents/com.lobster.sonos-now-playing.plist`

開機自動啟動，播放時 TV 開瀏覽器即可看到。

手動控制：
```bash
# 啟動
launchctl load ~/Library/LaunchAgents/com.lobster.sonos-now-playing.plist
# 停止
launchctl unload ~/Library/LaunchAgents/com.lobster.sonos-now-playing.plist
# 檢查狀態
launchctl list | grep sonos
```

### 播放時自動行為
Agent 在執行 `sonos play` / `sonos search --open` / `sonos open` 等播放指令時：
1. **Server 檢查**：檢查 TV 看板 server 是否運行，未運行則啟動：
   ```bash
   lsof -i :18888 >/dev/null 2>&1 || launchctl load ~/Library/LaunchAgents/com.lobster.sonos-now-playing.plist
   ```
2. **視覺回饋 (LINE)**：用純文字 + Quick Reply 泡泡回傳播放狀態（見上方格式），全程走 Reply。

### Quick Reply 泡泡控制路由

收到以下文字時執行對應指令，完成後回傳更新狀態卡：

| 使用者文字 | 指令 |
|-----------|------|
| ⏮ 上一首 | `sonos prev --name "書房"` |
| ▶️ 播放 | `sonos play --name "書房"` |
| ⏸ 暫停 | `sonos pause --name "書房"` |
| ⏭ 下一首 | `sonos next --name "書房"` |

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
