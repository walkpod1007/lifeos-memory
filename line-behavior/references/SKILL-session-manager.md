# SKILL-session-manager.md
# Session 管理規則（LB-002R / Route C）

> ⚠️ **OBSOLETE — 保留作歷史參考**
>
> 本檔描述舊路徑（`~/.openclaw/agents/lobster/sessions/`）與舊 token 讀取方式。
> 目前實際使用：
> - Session 目錄：`~/.claude/agents/<agent>/sessions/`
> - LINE token 讀取：`~/.claude/channels/line/.env`
> - 重置流程：見 `skills/session-cleanup/SKILL.md` + `skills/session-reset/SKILL.md`

## 1. 觸發詞偵測

當用戶訊息符合以下任一條件時，觸發「開新對話」流程：

完整匹配或訊息開頭：
- 開新對話
- 清除記憶
- 清除對話
- new chat
- /new
- /reset
- 新對話
- 重新開始
- clear

## 2. 通用 Postback 即時回覆規則（所有 postback 適用）

**收到任何 postback 後，第一件事是立刻發一則純文字回覆，讓用戶知道按鈕有被收到。**

這可以防止用戶感覺「按了沒反應」（因為後續動作如 curl/腳本可能需要數秒）。

格式：
1. 立刻回覆純文字（1 秒內）
2. 執行後續動作（重置腳本、發 Flex 卡等）

各場景即時回覆文字：
- clearSession confirmed: true → 「🔄 正在清除對話記憶...」
- clearSession confirmed: false → 「好的，繼續目前的對話。」
- 任何其他 postback → 「⏳ 處理中...」（通用備援）

## 3. 觸發後流程

### 步驟 1：估算當前對話狀態
- 輪數：從這次 session 開始到現在，粗估 user/assistant 來回次數
- Token 數：粗估（每輪約 500-2000 tokens，可以直接報「~N rounds」）

### 步驟 2：發送確認卡
使用 confirm.json 模板，透過 curl push 發送到當前群組：

```bash
TOKEN=$(cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; print(json.load(sys.stdin)['channels']['line']['channelAccessToken'])")
curl -X POST https://api.line.me/v2/bot/message/push \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "to": "GROUP_ID",
    "messages": [{
      "type": "flex",
      "altText": "確認清除當前對話？",
      "contents": {
        "type": "bubble",
        "header": {
          "type": "box", "layout": "vertical", "backgroundColor": "#FFFBEB",
          "contents": [
            {"type": "text", "text": "SESSION", "size": "xs", "color": "#D97706", "weight": "bold"},
            {"type": "text", "text": "確認清除當前對話？", "size": "md", "weight": "bold", "color": "#111111"}
          ]
        },
        "body": {
          "type": "box", "layout": "vertical",
          "contents": [{"type": "text", "text": "此操作無法復原。當前對話約 {{ROUNDS}} 輪，預估 ~{{TOKENS}} tokens。", "wrap": true, "size": "sm", "color": "#444444"}]
        },
        "footer": {
          "type": "box", "layout": "horizontal", "spacing": "sm",
          "contents": [
            {"type": "button", "style": "primary", "color": "#06C755", "height": "sm",
             "action": {"type": "postback", "label": "✓ 確認清除", "data": "{\"action\":\"clearSession\",\"confirmed\":true}"}},
            {"type": "button", "style": "secondary", "color": "#AAAAAA", "height": "sm",
             "action": {"type": "postback", "label": "取消", "data": "{\"action\":\"clearSession\",\"confirmed\":false}"}}
          ]
        }
      }
    }]
  }'
```

### 步驟 3：收到 postback 回應

postback data 格式（我會直接看到這個字串）：
- 確認：{"action":"clearSession","confirmed":true}
- 取消：{"action":"clearSession","confirmed":false}

#### confirmed: true → 執行重置
1. 執行重置腳本：
   workspace/projects/line-experience-lab/scripts/reset-session.sh <GROUP_ID>
2. 發送 success.json 卡片：

```bash
TOKEN=$(cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; print(json.load(sys.stdin)['channels']['line']['channelAccessToken'])")
curl -X POST https://api.line.me/v2/bot/message/push \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "to": "GROUP_ID",
    "messages": [{
      "type": "flex",
      "altText": "已開新對話",
      "contents": {
        "type": "bubble",
        "header": {
          "type": "box", "layout": "vertical", "backgroundColor": "#F0FDF4",
          "contents": [
            {"type": "text", "text": "SESSION", "size": "xs", "color": "#06C755", "weight": "bold"},
            {"type": "text", "text": "已開新對話", "size": "md", "weight": "bold", "color": "#111111"}
          ]
        },
        "body": {
          "type": "box", "layout": "vertical",
          "contents": [{"type": "text", "text": "有什麼我能幫你的？🦞", "wrap": true, "size": "sm", "color": "#444444"}]
        }
      }
    }]
  }'
```

3. 注意：重置後下一則訊息起，session 將重新開始

#### confirmed: false → 取消
純文字回覆：「好的，繼續目前的對話。」

## 4. 重置腳本說明

腳本位置：workspace/projects/line-experience-lab/scripts/reset-session.sh

用法：
  ./reset-session.sh c8a9cd9709dff693b807f0d02ee086d1b

運作原理：
1. 讀取 ~/.openclaw/agents/lobster/sessions/sessions.json
2. 找到 agent:lobster:line:group:group:<GROUP_ID> 對應的 sessionId
3. 將 ~/.openclaw/agents/lobster/sessions/<sessionId>.jsonl 重命名為 .jsonl.reset.TIMESTAMP
4. OpenClaw 下次收到訊息時會自動建立新的 session

## 5. 已知限制

- 全新 session（session 尚未出現在 sessions.json 中）無法用腳本重置
  → 這種情況下，直接跟用戶說「當前對話已經是全新的」
- /new 或 /reset 指令由 OpenClaw 內建處理，用戶可以直接輸入
- 重置後我（AI）的上下文不會立刻清空，要等到下一輪才完全生效

## 6. 常數

LINE Token: 從 ~/.openclaw/openclaw.json 讀取（channels.line.channelAccessToken）
Token 讀取指令: TOKEN=$(cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; print(json.load(sys.stdin)['channels']['line']['channelAccessToken'])")
Session 目錄: ~/.openclaw/agents/lobster/sessions/
Sessions JSON: ~/.openclaw/agents/lobster/sessions/sessions.json
Session Key 格式: agent:lobster:line:group:group:<lowercase_group_id>
