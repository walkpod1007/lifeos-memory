# Changelog

## v2.1.0 — 2026-03-24

### 更新
- Telegram 回覆改為 500 字（3 段落），原本 300 字太短
- Vault 深度摘要 800-1200 字（按內容量決定）
- 存放路徑改為 `00_Inbox/📌_Quick_Refs/`（原本是直接放 00_Inbox/）
- 明確區分 capture（單篇隨機）vs youtube-grabber（訂閱批量→NotebookLM）
- YT/Podcast 單篇也可以走 capture 進 inbox，不強制進 NotebookLM

### 為什麼改
用戶確認：capture 是「朋友分享或自己瀏覽看到想保留的」，跟 NotebookLM 的系統性知識累積是兩回事。

---

## v2.0.0 — 2026-03-24（大重構）

### 新增
- 從 `~/.openclaw/skills/link-capture/` 移植社群平台擷取邏輯
- 支援平台：Threads、X/Twitter、Instagram、Facebook、Dcard、PTT、知乎、Reddit（新增）
- GOTCHAS.md：9 條真實踩坑紀錄（G1-G9），改 skill 前必讀
- refs/ 資料夾：各平台詳細擷取流程（獨立文件，按需載入）
- platform-reddit.md：全新，支援 Reddit MCP 或 JSON API 降級
- obsidian-template.md：統一的 Vault 筆記格式

### 為什麼重構
- v1.0.0 的 capture skill 太簡單，只用 summarize CLI，社群平台完全沒有專屬處理
- 原本的 link-capture 是 LINE/VidClaw 架構，無法直接在 Life-OS 使用
- 整合後：一個 skill 處理所有 URL，不再分兩個技能

### 改了什麼（vs 原 link-capture）
- 移除：LINE 回覆（Step 6）→ 改為 Telegram 回覆
- 移除：Quick Reply（Step 7）
- 移除：VidClaw 任務板（Step 5.5）
- 修正：Vault 路徑改為正確的 Life-OS iCloud 路徑
- 新增：YouTube → youtube-grabber 路由
- 新增：Podcast → podcast-grabber 路由
- 新增：Reddit MCP 支援

### 已知問題 / 待觀察
- Instagram Browser Relay 依賴 Chrome + 外掛，mobile 環境無法使用
- Reddit MCP 尚未安裝，目前降級用 JSON API
- Facebook 擷取成功率不穩定（FB 防爬機制強）
- X API Rate Limit 15 次/15 分鐘，超限自動降級

---

## v1.0.0 — 2026-03-24

- 初始版本，用 summarize CLI 處理一般 URL
- 缺乏社群平台專屬處理

---
> 格式：版本 + 日期 → 改了什麼 → 為什麼 → 已知問題
> 目的：防止迭代後不知道前一版改過什麼又改回去
