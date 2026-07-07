# Life-OS Memory — 給 Claude Code 的外掛記憶層

很多人有自己的工作方式——缺的是**記憶管理**。

這個 repo 不教你怎麼工作。它做一件事：讓你的 [Claude Code](https://claude.com/claude-code) **記得住**——

- 🧠 踩過的坑**當場寫成坑卡**，下次不重踩
- 🧠 session 撞牆前把結論寫成 `handoff.md` 交接給下一個 session，**上下文不靠 compact 活命**
- 🧠 長期記憶是**可讀、可版控的 Markdown**（`MEMORY.md` 索引＋單卡單事實的記憶卡），不是壓縮到失真的對話摘要
- 🧠 寫進去的東西**搜得回來**：本機向量檢索（BM25＋embedding＋rerank），不用雲端服務

> Your workflow stays yours; this repo manages the memory. Docs in Traditional Chinese.

一切從一套天天在跑的個人自動化系統（Life-OS）長出來，不是紙上設計。

## 現在包裡有什麼

**造技能三件套**（即裝即用，零設定）——「把你自己的工作方式教給 Claude」的入口：

- 「把我這份 SOP 文件變成一個 skill」→ `doc-to-skill` 蒸餾成正式 SKILL.md
- 「幫我從零做一個 XX skill」→ `skill-author` 標準流程含紅隊審查
- 「網路上抓的這個 skill 安全嗎？」→ `skill-vetting` 審查後才格式化安裝

工作方式是你的：用這三個把它教給 Claude，而不是套別人的模板。

## 記憶層（整理中，本 repo 的主體）

原系統驗證過的完整記憶機制，正在去識別化、參數化，陸續進 repo：

| 元件 | 做什麼 |
|---|---|
| 10 分鐘摘要 | launchd/cron 每 10 分鐘把對話新增段摘要成 daily Markdown，session 死了記憶不死 |
| 坑卡機制 | 踩坑當場寫卡（格式規範＋引用流程），錯誤變成資產 |
| atom 記憶卡 | 單卡單事實＋`MEMORY.md` 索引，長期記憶可讀可版控 |
| 向量檢索 | 用公開套件 [`@tobilu/qmd`](https://www.npmjs.com/package/@tobilu/qmd)（`npm i -g @tobilu/qmd`）：本機 BM25＋向量＋LLM rerank |
| handoff 交接 | session 收尾寫 SUMMARY/CURRENT/NEXT/LESSON，新 session 開場即接手 |
| supervisor / watchdog | session 常駐、token 撞牆自動收尾重啟的護欄 |

設計原則：**不裝 Obsidian（或任何筆記軟體）就能啟動**——全部落在普通資料夾裡的 Markdown；**裝了就動得起來**——跑不動的東西不上架。

## 在哪裡能用

| 環境 | 能用嗎 |
|---|---|
| Claude Code CLI(終端機 `claude`) | ✅ |
| Claude 桌面 App 內建的 Claude Code | ✅ 同一個 `~/.claude/skills`，裝一次兩邊生效 |
| VS Code / JetBrains 的 Claude Code 插件 | ✅ 同上 |
| claude.ai 網頁對話 | ❌ 記憶層要在你的機器上落檔與排程，網頁沙箱摸不到 |

## 路徑 A — 全新 Mac 從零開始

```bash
# 1. Homebrew（macOS 套件管理器）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Node.js（Claude Code 跑在上面）
brew install node

# 3. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 4. 登入（開瀏覽器走 OAuth，需要 Claude 帳號）
claude
```

跑到第 4 步能進入對話畫面，就接著走路徑 B。

> 系統需求：macOS 13 以上，Apple Silicon 與 Intel 皆可。

## 路徑 B — 已有 Claude Code，裝技能（一分鐘）

從 GitHub 直接 clone（`~/.claude/skills` 尚不存在時最順）：

```bash
git clone <本 repo 的 URL> ~/.claude/skills
```

或下載 Release 的 `lifeos-*.tgz` 解壓：

```bash
mkdir -p ~/.claude/skills
tar xzf lifeos-*.tgz -C ~/.claude/
```

技能落在 `~/.claude/skills/<name>/`，Claude Code 啟動時自動發現，不用改設定。驗證：開一個 `claude` 對話，說「把這份文件變成一個 skill」，能觸發 `doc-to-skill` 就裝好了。

## 佔位符對照

打包時已把原系統的識別資訊換成佔位符，遇到時替換成你自己的：

| 佔位符 | 換成什麼 |
|---|---|
| `user@example.com` / `user2@example.com` | 你的 email |
| `<YOUR_DOMAIN>` | 你的網域 |
| `$HOME` | 多數情境 shell 會自動展開，寫死處換成你的家目錄 |

## 已知邊界

- 這些內容從一套活的個人系統萃取，內文帶原系統的路徑與流程慣例；不合用直接改 `SKILL.md`，它就是普通 Markdown。
- 出包前經過自動 scrub 與 release gate（無真實 ID、email、私鑰、內網位址殘留）；若發現殘留，請開 issue 回報。
- 各元件引用的外部工具授權依其原專案；本包內容依 repo 的 LICENSE。

## 沿革

- 2026-07-07：首發 35 個 skills → 同日重定位為**純記憶包**並改名 `lifeos-memory`（原 `lifeos-skills`，舊網址自動轉址）。非記憶類技能已下架，git 歷史可考。
