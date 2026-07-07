# Life-OS Skills — Claude Code 技能包

50 個生產環境長出來的 [Claude Code](https://claude.com/claude-code) agent skills：視覺與文件產出、YouTube/電子書翻譯管線、LINE bot 對話框架、智慧家庭 CLI、Google Workspace 整合、以及一套「skill 工程」方法論（怎麼寫 skill、審 skill、把 SOP 蒸餾成 skill）。

> This is a set of 50 Claude Code agent skills extracted from a personal Life-OS. Docs are in Traditional Chinese; each skill is self-describing via its `SKILL.md`.

## 適用場景

你有一台 Mac（全新或現役皆可），想在本機跑 Claude Code，並一次給它裝上一批現成能力。所有 skill 都在本機執行，不需要伺服器。

依你的起點走對應路徑：

- **已經在用 Claude Code** → 直接跳〔路徑 B〕，一行解壓就裝完
- **全新的 Mac、什麼都還沒裝** → 從〔路徑 A〕開始，十分鐘內帶到技能生效

## 路徑 A — 全新 Mac 從零開始

```bash
# 1. Homebrew（macOS 套件管理器，部分 skill 的外部工具靠它裝）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Node.js（Claude Code 跑在上面）
brew install node

# 3. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 4. 登入（開瀏覽器走 OAuth，需要 Claude 帳號）
claude
```

跑到第 4 步能進入對話畫面，就接著走路徑 B 裝技能。

> 系統需求：macOS 13 以上，Apple Silicon 與 Intel 皆可。

## 路徑 B — 已有 Claude Code，裝技能包（一分鐘）

從 GitHub 直接 clone（`~/.claude/skills` 尚不存在時最順）：

```bash
git clone <本 repo 的 URL> ~/.claude/skills
```

或下載 Release 的 `lifeos-skills-*.tgz` 解壓：

```bash
mkdir -p ~/.claude/skills
tar xzf lifeos-skills-*.tgz -C ~/.claude/
```

技能會落在 `~/.claude/skills/<name>/`，Claude Code 啟動時自動發現，不用改任何設定。驗證：開一個 `claude` 對話，輸入「用 canvas-design 做一張海報」，能觸發就裝好了。

兩個變化型：

- **只裝進單一專案**：放到 `<專案>/.claude/skills/`，技能只在該專案生效
- **不想全裝**：先 clone／解壓到暫存目錄，挑想要的資料夾搬進 `~/.claude/skills/`——每個 skill 一個資料夾，彼此獨立，隨拿隨用

## 哪些即裝即用、哪些要先設定

**零設定即用**（純方法論／prompt 驅動）
`skill-author`、`skill-vetting`、`doc-to-skill`、`task-sop`、`triad-tools`、`rule-change-review`、`runbook`、`code-audit`、`yt-script`、`region-streaming-check`、`tech-product-research`、`theme-factory`、`design-extract`、`magazine-doc`、`canvas-design`（字型庫自帶）

**裝個 CLI 工具就能用**（brew / npm / pip 一行）
`yt-dub`、`yt-sub-translate`、`yt-relay-translate`、`kindle-translate`（yt-dlp / ffmpeg / whisper）、`mac-health`、`cloudflared-tunnel`、`clone-website`、`carousel-gen`、`gdoc-article`

**要帶自己的 API key 或帳號**
`imagen-gen`、`codex-image`、`mini-agent`（各家生成模型的 key）、`gog`、`gmail-triage`（Google OAuth）、`obsidian-capture`、`vault-ops`、`capture`（本機 Obsidian Vault）

**要有對應硬體**
`openhue`（Philips Hue Bridge）、`roborock`、`samsung-smartthings`、`sonoscli`、`xiaomi-home`、`smart-home`（統一入口）

**LINE bot 框架**（見下節）
`line-dispatcher`、`line-behavior`、`line-output`、`line-health`、`line-media`、`line-stt`、`line-tts`、`line-session-check`、`tier1-line-bootstrap`、`switch-channel-model`、`safe-restart`、`session-end`

## 佔位符對照

打包時已把原系統的識別資訊換成佔位符，用到相關 skill 時替換成你自己的：

| 佔位符 | 換成什麼 |
|---|---|
| `<LINE_USER_ID>` / `<LINE_GROUP_ID>` / `<LINE_ROOM_ID>` | 你的 LINE Messaging API 識別碼 |
| `user@example.com` / `user2@example.com` | 你的 email |
| `<YOUR_DOMAIN>` | 你的網域（webhook / tunnel 用） |
| `<LAN_IP>` | 你的內網設備 IP |
| `$HOME` | 多數情境 shell 會自動展開，寫死處換成你的家目錄 |

## 關於 LINE bot 整組 skill

這組是本包最完整的資產：一個以 Claude Code session 為「大腦」的 LINE bot 架構——`line-dispatcher` 解析事件路由、`line-media`/`line-stt`/`line-tts` 處理多媒體、`line-behavior` 定義社交行為、`tier1-line-bootstrap` 端到端建新群組 session。

**注意**：完整運行還需要三樣本包沒有的東西——LINE Messaging API channel（去 LINE Developers 申請）、把 webhook 打回本機的 tunnel（`cloudflared-tunnel` skill 有教）、以及把訊息餵進 Claude Code 的 MCP server 與 supervisor 腳本（屬於 harness 層，計畫另出 `lifeos-harness` 包）。在那之前，這組 skill 可當成完整的架構參考來讀與改作。

## 已知邊界

- 這些 skill 從一套活的個人系統萃取，內文帶有原系統的路徑與流程慣例；不合用的地方直接改 `SKILL.md`，它就是普通 Markdown。
- 出包前經過自動 scrub 與 release gate（無真實 ID、email、私鑰、內網位址殘留）；若仍發現任何殘留，請開 issue 回報。
- 各 skill 引用的外部工具（yt-dlp、ffmpeg、openhue CLI 等）授權依其原專案；本包內容依 repo 的 LICENSE。
