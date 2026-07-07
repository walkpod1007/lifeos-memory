---
name: line-tts
description: LINE TTS：文字轉語音經 edge-tts 合成，以 audioMessage 回覆。觸發：傳語音訊息進來、用說的、讀給我聽、語音回覆
version: "1.0"
updated: "2026-04-17"
metadata: {"clawdbot":{"emoji":"🔊"}}
---

# LINE TTS 語音回覆（line-tts）

使用 edge-tts（免費，本機已安裝）產生語音，替代舊版 Gemini TTS 方案。

---

## 觸發條件

| 情境 | 行為 |
|------|------|
| 使用者傳語音訊息進來 | **必定**語音回覆（聲音進、聲音出）|
| 說「用說的」「讀給我聽」「語音回覆」「唸出來」| 改以語音回覆 |
| 一般文字問題 | 預設文字回覆，不主動轉 TTS |

---

## 完整流程

```
生成文字回覆
  → edge-tts 合成 mp3
  → ffmpeg 轉 m4a（AAC）
  → 上傳 catbox.moe → 取得 HTTPS URL
  → LINE audioMessage（originalContentUrl + duration）
```

---

## Step 1：edge-tts 合成

```bash
VOICE="zh-TW-HsiaoChenNeural"   # 預設女聲；可選 HsiaoYuNeural / YunJheNeural（男）
TEXT="要轉換的文字內容"
edge-tts --voice "$VOICE" --text "$TEXT" --write-media /tmp/line-tts.mp3
```

可用繁中聲音：
- `zh-TW-HsiaoChenNeural`（女，友善）← 預設
- `zh-TW-HsiaoYuNeural`（女，友善）
- `zh-TW-YunJheNeural`（男，友善）

---

## Step 2：ffmpeg 轉 m4a

```bash
ffmpeg -i /tmp/line-tts.mp3 -c:a aac -b:a 128k /tmp/line-tts.m4a -y 2>/dev/null
DURATION_MS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 /tmp/line-tts.m4a 2>/dev/null \
  | python3 -c "import sys; print(int(float(sys.stdin.read().strip())*1000))")
```

---

## Step 3：上傳 catbox.moe

```bash
AUDIO_URL=$(curl -s -F "reqtype=fileupload" \
  -F "fileToUpload=@/tmp/line-tts.m4a" \
  "https://catbox.moe/user.php" | tr -d '[:space:]')
```

回傳格式：`https://files.catbox.moe/xxxxxx.m4a`

---

## Step 4：LINE audioMessage

```bash
LINE_TOKEN=$(grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env | cut -d= -f2)
curl -s -X POST https://api.line.me/v2/bot/message/reply \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LINE_TOKEN" \
  -d "{
    \"replyToken\": \"$REPLY_TOKEN\",
    \"messages\": [{
      \"type\": \"audio\",
      \"originalContentUrl\": \"$AUDIO_URL\",
      \"duration\": $DURATION_MS
    }]
  }"
```

---

## 長度限制

| 情境 | 處理 |
|------|------|
| 文字 ≤ 4000 字元 | 正常 TTS |
| 文字 > 4000 字元 | 截斷至 4000 字元，附說明 |
| 音頻 > 5 分鐘 | duration 上限 300000ms |

---

## 錯誤處理

| 錯誤 | 行為 |
|------|------|
| edge-tts 失敗 | fallback 改傳文字訊息 |
| ffmpeg 轉換失敗 | fallback 改傳文字訊息 |
| catbox 上傳失敗 | log 錯誤，退出（LINE 無法播放本機路徑）|
| LINE API 失敗 | log HTTP code，不重試 |

---

## 依賴確認

```bash
which edge-tts
which ffmpeg && which ffprobe
grep LINE_CHANNEL_ACCESS_TOKEN ~/.claude/channels/line/.env
curl -s https://catbox.moe/user.php --max-time 5
```

---

## Gotchas

- edge-tts 需要網路連線（呼叫 Microsoft Edge TTS 服務）
- catbox.moe 免費但偶有不穩定，失敗時 fallback 文字
- LINE audioMessage 只接受 HTTPS URL，本機路徑不可用
- reply token 單次使用，TTS 完成前不能先用掉（不發純文字 ack）

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
