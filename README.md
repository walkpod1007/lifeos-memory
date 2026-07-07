# Life-OS Skills — Claude Code 技能包

裝完這包，你的 [Claude Code](https://claude.com/claude-code) 從「會聊天的終端機」變成「會做事的助理」：

- 🗣「幫我做一張講座海報」→ 幾分鐘後拿到成品 PDF
- 🗣「這支 YouTube 翻成日韓英泰字幕、傳回頻道」→ 一句話跑完整條管線
- 🗣「未讀信哪些要回？」→ 分好優先級擺在你面前
- 🗣「逆向這個網站的設計，給我一份 design tokens」→ 結構化 DESIGN.md 到手

29 個 skills，全部從一套天天在跑的個人自動化系統（Life-OS）長出來。

> 29 production-grown Claude Code agent skills. Docs in Traditional Chinese; each skill is self-describing via its `SKILL.md`.

## 為什麼跟網路上的 skill 合集不一樣

**1. 真系統長出來的。** 每個 skill 都在一套真實系統裡用了幾個月、踩坑修過版，不是 AI 一鍵生成的樣板。你拿到的就是本人在用的完整版本（只去掉個人識別），含踩坑註記與修正史。

**2. 上下文不靠 compact 活命。** Life-OS 的核心設計：session 撞牆前把結論寫成 `handoff.md` 檔案交接給下一個 session，長期記憶是可讀、可版控的 Markdown（`MEMORY.md` 索引 + 記憶卡），而不是壓縮到失真的對話摘要。這批 skill 就是在這種「記憶靠檔案、不靠壓縮」的架構裡被磨出來的；承載這套機制的 harness 層（supervisor / watchdog / handoff 三件套）見 Roadmap，計畫第二波發布。

**3. 會自我繁殖。** 內附「造技能的技能」（`doc-to-skill`、`skill-author`、`skill-vetting`）——把你自己的 SOP 文件蒸餾成正式 skill、從零打造新 skill、審查網路上抓來的 skill。用著用著，你會長出自己的技能包。

## 裝完你可以直接這樣說

技能裝好後不用學指令，在 `claude` 對話裡用人話講需求就會觸發。實際場景：

**🎨 做視覺、做文件**
- 「幫我做一張講座海報，主題是 AI 時代的手工價值」→ `canvas-design` 用設計哲學推導版面與配色，輸出 PNG/PDF，字型庫自帶
- 「把這篇文案做成 IG 九宮格」→ `carousel-gen` 產出風格一致的輪播圖
- 「這份報告幫我套個專業配色」→ `theme-factory` 十組預置主題挑一組或現場生成
- 「逆向這個網站的設計，給我一份 design tokens」→ `design-extract` 產出結構化 DESIGN.md

**📺 YouTube／翻譯管線**
- 「把這支影片的字幕翻成日韓英泰四語並傳回頻道」→ `yt-sub-translate` 一條龍
- 「幫這支影片生成日語配音軌」→ `yt-dub` 從 SRT 到 edge-tts 到 ffmpeg 組軌上傳
- 「我想做一支『無臉頻道』影片，從選題幫我推到可拍腳本」→ `yt-script` 先逆向競品頻道再代寫
- 「這本日文電子書翻成繁中」→ `kindle-translate`

**📬 日常整理**
- 「看一下我的未讀信，哪些要回？」→ `gmail-triage` 分優先級，錢到了沒、貨出了沒優先標出
- 「明天行事曆有什麼？幫我加一個週五交稿的 task」→ `gog`（Gmail/Calendar/Tasks/Sheets/Drive 一支 CLI）

**🔧 工程與運維**
- 「這個 repo 幫我做一次程式碼健檢」→ `code-audit` 架構掃描＋批次審計＋匯報
- 「服務報 502 了」→ `runbook` 自動查 log、定位、輸出結構化報告
- 「我的 Mac 最近怪怪的」→ `mac-health` 本機健檢
- 「這個長任務不要燒 Claude 額度」→ `mini-agent` 派給便宜模型跑

**🧬 造技能的技能（本包的私房菜）**
- 「把我這份 SOP 文件變成一個 skill」→ `doc-to-skill` 蒸餾成正式 SKILL.md
- 「幫我從零做一個 XX skill」→ `skill-author` 標準流程含紅隊審查
- 「網路上抓的這個 skill 安全嗎？」→ `skill-vetting` 審查後才格式化安裝
- 用這三個，你自己的工作流程也能長成自己的技能包

## 在哪裡能用

| 環境 | 能用嗎 |
|---|---|
| Claude Code CLI（終端機 `claude`） | ✅ |
| Claude 桌面 App 內建的 Claude Code | ✅ 同一個 `~/.claude/skills`，裝一次兩邊生效 |
| VS Code / JetBrains 的 Claude Code 插件 | ✅ 同上 |
| claude.ai 網頁對話 | ❌ 這批技能大多要跑本機工具（ffmpeg、家電 CLI、本機檔案），網頁沙箱摸不到你的機器 |

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
`codex-image`、`mini-agent`（各家生成模型的 key）、`gog`、`gmail-triage`（Google OAuth）

**要有對應硬體**
`sonoscli`（Sonos 音響）

## 佔位符對照

打包時已把原系統的識別資訊換成佔位符，用到相關 skill 時替換成你自己的：

| 佔位符 | 換成什麼 |
|---|---|
| `user@example.com` / `user2@example.com` | 你的 email |
| `<YOUR_DOMAIN>` | 你的網域（webhook / tunnel 用） |
| `<LAN_IP>` | 你的內網設備 IP |
| `$HOME` | 多數情境 shell 會自動展開，寫死處換成你的家目錄 |

## Roadmap

原系統還有一組以 Claude Code session 為「大腦」的 LINE bot 框架（事件路由、語音轉文字、TTS、多群組 session 管理），與其依賴的 harness 層（supervisor / watchdog / handoff 三件套）。這兩塊計畫整理好後另行發布。

## 已知邊界

- 這些 skill 從一套活的個人系統萃取，內文帶有原系統的路徑與流程慣例；不合用的地方直接改 `SKILL.md`，它就是普通 Markdown。
- 出包前經過自動 scrub 與 release gate（無真實 ID、email、私鑰、內網位址殘留）；若仍發現任何殘留，請開 issue 回報。
- 各 skill 引用的外部工具（yt-dlp、ffmpeg 等）授權依其原專案；本包內容依 repo 的 LICENSE。
