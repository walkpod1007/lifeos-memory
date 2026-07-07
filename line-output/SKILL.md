---
name: line-output
description: Choose LINE reply format. Plain text for chat, Flex Message cards for structured results, TTS for voice, image generation for pictures.
metadata: {"clawdbot":{"emoji":"📤"}}
---

# LINE 輸出能力邊界（line-output）

> 觸發時機：需要選擇最適合的 LINE 回覆方式時（文字 / 圖片 / 語音 / Flex / 影片）

---

## LINE 能做 ✅ 和不能做 ❌

| 能做 | 不能做 |
|------|--------|
| 文字訊息 | PDF 附件 |
| 圖片（URL 公開可存取）| 自定義貼圖 |
| 音訊（URL 公開可存取，m4a/mp3）| 確認已讀 |
| 影片（URL，最大 200MB）| 取得使用者 LINE ID（隱私）|
| Flex Message（結構化卡片）| Markdown 格式（LINE 不渲染）|
| Quick Reply 按鈕 | Code block / stack trace |
| Loading Animation | 超過 5 個 message object |

---

## 輸出方式選擇原則

**字數與段落規範（強制）：**
- 單則訊息上限 300 字（盡可能詳細平實回答，不刪減關鍵資訊）
- 每 60-80 字為一個段落（空一行），讓人類好閱讀
- 超過 300 字的資訊，拆成「核心結論（< 300 字）」+「詳情等我再問」
- **禁止 🦞 footer／emoji 簽名收尾**：使用者已明確要求不要在回覆結尾固定加龍蝦或任何 emoji 簽名（2026-06-14）。內文有需要時可用 emoji，但不要當每則訊息的固定尾巴。

**回覆通道規範（強制）：**
- **一律用 `reply`**，`push` 只當最後手段（reply_token 過期才用）。push 會吃月額度，濫用會月中就耗盡。
- reply_token 有效 30 秒：收到訊息後，能在 30 秒內收尾的任務，**一次 reply 把結果給完**，不要拆成「ack + push 結果」兩則。
- 真要長跑（>30 秒）才被迫 push：先評估能否「先一句 reply 帶走、結果等下一輪再講」，盡量避免 push。
- 群組 push 用 group_id（不是 user_id），否則會跑進 DM。

**簡短回答（< 500 字）→ 純文字**

**結構化資訊（行程 / 清單 / 比較 / 卡片）→ Flex Message**
使用 curl 打 LINE Messaging API push endpoint（`[[buttons:]]` 等 OpenClaw 指令在 LINE 群組不生效）。各媒體類型的 Flex 模板見對應 Skill 的 references/ 資料夾。

**使用者要求「唸給我聽」或語音更自然的場景 → TTS**
工具：`bash ~/life-os/scripts/voice-reply.sh "<文字>"`
⚠️ 必須用 exec(background=true) 執行！
音檔存放：`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/60_Deliverables/audio/`
公開 URL：`https://<YOUR_DOMAIN>/60_Deliverables/audio/{檔名}`
回覆方式：文字回覆底部附 🔊 vault URL（一則搞定，零 Push）

**使用者要求「畫 / 生成圖片」→ Imagen 4 / DALL-E 3**
工具：`bash ~/life-os/scripts/image-gen.sh "<描述>" "<LABEL>"`
⚠️ 必須用 exec(background=true) 執行！
圖片存放：`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/90_System/Inbox/gen-{日期}-{label}.png`
公開 URL：`https://<YOUR_DOMAIN>/90_System/Inbox/{檔名}`
回覆方式：存 pending-result（type=mediaplayer）→ 下一則使用者訊息用 reply token 送 [[media_player:]]

**使用者上傳圖 + 要「風格類似」→ codex-image 風格化生圖**
工具：`REPLY_TOKEN="<replyToken>" USER_PROMPT="<風格描述>" bash ~/life-os/scripts/line-stylegen.sh`
⚠️ 必須用 exec(background=true) 執行！吃使用者上傳圖當 style reference（codex --image），輸出上傳 Google Drive。
回覆方式：存 pending-result（**type=text_link**，caption 含 Drive 連結）→ 下一則使用者訊息把 caption 當**純文字 reply**（內含 Drive 連結）。
⚠️ type=text_link **不要**走 [[media_player:]]——Drive 分享連結非直連圖檔，無法 inline 顯示，只能回文字連結。零 Push，全走 Reply。

**STT（語音轉文字）**
工具：OpenAI Whisper API（curl，不需要裝套件或 CLI）
```bash
source ~/.claude/.env
curl -s https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F model="whisper-1" -F file="@/tmp/stt-input.wav" -F language="zh"
```

