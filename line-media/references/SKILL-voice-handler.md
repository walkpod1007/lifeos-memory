# SKILL-voice-handler.md
# 龍蝦語音處理流程（LB-004R / LB-016R）— Intent-First 版本

## 1. 收到語音訊息 → Intent-First ACK

**絕對不發 Push ACK**（浪費額度）。用 `[[buttons:]]` 透過 replyToken 回覆（免費）。

### 步驟
1. 立即用 `[[buttons:]]` directive 回覆（佔用 replyToken，1秒內完成）
2. 背景同步啟動 voice-process.sh（非同步，不阻塞）
3. 等 postback，再依選擇處理結果

### ACK 格式
```
[[buttons: 🎙️ 語音辨識中... | 辨識完成後要做什麼？ | 💬 直接回覆:sttReply, 📝 存筆記:toNote]]
```

### voice-process.sh 呼叫
```bash
bash $HOME/.openclaw/workspace/projects/line-experience-lab/scripts/voice-process.sh <MESSAGE_ID> <GROUP_ID> &
```

---

## 2. postback 處理

voice-process.sh 結果儲存在：`/tmp/line-last-stt.json`
格式：`{"messageId":"...","text":"...","lang":"zh-TW","timestamp":"..."}`

### 2a. sttReply（直接回覆）
1. 讀 `/tmp/line-last-stt.json` 取出 `text`
2. 直接作為使用者輸入處理（對話繼續）

### 2b. toNote（存到 Apple Notes）

#### 主路徑：osascript（需 Automation 權限）
```bash
NOTE_TITLE="語音備忘 $(date '+%Y-%m-%d %H:%M')"
NOTE_BODY=$(cat /tmp/line-last-stt.json | python3 -c "import json,sys; print(json.load(sys.stdin)['text'])")
osascript -e "tell application \"Notes\" to make new note at folder \"Notes\" with properties {name:\"$NOTE_TITLE\", body:\"$NOTE_BODY\"}" &
OSPID=$!
sleep 4
if kill -0 $OSPID 2>/dev/null; then
  kill $OSPID
  OSASCRIPT_OK=0  # HUNG → fallback
else
  wait $OSPID
  OSASCRIPT_OK=$?
fi
```

#### Fallback 路徑（osascript 失敗 / 沒有 Automation 權限）
```bash
mkdir -p /tmp/pending-notes
TS=$(date '+%Y%m%d-%H%M%S')
PENDING_FILE="/tmp/pending-notes/$TS-voice.md"
echo "$NOTE_BODY" > "$PENDING_FILE"
# 回覆使用者
echo "📝 Notes.app 需要 Automation 授權，筆記暫存在 $PENDING_FILE，回家後授權即可正常運作。"
```

#### 回覆格式
- 成功：`✅ 已儲存到 Apple Notes「{NOTE_TITLE}」`
- Fallback：`📝 筆記暫存到本機 /tmp/pending-notes/，回家後授權 Notes.app Automation 即可匯入。`

---

## 3. osascript 授權說明（回家時操作）

1. 打開「系統設定 → 隱私權與安全性 → 自動化」
2. 找到 Terminal / openclaw 對應的項目
3. 勾選「Notes」

授權後 `/tmp/pending-notes/` 的所有 `.md` 檔可批次匯入：
```bash
for f in /tmp/pending-notes/*.md; do
  TITLE=$(basename "$f" .md | sed 's/[0-9]*-[0-9]*-//' | sed 's/-voice//')
  BODY=$(cat "$f")
  osascript -e "tell application \"Notes\" to make new note at folder \"Notes\" with properties {name:\"$TITLE\", body:\"$BODY\"}"
done
```

---

## 4. STT 結果持久化（voice-process.sh 已實作）
- 輸出：`/tmp/line-last-stt.json`
- 欄位：`messageId`, `text`, `lang`, `timestamp`
- **postback 必讀此檔案**，不要假設記憶裡有內容

---

## 5. TTS（語音回覆）
- 腳本：`voice-reply.sh`
- 模型：`gemini-2.5-flash-preview-tts`
- 聲音：`Aoede`
- 上傳：catbox.moe（公開 HTTPS）→ LINE audioMessage
