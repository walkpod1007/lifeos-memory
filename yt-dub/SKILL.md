---
name: yt-dub
description: YouTube 影片生成多語言 TTS 配音軌並上傳。觸發：配音、tts、dubbing、生成配音、多語言音軌、幫影片配音
---

# yt-dub — YouTube 多語言 TTS 配音工作流程

從 SRT 字幕 → edge-tts 生成語音 → ffmpeg 組裝音軌 → 上傳 YouTube 配音軌，全程自動化。

## 先決條件

```bash
python3 -c "import edge_tts"   # edge-tts SDK
which ffmpeg                    # ffmpeg 音訊處理
```

Token 路徑：`~/Documents/life-os/config/yt-<account>-token.json`（含 client_id / client_secret / refresh_token）

## 工作流程

```
SRT 字幕（已翻譯）
    → edge-tts 逐條生成 MP3 clip（批次 20 條）
    → ffmpeg adelay 組裝（每個 clip 依 SRT 起始時間定位）
    → 輸出 .m4a（AAC 128k）
    → YouTube Captions API 上傳為配音軌
```

## 語音對照表（男聲 default）

| 語言 | 男聲 Voice ID | 女聲 Voice ID |
|------|--------------|--------------|
| 英語 | `en-US-GuyNeural` | `en-US-JennyNeural` |
| 泰語 | `th-TH-NiwatNeural` | `th-TH-PremwadeeNeural` |
| 日語 | `ja-JP-KeitaNeural` | `ja-JP-NanamiNeural` |
| 韓語 | `ko-KR-InJoonNeural` | `ko-KR-SunHiNeural` |
| 中文（台） | `zh-TW-YunJheNeural` | `zh-TW-HsiaoChenNeural` |

## 執行方式

```bash
# 單一語言
python3 ~/.claude/skills/yt-dub/dub.py \
  --srt ~/Documents/life-os/drafts/MacBookNeo_en.srt \
  --voice en-US-GuyNeural \
  --out /tmp/MacBookNeo_en_dub.m4a

# 上傳到 YouTube
python3 ~/.claude/skills/yt-dub/dub.py \
  --srt ~/Documents/life-os/drafts/MacBookNeo_en.srt \
  --voice en-US-GuyNeural \
  --out /tmp/MacBookNeo_en_dub.m4a \
  --upload --video-id kyPdgEIuABI \
  --token ~/Documents/life-os/config/yt-yourchannel-token.json \
  --lang en --lang-name English
```

## YouTube 上傳 API 流程

```python
# 1. 初始化 resumable upload（snippet 帶 language + name）
POST https://www.googleapis.com/upload/youtube/v3/captions
  ?uploadType=resumable&part=snippet&sync=false

# 2. PUT SRT/m4a 內容到 Location header 的 upload_url
# 注意：YouTube 配音軌上傳需用 .m4a (AAC)，不能用 .mp3
```

## 常見問題

| 問題 | 原因 | 解法 |
|------|------|------|
| SRT 讀取 `Operation not permitted` | 從 Downloads 複製帶 quarantine xattr | `xattr -c ~/Documents/life-os/drafts/*.srt` |
| token refresh 400 `invalid_grant` | refresh_token 過期/revoked | 跑 `yt-reauth.py` 重新授權 |
| ffmpeg 組裝超慢 | 152 條 adelay inputs | 正常，152 clips × 8分鐘影片約 30s |
| edge-tts 某條 TranslationNotFound | 非翻譯問題，是網路 timeout | 加 `except Exception: return text` fallback |

## 相關 token 路徑

- yourchannel 頻道：`~/Documents/life-os/config/yt-yourchannel-token.json`
- yourchannel2 頻道：`~/Documents/life-os/config/yt-yourchannel2-token.json`
- 重新授權腳本：`~/Documents/life-os/scripts/yt-reauth.py`
