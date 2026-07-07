# sonoscli CHANGELOG

## v1.4.0 — 2026-04-05

- 改了什麼：新增 Sonos 原生播放清單管理功能（list / save / play）
- 為什麼改：原本無法從 Telegram 快速叫出清單播放，也無法把當前 queue 存成命名清單
- 新增檔案：`scripts/playlist-manager.py`（soco）、`scripts/playlist-manager.sh`（bash 入口）
- 觸發詞：「列出清單」「存成清單」「放清單 <名稱>」
- 驗證方式：E2E 跑 list/play/save 全部通過，36 首清單存取成功
- 注意：僅操作 Sonos 原生清單，不含 Spotify/Qobuz/TIDAL 串流服務清單


## v1.3.9 — 2026-03-21

- 改了什麼：修正 icon 與 Up Next 閃爍；前端只在資料變化時更新來源 icon/標題/meta，不再每輪詢重寫 DOM。
- 為什麼改（根因）：每 3 秒輪詢時即使內容沒變也重設 `innerHTML/innerText`，在三星 TV 瀏覽器容易造成重繪閃爍。
- 改之前是什麼：每次 update 都重畫來源行與文字，導致視覺閃爍。
- 驗證方式：播放中觀察 1–2 分鐘，icon 與 Up Next 穩定；僅在換歌/換來源時更新。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`


## v1.3.8 — 2026-03-21

- 改了什麼：四個來源 icon 全改為官方網域資產落地（Spotify/TIDAL/Qobuz/Apple Music），前端改讀本機 `/assets/*.png`，不再依賴截圖裁切與第三方圖床。
- 為什麼改（根因）：截圖裁切容易帶入雜訊與比例誤差，且來源不可追溯。
- 改之前是什麼：Qobuz 曾使用對話截圖裁切；部分平台用外站圖示。
- 驗證方式：檢查 `assets/` 檔案存在、頁面顯示四平台圖示、重整後 no-cache 立即生效。
- 搭配變更：
  - `~/.openclaw/skills/sonoscli/assets/spotify.png`
  - `~/.openclaw/skills/sonoscli/assets/tidal.png`
  - `~/.openclaw/skills/sonoscli/assets/qobuz.png`
  - `~/.openclaw/skills/sonoscli/assets/applemusic.png`
  - `~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`
  - `~/.openclaw/skills/sonoscli/SKILL.md`

## v1.3.7 — 2026-03-21

- 改了什麼：來源 icon 與文字改為同一中心線對標（icon box + label line-height 對齊），Qobuz 圖檔改為容器置中等比縮放（`object-fit: contain; object-position: center`），移除手動平移。
- 為什麼改（根因）：手動位移會在不同畫面比例下跑位，與中文文字中心線不一致。
- 改之前是什麼：Qobuz icon 依 `translateY` 微調，位置在不同裝置可能偏移。
- 驗證方式：Qobuz 行的 icon 與文字垂直中心線一致，縮放後不變形不裁切。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`

## v1.3.6 — 2026-03-21

- 改了什麼：Qobuz icon 改為實際參考圖資產（本機 `/assets/qobuz-icon-ref.png`），不再使用手刻 SVG；新增 `/assets/*` 靜態路由與 no-cache，避免舊圖快取。
- 為什麼改（根因）：手刻版外觀與目標 icon 仍有落差，且三星瀏覽器快取會讓改版不生效。
- 改之前是什麼：Qobuz icon 使用程式內嵌 SVG 近似圖。
- 驗證方式：刷新頁面後，Qobuz 應顯示參考圖風格 icon；修改資產後可立即生效。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`、`~/.openclaw/skills/sonoscli/assets/qobuz-icon-ref.png`

## v1.3.5 — 2026-03-21

- 改了什麼：Up Next 改為「僅在換歌時刷新 queue」，不再每 3 秒重抓 queue。
- 為什麼改（根因）：持續輪詢 queue 在三星 TV 容易造成右欄閃爍，且使用者需求是接近換歌節點才更新。
- 改之前是什麼：每次 `/api/status` 都可能重抓 queue preview。
- 驗證方式：播放中觀察 Up Next，應維持穩定；切到下一首時才更新清單。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`

## v1.3.4 — 2026-03-21

- 改了什麼：修正 Qobuz icon（改為黑膠 Q 造型）與 Up Next 無標題 fallback（Untitled → Unknown Track / album / artist），並完成 Qobuz/TIDAL 播放路徑的 metadata adapter 分流。
- 為什麼改（根因）：三星 TV 上 Qobuz icon 辨識偏差，且某些來源回傳稀疏 metadata 時 Up Next 容易出現 Untitled；跨平台共用 payload 也會造成欄位遺失。
- 改之前是什麼：Qobuz icon 為放大鏡風格，Up Next 缺 title 時顯示 Untitled；Qobuz/TIDAL 路徑欄位完整度不一致。
- 驗證方式：播放 Qobuz/TIDAL 時確認品牌 icon 正確、Now Playing 與 Up Next 均有可讀名稱（title/artist/album 至少其一），並用 `sonos status` 驗證 Title/Artist/Album 有值。
- 搭配變更：
  - `~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`
  - `~/.openclaw/workspace/scripts/music-qobuz.sh`
  - `~/.openclaw/workspace/scripts/music-tidal.sh`

## v1.3.3 — 2026-03-21

- 改了什麼：修正 TIDAL 顯示穩定性（補 nowPlaying queue 回填、TIDAL 小 icon fallback、封面 URL 空值不覆蓋）。
- 為什麼改（根因）：TIDAL 偶發回傳稀疏 metadata，導致主畫面出現空標題/無封面，且 icon 來源失敗時只剩點點。
- 改之前是什麼：TIDAL metadata 空時 UI 直接吃到空值；icon fallback 未含 TIDAL。
- 驗證方式：切到 TIDAL 播放時，應可看到正常歌名/藝人/封面，service icon 穩定顯示 TIDAL 菱形。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（Python + JS）

## v1.3.2 — 2026-03-21

- 改了什麼：Up Next 加入 30 秒 queue 防抖快取（API 暫時回空時，沿用上一版非空清單）。
- 為什麼改（根因）：三星 TV 偶發拿到空 queue，畫面在「有清單」與「Queue preview unavailable」之間切換造成閃爍。
- 改之前是什麼：只要本次回空就立刻改畫面為 unavailable。
- 驗證方式：播放中觀察 1-2 分鐘，偶發空回應不再立即清空 Up Next，閃爍顯著下降。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（JS）

## v1.3.1 — 2026-03-21

- 改了什麼：Spotify icon 改用官方圖檔（Wikimedia SVG）顯示，不再用手刻 path 版本。
- 為什麼改（根因）：使用者回報 icon 視覺仍有違和感，需提高官方一致性。
- 改之前是什麼：內嵌 SVG path 手工版本。
- 驗證方式：刷新頁面後 Spotify 顯示官方圖檔樣式；其餘平台維持既有版本。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（JS + CSS）

## v1.3.0 — 2026-03-21

- 改了什麼：來源顯示改成單獨一行「品牌 icon + 服務名稱文字」（例如 Spotify / TIDAL / Qobuz / Apple Music）。
- 為什麼改（根因）：大圖示雖有存在感但太佔空間，需求改為一行式且保留品牌辨識。
- 改之前是什麼：80px 大型 badge，獨立方塊樣式。
- 驗證方式：刷新頁面後，進度條下方顯示一行來源資訊（左 icon、右服務名稱），切換來源會同步更新文字與圖示。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + HTML + JS）

## v1.2.9 — 2026-03-21

- 改了什麼：來源服務 icon 升級為 80px 大尺寸「存在感版」，從時間列移到進度條下方獨立顯示，風格改為仿 Sonos 控制頁視覺。
- 為什麼改（根因）：30px 級別在電視與遠距觀看下不夠醒目，辨識度不足。
- 改之前是什麼：小 icon 置於時間列右側。
- 驗證方式：刷新頁面後，進度條下方可見 80px 來源 icon；Spotify/TIDAL/Qobuz/Apple Music 切換時對應樣式會更新。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + HTML + JS）

## v1.2.8 — 2026-03-21

- 改了什麼：Apple Music 來源 icon 改成官方感樣式（粉紅漸層底 + 白色音符 SVG）。
- 為什麼改（根因）：前一版 Apple Music 只用一般音符字元，品牌辨識不夠。
- 改之前是什麼：粉紅底 + 文字字元 `♪`。
- 驗證方式：播放來源為 Apple Music 時，進度列右側 icon 顯示白色音符圖形與粉紅漸層底。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + JS）

## v1.2.7 — 2026-03-21

- 改了什麼：Qobuz 來源 icon 改成官方感樣式（白底黑色 Q 標記，非藍底字母版）。
- 為什麼改（根因）：前一版 Qobuz 識別不夠像品牌圖示，與你提供參考差距大。
- 改之前是什麼：藍底/簡化字母風格。
- 驗證方式：播放來源為 Qobuz 時，進度列右側 icon 顯示白底黑 Q 標記。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + JS）

## v1.2.6 — 2026-03-21

- 改了什麼：Spotify 來源 icon 改成官方配色方向（亮綠底 + 黑色弧線），不再是白色弧線。
- 為什麼改（根因）：品牌辨識上 Spotify 經典主視覺是黑弧線搭配綠底，白弧線看起來像反色版本。
- 改之前是什麼：綠底 + 白色弧線。
- 驗證方式：播放來源為 Spotify 時，右側 icon 顯示黑色弧線且綠色底。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS）

## v1.2.5 — 2026-03-21

- 改了什麼：TIDAL 來源 icon 改成官方感樣式（黑底 + 白色菱形，且改為圓角方形而非圓形）。
- 為什麼改（根因）：TIDAL 品牌辨識重點是黑色方形底與菱形符號，圓形版本辨識度不足。
- 改之前是什麼：TIDAL 跟其他服務同一套圓形底。
- 驗證方式：播放來源切到 TIDAL 時，右側來源 icon 顯示黑底白菱形且為圓角方形。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS）

## v1.2.4 — 2026-03-21

- 改了什麼：完全移除 `SOURCE:` 文字節點，來源 icon 改成本機內嵌 SVG（不依賴外網 CDN），並移到進度列時間右側顯示。
- 為什麼改（根因）：三星/桌面瀏覽器可能快取舊版與阻擋外部 SVG，導致 source 文字仍出現、icon 不顯示。
- 改之前是什麼：保留 source DOM 且 icon 仰賴 jsDelivr 外部檔案。
- 驗證方式：刷新頁面後確認 `SOURCE:` 字樣消失、進度列右側可見來源圓形 icon（Spotify 為三弧線樣式）。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（HTML + CSS + JS）

## v1.2.3 — 2026-03-21

- 改了什麼：來源服務 icon 放大（22→32），並改成載入官方品牌 SVG（Spotify/Qobuz/TIDAL/Apple Music）。
- 為什麼改（根因）：上一版 icon 太小且用字母替代，不符合品牌辨識。
- 改之前是什麼：小尺寸圓點 + 英文字母（S/Q/T/A）假 icon。
- 驗證方式：刷新頁面後確認 icon 尺寸變大，Spotify 顯示官方三弧線 logo；切換來源時 logo 對應正確。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + JS）

## v1.2.2 — 2026-03-21

- 改了什麼：移除主資訊區 `SOURCE:` 文字列，改為下方 meta 區顯示來源服務圓形 icon（Spotify/Qobuz/TIDAL/Apple Music/Unknown）。
- 為什麼改（根因）：`SOURCE:` 文字行佔版面且視覺噪音高；改成 icon 可保留資訊又更乾淨。
- 改之前是什麼：標題區固定顯示 `SOURCE: ...` 英文字。
- 驗證方式：刷新頁面後確認主區不再顯示 source 文字，meta 區會出現對應服務圓形 icon，切歌時 icon 跟著服務變動。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + HTML + JS）

## v1.2.1 — 2026-03-21

- 改了什麼：調整桌面版 Up Next 卡片的封面與文字間距（封面欄寬 68→72、gap 14→18、卡片左右 padding 微增、文字區左側補 2px）。
- 為什麼改（根因）：電腦視窗版右欄在較寬布局下，封面與標題視覺貼太近；三星 TV 版不受影響。
- 改之前是什麼：桌面版 `.queue-item` 間距偏緊，歌曲標題靠近封面邊緣。
- 驗證方式：桌面瀏覽器（寬螢幕）刷新 `/`，確認封面與文字距離更舒適；三星 TV 2x2 卡片布局維持不變。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS only）

## v1.2.0 — 2026-03-21

- 改了什麼：Now Playing TV Dashboard 版面修正（封面強制 1:1、長歌名字級自適應、Up Next 改 4 首、小螢幕改 2x2 固定卡片、queue 無變更不重繪）。
- 為什麼改（根因）：三星 TV 瀏覽器在窄寬度會把 Up Next 變成橫向捲動，導致捲軸與重繪閃爍；長標題也會撐爆資訊區。
- 改之前是什麼：封面只有寬度約束，特定視窗下仍可能視覺比例異常；Up Next 為 5 首且 mobile 走橫向 scroll；每次輪詢都重畫 queue。
- 驗證方式：
  - `python3 -m py_compile ~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`
  - `launchctl unload/load ~/Library/LaunchAgents/com.lobster.sonos-now-playing.plist`
  - TV 端刷新後確認：無橫向捲軸、閃爍下降、封面維持正方形、長標題不溢出。
- 搭配變更：`~/.openclaw/skills/sonoscli/sonos-now-playing-server.py`（CSS + JS + queue count）

## 2026-03-20 — Qobuz 多首佇列修正

- 記錄：`sonos enqueue` 只支援 Spotify URI，Qobuz/TIDAL/Apple Music 會失敗
- 記錄：`music-qobuz.sh play` 每次覆蓋播放，不累加佇列
- 新增：soco `add_uri_to_queue()` 多首佇列播放範例
- 根因：sonoscli 的 enqueue 指令只實作了 Spotify ref 解析，非 Spotify URI 直接報錯
- 驗證：實測 10 首 Qobuz Jazz 用 soco 成功加入佇列並播放

## v1.2 — 2026-07-10

### 改了什麼
`sonos-now-playing-server.py` 的 `run_sonos_json()` timeout 從 2 秒改為 5 秒。

### 為什麼改
sonos CLI 查詢 Qobuz 播放狀態偶爾超過 2 秒，導致 `/api/status` 回傳 timeout error，TV dashboard 封面、曲名、歌手全部消失。

### 改之前是什麼
`timeout=2` → server 偶發整頁空白，Qobuz 資料看不到。

### 驗證方式
`curl http://<LAN_IP>:18888/api/status` 正確回傳 nowPlaying（title/artist/album/albumArtURL）。

### 搭配變更
無。