**長任務通用原則：**
所有長任務使用 exec(background=true) + shell 腳本，呼叫 REST API。
不依賴 Gemini CLI（只能處理純文字，不能處理音檔/圖檔）。
產出物存 Vault（Inbox 或 Deliverables），拿公開 URL。零 Push，全走 Reply。

**Postback 按鈕通用規則（強制）：**
所有 Flex 卡片中的 postback 按鈕，必須加 `"displayText": "<按鈕 label 文字>"`。
沒有 displayText = 按下後聊天室靜默，用戶不知道有沒有按到 = 輸出格式錯誤。

**絕對不在 LINE 輸出：**
- Markdown code block（\`\`\`）
- JSON 原始格式
- Stack trace / 錯誤堆疊
- 表格（用 Flex 代替）
- 超過 2000 字的回覆（分段或用 Gist）

---

## 回覆方式與推播額度

| 方式 | 成本 | 限制 |
|------|------|------|
| Reply（用 replyToken）| 免費 | replyToken 有效約 30-60 秒（以 30 秒內用掉為原則），只能用一次 |
| Push（主動推播）| 計入月額度 | 免費方案 200 則/月 |

**原則：能用 reply 就用 reply**

---

## 3 秒原則 + Loading Animation

任何操作超過 3 秒，優先呼叫 Loading Animation（不吃 reply/push）。

⚠️ **「處理中，請稍候...」文字 ACK 只在 push 額度健康時允許**。push 429 期間／延遲交付管線生效時（見 capture SKILL §LINE 回覆管線化）**禁用**——那會把唯一的 reply token 打在零資訊上；改用 Loading Animation ＋ 把 reply 留給實質內容。

Loading Animation API：
```bash
TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.claude/channels/line/.env')); print(d['channelAccessToken'])")
curl -s -X POST https://api.line.me/v2/bot/chat/loading/start \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"chatId":"<GROUP_OR_USER_ID>","loadingSeconds":20}'
```

---

## 常用 GROUP ID

- 主對話群組：`<LINE_GROUP_ID>`
- 系統通知群組：`<LINE_GROUP_ID>`
- LINE-talk（claude.ai chat 風格，由 project folder `ws/line-talk/` 處理，**不走本 skill 的 300 字 / 🦞 footer / 任務狀態尾巴規則**）：`<LINE_GROUP_ID>`

---

## 完整參考文件（references/）

- `references/SKILL-tts-reply.md` — TTS 語音輸出完整流程（含 catbox.moe 說明）
- `references/SKILL-image-gen.md` — Imagen 4 生圖完整流程
- `references/SKILL-flex-templates.md` — 16 種 Flex 訊息模板
- `references/SKILL-task-manager.md` — 非同步長任務推播策略

原始位置：`~/life-os/scripts/`

---

## 任務狀態尾巴（純文字 reply 專用）

**資料源＝主 session 對話內佇列**（背景 Agent/工單/捕捉 pending 等，session 自己知道的任務）。
（歷史註記 2026-07-05：本節原設計讀 `~/life-os/scripts/task-queue.json`，紅隊查證該檔從未存在、無任何腳本讀寫——紙上機制，已改為對話內佇列為準；json 路徑保留作未來實作預留，實作前不得再寫「讀取」字樣。）

組裝規則：
- 有任何任務（running / queued / 本輪剛完成未告知的 done / failed）→ 在回覆結尾加狀態列
- 完全沒有任務 → 不加，保持乾淨
- 跨 session：✅/❌ 的「已顯示過」狀態在 session 重啟後會蒸發，重啟首輪寧可重列一次也不要漏列

狀態列格式：
─────────────
🔄 [任務名稱] ← running，每次都顯示
⏳ [任務名稱] ← queued/排隊中（2026-07-05 使用者裁示新增；含對話內排隊項與 capture pending 交付項，不限 task-queue.json）
✅ [任務名稱] ← done，acked: false 時顯示一次
❌ [任務名稱] ← failed，acked: false 時顯示一次
⛔ [任務名稱] ← cancelled，acked: false 時顯示一次

附加後，本輪顯示過的 done / failed / cancelled 下輪不再列（✅ 一次即清，2026-07-05 使用者裁示：不要累積綠勾勾牆；將來 task-queue.json 實作時對應 acked: true）。

限制：
- 只適用於純文字 reply，Flex 回覆不加
- 狀態列不超過 5 筆（優先序：⏳ pending 交付項保底 1 席 → running → 其餘依先來後到）

## Gotchas
- 執行前先確認前置檔案/旗標存在；缺少時直接回報並停止，不要硬做。
- 需要改檔時先備份（.bak），避免錯誤覆寫不可回復。
- 回覆外部訊息前，先完成核心產出檔落地，避免「只說完成但無檔案」。
- 若模型或 API 出現 rate limit / 400 錯誤，改用備援模型並重跑，不要把空跑當成功。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
