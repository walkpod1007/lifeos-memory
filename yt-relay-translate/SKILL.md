---
name: yt-relay-translate
description: >
  外文演講/訪談 YT 影片搬運翻譯一條龍：下載→取或聽寫字幕→sonnet 翻繁中→燒錄＋軟字幕→上傳自有頻道（預設 unlisted 待過目）。
  觸發：搬運這支影片、加中文字幕上傳、外文演講翻譯上傳、relay translate、下載加中字傳我頻道。
  不觸發：自己影片的多語字幕（yt-sub-translate）、配音音軌（yt-dub）、只要摘要不要影片（capture）。
  消歧：關鍵差異是「下載別人的影片重傳自己頻道」；只動字幕不動影片本體時走 yt-sub-translate。
version: "1.0"
created: "2026-07-03"
---

# yt-relay-translate

## 為什麼存在

2026-07-03 使用者需求：外文演講類影片丟連結→背景全自動加繁中字幕上傳自有頻道。yt-sub-translate 只處理「自己頻道現有影片」的字幕層；本 skill 補「下載外部影片＋無字幕時 STT＋影片本體重傳」三段。參考實作：VideoSubtitler（wiki/entities/，@goldyubrain）——但翻譯引擎照本系統鐵則走 sonnet 子代理（品質），STT 用本機 whisper.cpp（長演講免 API 費）。

## Happy path

```bash
bash ~/life-os/skills/yt-relay-translate/scripts/relay.sh <YT_URL> [--privacy unlisted|private] [--burn|--soft-only] [--channel yourchannel|yourchannel2] [--channel yourchannel|yourchannel2]
bash ~/life-os/skills/yt-relay-translate/scripts/relay.sh --resume <video_id> [--approve-upload] [--dry-run] [--force-reupload]
```

（`--privacy public` 在 relay.sh 這層直接拒絕——初次搬運一律 unlisted 起步，公開走第 6 步的 `--update-privacy`。`--dry-run` 或 env `YT_RELAY_NO_UPLOAD=1` 可讓 Step5 只印出上傳 payload、不呼叫 API，測試時用這個而不是裸資帳號續跑。）

1. **下載**：yt-dlp 抓最佳 mp4（≤1080p）＋來源 metadata（title/channel/date）到 `/tmp/yt-relay/<video_id>/`（同一個 video_id 用 mkdir 鎖目錄防併發重跑，兩個進程搶同一支影片會有一個被拒絕）
2. **字幕來源**（優先序）：a) 來源影片自帶人工字幕 srt → 直接用；b) 自動字幕 → 用但標記；c) 都沒有 → 先 `ffprobe` 驗證有音軌，再本機 `whisper-cli` 聽寫產 srt（本機現有最佳模型＝ggml-large-v3-turbo，於 ~/.claude-video-vision/models/，品質優於 medium——非 degraded）
3. **翻譯**：主 session 派 **sonnet 子代理**翻繁中（.srt 結構保留、段數相符；鐵則：翻譯不走 Haiku/CLI 批次）——script 在此步 pause 產出 JSON 格式的 `NEED_TRANSLATE.flag`，由主 session 接手派工後把 `zh.srt` 放回工作目錄，**並寫 `TRANSLATE_DONE.json`（`{"source_sha256":..., "zh_segments":...}`）**，兩者缺一或段數/sha256 對不上，翻譯閘不放行，才用 `--resume` 續跑
4. **合成**：預設軟字幕版（原片＋zh.srt 掛 caption——YT 原生渲染、可開關、可搜尋）；`--burn` 燒錄版優先用 `~/life-os/bin/ffmpeg-full`（靜態 build 含 libass；Homebrew 官方 ffmpeg 8.x 配方已移除 libass，重裝無效——2026-07-03 實測後改抓 martin-riedl.de 靜態版，燒錄冒煙測試過），不存在或該 binary 沒編 subtitles filter 才 fallback 系統 ffmpeg（沒 libass 就照 degraded 邏輯降軟字幕）。filter 語法 `subtitles=filename='<path>'`
5. **上傳**：Step4 完成後不會自動上傳——需明確帶 `--approve-upload`（或純測試用 `--dry-run`）才進 Step5。核可後沿用 yt-sub-translate 的 OAuth（`~/.config/yt-sub-translate/token.json`，scope youtube.force-ssl 含 upload）`videos.insert`，**預設 unlisted**；描述欄自動附「原始影片出處＋頻道」溯源行（缺這行上傳器會拒傳），zh.srt 同步掛 caption；字幕掛載失敗時狀態落地成 `completed_no_captions`（不是一般 `completed`）
6. **回報**：LINE 給 unlisted 連結（附 YouTube 回應的真實 `uploaded_id`），使用者過目後說「轉公開」再 `videos.update` privacy

## Degraded path

- yt-dlp 下載失敗（地區鎖/會員限定）→ 報 URL 與錯誤，不重試超過 2 次
- whisper-cli 不在或模型缺 → 降級 OpenAI whisper-1 API（分段 ≤25MB）；再失敗 → 存已下載影片並報「字幕段卡住」
- 上傳配額爆（youtube quota 1600 units/支，日限 ~6 支）→ 保留本地成品，回報「隔日自動重試或手動」
- 燒錄 ffmpeg 失敗 → 至少交軟字幕版，不整案報廢
- state.json 損毀/必要鍵缺失 → --resume 直接拒絕，指示帶原始 `<YT_URL>` 用 `--resume <video_id> --restart` 重建（既有產出檔案會被沿用，不必重下載）
- Step5 已寫過 `upload-started.marker`（曾嘗試上傳過）→ 拒絕再次上傳，除非明確加 `--force-reupload`

## Guard（紅線）

- ❌ 預設 public 上傳（relay.sh 這層直接拒絕 `--privacy public`；一律 unlisted 起步，使用者過目才用 `yt_relay_upload.py --update-privacy` 轉公開——搬運內容的頻道品控）
- ❌ 略過描述欄溯源行（原始出處必附，版權禮儀；上傳器邊界也會擋，空描述或缺「原始影片：」前綴直接拒傳 exit 2）
- ❌ 翻譯走 Haiku/CLI 批次（鐵則：sonnet 子代理；泰文類 CLI 必超時前科）
- ❌ 略過翻譯閘直接進 Step4/5（`zh.srt` 存在還不夠，需 `TRANSLATE_DONE.json` 且 sha256/段數皆驗證通過）
- ❌ Step4 完成後未經 `--approve-upload`（或 `--dry-run`）就自動上傳（2026-07-03 事故：測試續跑直通上傳段，垃圾影片真的上了頻道，工兵自刪＋主 session 複核歸零——這條就是補這個閘）
- ❌ 刪除 /tmp 工作目錄在使用者確認公開之前（重做成本高）
- ✅ 長演講（>30 min）whisper 聽寫先報預估時間再開跑
- ❌ 測試/開發時帶真 OAuth 跑 --resume 之後的步驟（測上傳一律先 `mv token.json token.json.bak` 或用 `--dry-run` / env `YT_RELAY_NO_UPLOAD=1`）

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: "skill-author 2026-07-03，需求方 LINE DM"
status: active
closeout_gist: ""
