---
name: line-dispatcher
description: 解析每則 LINE 事件類型與 payload，路由到處理 skill。觸發：每則 LINE 訊息或事件到達時自動執行
version: "1.0"
created: "2026-04-14"
---

# LINE Dispatcher

> 執行時機：每則 LINE 事件，最優先執行。

---

## 路由表

### message 事件

| message.type | 條件 | 目的地 skill |
|-------------|------|------------|
| `image` | — | `line-media` → 圖片 Quick Reply 流程 |
| `audio` | — | `line-media` → 語音 STT 流程 |
| `video` | — | `line-media` → 影片流程 |
| `file` | — | `line-media` → 文件流程 |
| `location` | — | `line-media` → 地理處理 |
| `sticker` | — | `line-behavior` → 情緒回應 |
| `text` | `source.groupId` == `<LINE_GROUP_ID>`（LINE-talk） | **載入 `ws/line-talk/CLAUDE.md` + `ws/line-talk/memory/MEMORY.md`** → 用 claude.ai chat 風格完整回覆（**跳過 silence-gating**） |
| `text` | 其他群組，未被 @ | `group-silence-gating` → 靜默 |
| `text` | 其他群組，被 @ 但非 @阿普 | `group-silence-gating` → 靜默 |
| `text` | DM | → `skill-routes.md` 觸發條件比對 |
| `text` | 其他群組，被 @阿普 | → `skill-routes.md` 觸發條件比對 |

### postback 事件

| postback.data 前綴 | 說明 | 目的地 |
|-------------------|------|--------|
| `qr_*` | Quick Reply 回呼 | 對應 skill 的 postback 處理段落 |
| `flex_*` | Flex Message action 回呼 | 對應 skill 的 postback 處理段落 |
| 其他 | 通用 postback | 對應 skill 的 postback 處理段落 |

### 其他事件

| 事件類型 | 目的地 |
|---------|--------|
| `follow` | `line-behavior` → 歡迎訊息 |
| `unfollow` | `line-behavior` → 靜默記錄 |

---

## postback data 命名慣例（全系統統一）

- Quick Reply：`qr_<動作名稱>`（例：`qr_stt_reply`、`qr_image_ocr`）
- Flex action：`flex_<動作名稱>`（例：`flex_save_note`、`flex_confirm_delete`）
- 不要用其他前綴，dispatcher 靠前綴區分來源

---

## 使用方法

1. 讀取 LINE 事件類型（`message` / `postback` / `follow` 等）
2. 對照路由表
3. 明確呼叫目的地 skill，傳入完整事件 context
4. 不輸出任何訊息給使用者

## 注意事項

- LINE Flex Message 和 Quick Reply 的 callback 都走 `postback` 事件，靠 `data` 欄位的前綴區分
- 群組訊息：先判斷是否被 @ 才決定是否路由到 skill-routes.md
- LINE 媒體有 30 分鐘失效限制，dispatcher 路由到 line-media 後，line-media 應立即下載

## 重要：工具探查禁令

**禁止讀取 `.mcp.json`、`mcp-line.json` 或任何 config 檔來判斷工具是否可用。**

可用工具列表由 session 啟動時注入，是唯一 source of truth。直接呼叫 `get_pending`、`reply`、`push` 等工具——如果工具不存在，呼叫本身就會報錯，那才是真的缺失。讀 config 檔推斷工具清單是錯誤的推理路徑。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
