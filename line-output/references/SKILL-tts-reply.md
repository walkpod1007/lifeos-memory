# SKILL-tts-reply.md
# 龍蝦 TTS 語音回覆規範（LB-016R）

建立日期：2026-02-23
依賴：Gemini API Key、gog、ffmpeg、LINE Push API

---

## 1. 觸發條件

| 情境 | 行為 |
|------|------|
| 用戶傳語音訊息進來 | **必定**以語音回覆（聲音進、聲音出） |
| 用戶說「用說的」「讀給我聽」「語音回覆」「唸出來」 | 改以語音回覆 |
| 一般文字問題 | **預設**仍為文字回覆，不主動轉 TTS |

**原則：語音回覆是選項，不是預設。**

---

## 2. 完整流程

### 步驟 1：生成文字回覆（正常流程）
先用正常 AI 流程生成文字回覆內容。

### 步驟 2：判斷是否需要語音回覆
滿足觸發條件 → 進入語音流程。

### 步驟 3：ack（若回覆超過 3 秒）
```bash
TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.openclaw/openclaw.json')); print(d['channels']['line']['channelAccessToken'])")
curl -s -X POST https://api.line.me/v2/bot/message/push \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"to\":\"USER_ID\",\"messages\":[{\"type\":\"text\",\"text\":\"🔊 生成語音中...\"}]}"
```

### 步驟 4：執行 TTS
```bash
LAB="$HOME/.openclaw/workspace/projects/line-experience-lab"
bash "$LAB/scripts/voice-reply.sh" "文字內容" "USER_ID"
```

### 步驟 5：不需要再傳文字版本
語音已包含完整內容，不需要重複傳文字訊息（除非用戶要求）。

---

## 3. voice-reply.sh 規格

**位置：** `workspace/projects/line-experience-lab/scripts/voice-reply.sh`

**用法：**
```bash
bash voice-reply.sh "<文字內容>" "<LINE用戶或群組ID>" [輸出路徑.m4a]
```

**流程：**
1. 讀取 `$LAB/.gemini-api-key`
2. 呼叫 `gemini-2.5-flash-preview-tts`（單一說話者，Aoede 音色）
3. 解碼 base64 PCM（**s16le little-endian**, 24kHz, mono｜API mimeType 寫 L16 但實際是 LE）
4. `ffmpeg -f s16le -ar 24000 -ac 1 -i input.pcm -c:a aac -b:a 128k output.m4a`
5. 上傳至 **catbox.moe**（主）或 Google Drive（備援）
6. 傳送 LINE `audio` 訊息（`originalContentUrl` = catbox HTTPS URL）

**音檔儲存：** `workspace/media-cache/{TIMESTAMP}-tts-reply.m4a`

---

## 4. Gemini API Key 設定

```bash
echo "YOUR_GEMINI_KEY_HERE" > ~/.openclaw/workspace/projects/line-experience-lab/.gemini-api-key
```

**注意：** `.gemini-api-key` 含敏感資訊，**不列入 lobstercore 備份包**，系統還原後需手動重建。

---

## 5. LINE audio message 說明

LINE 音訊訊息規格：
- `type`: `audio`
- `originalContentUrl`: 公開 HTTPS URL，直接回傳音頻內容
- `duration`: 毫秒（最長 300000 = 5 分鐘）
- 格式支援：m4a（AAC）、mp3

**公開 URL 策略：**
- 優先使用 Google Drive 公開分享連結
- URL 格式：`https://drive.google.com/uc?export=download&id={fileId}&confirm=1`
- 已驗證：設定 `--to=anyone --role=reader` 後，URL 無需登入即可存取

---

## 6. 長度限制

| 情境 | 處理方式 |
|------|---------|
| 文字 ≤ 4000 字元 | 正常 TTS |
| 文字 > 4000 字元 | 截斷至 4000 字元，附上「(已截斷)」說明 |
| 音頻 > 5 分鐘 | ffmpeg 輸出後 duration 上限 300000ms |

---

## 7. 錯誤處理

| 錯誤 | 處理 |
|------|------|
| Gemini API 失敗 | log 錯誤，fallback 改傳文字訊息 |
| ffmpeg 轉換失敗 | log 錯誤，fallback 改傳文字訊息 |
| Drive 上傳失敗 | log 錯誤，退出（LINE 無法播放本機路徑） |
| LINE API 失敗 | log HTTP code，不重試（reply token 限制） |

---

## 8. 依賴確認

```bash
which ffmpeg && ffmpeg -version 2>&1 | head -1     # 需要 ffmpeg
which ffprobe                                        # 需要 ffprobe（通常隨 ffmpeg）
which gog && gog --version                           # 需要 gog v0.11.0+
gog auth list                                        # 確認 user2@example.com 已登入
ls ~/.openclaw/workspace/projects/line-experience-lab/.gemini-api-key  # 金鑰存在
```

---

## 9. 已知限制

- LINE audio 訊息需要公開 HTTPS URL，本機路徑不可用
- Google Drive 大型檔案有「病毒掃描警告」確認頁，小型 TTS 音頻（< 1MB）通常無此問題
- `confirm=1` 參數繞過確認頁面
- LINE 語音播放 UI 顯示為麥克風圖示（系統音訊），非 LINE 特有 UI

---

*最後更新：2026-02-23（LB-016R）*

## 輸出規則
TTS 完成後，必須使用 Flex Message 回覆，模板路徑：
~/.openclaw/workspace/projects/line-experience-lab/templates/tts-response.json
讀取模板 → 填入音訊 URL 與原始文字 → 用 LINE reply API 發送。
失敗時使用 templates/task-failed.json。
不得用純文字回覆 TTS 結果。
