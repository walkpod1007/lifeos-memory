# Life-OS Memory — 給 Claude Code 的外掛記憶層

很多人有自己的工作方式——缺的是**記憶管理**。

這個 repo 不教你怎麼工作。它做一件事：讓你的 [Claude Code](https://claude.com/claude-code) **記得住**——

- 🧠 踩過的坑**當場寫成坑卡**，下次不重踩
- 🧠 講過的偏好、拍板過的決定，落成一張張 **atom 記憶卡**——一事一卡，可讀、可改、可版控
- 🧠 對話**每 10 分鐘自動摘要**成 daily 日誌，session 死了記憶不死
- 🐕 token 撞頂前**自動寫交接檔並重生新 session** 接著做，上下文不靠 compact 活命
- 🔍 寫進去的東西**搜得回來**：可選裝本機向量檢索（BM25＋embedding＋rerank），不經雲端

> Your workflow stays yours; this repo manages the memory. Docs in Traditional Chinese.

一切從一套天天在跑的個人自動化系統（Life-OS）長出來，不是紙上設計。

## 現在包裡有什麼

**記憶層（本 repo 主體，已上架）**：

```
install.sh                    一鍵安裝（依賴檢查→建目錄→掛排程→裝 claw→冒煙測試）
memory-harness/scripts/       claw（session 啟動器）、watchdog（token 狗）、
                              gen-handoff（交接檔）、realtime-summary（10 分鐘摘要）
memory-cards/SKILL.md         記憶卡寫法（atom 卡＋坑卡格式與引用流程）
tests/                        沙盒測試套件（install 33 項、claw 25 項，全綠才出包）
```

**造技能三件套**（即裝即用）——「把你自己的工作方式教給 Claude」的入口：

- 「把我這份 SOP 文件變成一個 skill」→ `doc-to-skill` 蒸餾成正式 SKILL.md
- 「幫我從零做一個 XX skill」→ `skill-author` 標準流程含紅隊審查
- 「網路上抓的這個 skill 安全嗎？」→ `skill-vetting` 審查後才格式化安裝

## 記憶層 — 需要什麼

- macOS 或 Linux（Windows 請用 WSL）
- [Claude Code CLI](https://claude.com/claude-code)（`npm i -g @anthropic-ai/claude-code`，裝完跑一次 `claude` 完成登入）
- `python3`（macOS 內建）
- `timeout`（macOS 跑 `brew install coreutils`；Linux 通常內建）
- 可選：[qmd](https://www.npmjs.com/package/@tobilu/qmd)（`npm i -g @tobilu/qmd`）——裝了記憶可以語意搜尋，沒裝就用 grep

## 記憶層 — 安裝

```bash
git clone https://github.com/walkpod1007/lifeos-memory.git
cd lifeos-memory
./install.sh          # 問兩題：記憶目錄放哪（預設 ~/lifeos-memory）、
                      # 要不要寫 CLAUDE.md 開機區塊（建議要，不然 Claude 不會主動用記憶）
```

裝完會有：
- `~/lifeos-memory/` 記憶目錄（daily 日誌、handoff 交接、cards 記憶卡）
- 每 10 分鐘一次的對話摘要排程（macOS 用 launchd、Linux 用 cron）
- `claw` 指令（裝在 `~/.local/bin`，不在 PATH 的話照安裝完的提示加一行）
- `~/.claude/CLAUDE.md` 裡一個 BEGIN/END 標記的開機區塊（寫入前自動備份原檔；
  區塊內含 `@MEMORY.md` 自動載入索引＋四條使用規則——這塊就是「裝了就動」的關鍵）

## 記憶層 — 使用

```bash
cd 你的專案
claw            # 用 claw 代替 claude 開工作 session
```

其他都跟平常用 `claude` 一樣。差別在背景多了兩件事：

1. **自動摘要**：每 10 分鐘把對話重點寫進 `~/lifeos-memory/daily/`
2. **斷頭重生**：token 用量撞 150,000 門檻時，自動寫交接檔 → 結束舊 session →
   起新 session 並讓它讀交接檔接續工作。你會看到 session 重啟，工作不中斷。

讓每個 session 開場就帶著記憶，在專案的 `CLAUDE.md` 加一行：

```
@~/lifeos-memory/MEMORY.md
```

記憶卡怎麼寫（讓 Claude 記事實、記踩過的坑）見 `memory-cards/SKILL.md`。

## 記憶層 — 卸載

```bash
./install.sh --uninstall   # 移除排程與 claw 指令；記憶資料不動
```

## 記憶層 — 出問題

- **claw 說找不到 claude**：Claude Code CLI 沒裝或不在 PATH
- **摘要沒出現**：先跑一次 `claude` 確認登入態；macOS 查
  `launchctl print gui/$(id -u)/com.lifeos-memory.realtime-summary`
- **連續重生後停住**：防風暴煞車（60 秒內死 3 次就停），查 `~/lifeos-memory/.logs/` 再手動 `claw`
- 其他狀況：開 issue 附上 `~/lifeos-memory/.logs/` 裡對應的 log

## 造技能三件套 — 安裝

已有 Claude Code 的話一分鐘裝完。把三個技能目錄放進 `~/.claude/skills/`：

```bash
mkdir -p ~/.claude/skills
for s in doc-to-skill skill-author skill-vetting; do
  cp -R "$s" ~/.claude/skills/
done
```

技能落在 `~/.claude/skills/<name>/`，Claude Code 啟動時自動發現，不用改設定。驗證：開一個 `claude` 對話，說「把這份文件變成一個 skill」，能觸發 `doc-to-skill` 就裝好了。

## 全新 Mac 從零開始

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

跑到第 4 步能進入對話畫面，就接著走上面的安裝步驟。

> 系統需求：macOS 13 以上，Apple Silicon 與 Intel 皆可。

## 在哪裡能用

| 環境 | 能用嗎 |
|---|---|
| Claude Code CLI(終端機 `claude`) | ✅ |
| Claude 桌面 App 內建的 Claude Code | ✅ 同一個 `~/.claude/skills`，裝一次兩邊生效 |
| VS Code / JetBrains 的 Claude Code 插件 | ✅ 同上 |
| claude.ai 網頁對話 | ❌ 記憶層要在你的機器上落檔與排程，網頁沙箱摸不到 |

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

- 2026-07-08：**記憶層主體上架**——install.sh 一鍵安裝、10 分鐘摘要、handoff 交接、記憶卡格式、單 session token 狗（claw）。沙盒測試 58 項全綠＋乾淨環境 dogfooding 通過後出包。
- 2026-07-07：首發 35 個 skills → 同日重定位為**純記憶包**並改名 `lifeos-memory`（原 `lifeos-skills`，舊網址自動轉址）。非記憶類技能已下架，git 歷史可考。
