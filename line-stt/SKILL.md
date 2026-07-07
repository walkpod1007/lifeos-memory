---
name: line-stt
description: LINE 語音訊息 STT：下載 m4a 經 Whisper 轉文字回覆。觸發：line-media 收到 message.type=audio 時呼叫
version: "1.0"
updated: "2026-04-17"
metadata: {"clawdbot":{"emoji":"🎙️"}}
---

# LINE STT 語音轉譯（line-stt）

對照 Telegram 的 telegram-media 語音處理邏輯，移植至 LINE 媒體下載機制。

---

## 完整流程

```
收到 message.type=audio
  → 下載 m4a（LINE API）
  → ffmpeg 轉 wav
  → OpenAI Whisper 轉譯
  → 直接 reply 轉譯文字
```

---

## Step 1：下載 m4a

```bash
LINE_TOKEN=$(grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $LINE_TOKEN" \
  "https://api-data.line.me/v2/bot/message/{messageId}/content" \
  -o /tmp/line-voice.m4a
```

⚠️ domain 必須用 `api-data.line.me`

---

## Step 2：ffmpeg 轉 wav

```bash
ffmpeg -i /tmp/line-voice.m4a -ar 16000 -ac 1 /tmp/line-stt.wav -y 2>/dev/null
```

---

## Step 3：OpenAI Whisper 轉譯

```bash
OPENAI_API_KEY=$(grep OPENAI_API_KEY ~/.claude/.env | cut -d= -f2)
curl -s https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F model="whisper-1" \
  -F file="@/tmp/line-stt.wav" \
  -F language="zh"
```

回傳 JSON：`{"text": "轉譯內容"}`

---

## Step 4：回覆

- 直接把轉譯文字當作使用者輸入繼續對話
- 不逐字複誦，回覆語意

---

## 錯誤處理

| 狀況 | 行為 |
|------|------|
| 下載失敗（檔案 < 1000 bytes）| reply「語音下載失敗，請重新傳」 |
| Whisper API 失敗 | reply「語音辨識失敗，請重新傳或改用文字」 |
| ffmpeg 失敗 | reply「音檔格式無法處理」 |

---

## 依賴確認

```bash
which ffmpeg
which ffprobe
grep OPENAI_API_KEY ~/.claude/.env
grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env
```

---

## Gotchas

- LINE 媒體 URL 在 webhook 後約 30 分鐘失效，必須立刻下載
- Whisper `language=zh` 涵蓋繁體／簡體中文，不需額外分語言
- 不用 Intent-First / postback 架構（舊 openclaw 方式），同步處理即可

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
