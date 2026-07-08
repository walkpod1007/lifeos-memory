<a id="en"></a>

# Life-OS Memory — a plug-in memory layer for Claude Code

**English** | [繁體中文 ↓](#zh-tw)

Most people already have their own way of working — what's missing is **memory management**.

This repo doesn't tell you how to work. It does one thing: it makes your [Claude Code](https://claude.com/claude-code) **remember** —

- 🧠 Every mistake gets written down as a **pitfall card** on the spot, so the same pit never bites twice
- 🧠 Preferences you've stated and decisions you've made become **atomic memory cards** — one fact per card, readable, editable, version-controllable
- 🧠 Conversations are **auto-summarized every 10 minutes** into daily logs, so the memory survives even when the session dies
- 🐕 When token usage is about to hit the limit, a watchdog **writes a handoff file and respawns a fresh session** that picks up where the old one left off — no relying on context compaction to survive
- 🔍 Everything you store is **searchable**: optional local vector search (BM25 + embedding + rerank), nothing gets uploaded to the cloud

Your workflow stays yours; this repo only manages the memory.

All of it grew out of a personal automation system (Life-OS) that runs every single day — it is not a paper design.

## What's in the box

**Memory layer (the main body of this repo, shipped):**

```
install.sh                    One-command installer (dependency check → create dirs → schedule jobs → install claw → smoke test)
memory-harness/scripts/       claw (session launcher), watchdog (token guard),
                              gen-handoff (handoff writer), realtime-summary (10-minute summarizer)
memory-cards/SKILL.md         How to write memory cards (atomic card + pitfall card formats and citation flow)
tests/                        Sandboxed test suite (33 install checks + 25 claw checks; ships only when every one passes)
```

**Skill-making trio** (ready to use) — the entry point for "teaching Claude your own way of working":

- "Turn this SOP document of mine into a skill" → `doc-to-skill` distills it into a proper SKILL.md
- "Build me a skill for X from scratch" → `skill-author`, a standard pipeline with red-team review built in
- "Is this skill I grabbed off the internet safe?" → `skill-vetting` reviews it before formatting and installing

## Memory layer — requirements

- macOS or Linux (Windows via WSL)
- [Claude Code CLI](https://claude.com/claude-code) (`npm i -g @anthropic-ai/claude-code`, then run `claude` once to log in)
- `python3` (built into macOS)
- `timeout` (on macOS run `brew install coreutils`; usually built into Linux)
- Optional: [qmd](https://www.npmjs.com/package/@tobilu/qmd) (`npm i -g @tobilu/qmd`) — with it your memory gets semantic search; without it, plain grep still works

## Memory layer — install

```bash
git clone https://github.com/walkpod1007/lifeos-memory.git
cd lifeos-memory
./install.sh          # Asks two questions: where to put the memory directory (default ~/lifeos-memory),
                      # and whether to write the CLAUDE.md boot block (recommended — without it
                      # Claude won't reach for the memory on its own)
```

After installation you'll have:

- `~/lifeos-memory/` memory directory (daily logs, handoff files, memory cards)
- A conversation-summary job that runs every 10 minutes (launchd on macOS, cron on Linux)
- The `claw` command (installed to `~/.local/bin`; if that's not on your PATH, add the line shown at the end of the install)
- A BEGIN/END-marked boot block in `~/.claude/CLAUDE.md` (the original file is backed up before writing;
  the block auto-loads the `@MEMORY.md` index plus four usage rules — this block is what makes it work right after install)

## Memory layer — use

```bash
cd your-project
claw            # start work sessions with claw instead of claude
```

Everything else works exactly like `claude`. Two extra things happen in the background:

1. **Auto-summary**: every 10 minutes, the key points of the conversation are written into `~/lifeos-memory/daily/`
2. **Handoff and respawn**: when token usage crosses the 150,000 threshold, it automatically writes a handoff file → ends the old session →
   starts a new session that reads the handoff and continues. You'll see the session restart; the work doesn't get interrupted.

To make every session start with its memory loaded, add one line to your project's `CLAUDE.md`:

```
@~/lifeos-memory/MEMORY.md
```

For how to write memory cards (facts you want kept, pits already stepped in), see `memory-cards/SKILL.md`.

## Memory layer — uninstall

```bash
./install.sh --uninstall   # removes the scheduled jobs and the claw command; your memory data stays untouched
```

## Memory layer — troubleshooting

- **claw says it can't find claude**: the Claude Code CLI isn't installed, or it isn't on PATH
- **Summaries don't show up**: run `claude` once to confirm you're logged in; on macOS check
  `launchctl print gui/$(id -u)/com.lifeos-memory.realtime-summary`
- **It stops after several respawns in a row**: that's the storm brake (3 deaths within 60 seconds stops the loop); check `~/lifeos-memory/.logs/`, then run `claw` manually
- Anything else: open an issue and attach the matching log from `~/lifeos-memory/.logs/`

## Skill-making trio — install

If you already have Claude Code, this takes about a minute. Copy the three skill directories into `~/.claude/skills/`:

```bash
mkdir -p ~/.claude/skills
for s in doc-to-skill skill-author skill-vetting; do
  cp -R "$s" ~/.claude/skills/
done
```

The skills land in `~/.claude/skills/<name>/` and Claude Code discovers them on startup — no config changes needed. To verify: open a `claude` conversation and say "turn this document into a skill"; if `doc-to-skill` triggers, you're all set.

## Starting from a brand-new Mac

```bash
# 1. Homebrew (macOS package manager)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Node.js (Claude Code runs on it)
brew install node

# 3. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 4. Log in (opens a browser for OAuth; needs a Claude account)
claude
```

Once step 4 gets you into a conversation, continue with the install steps above.

> System requirements: macOS 13 or later, Apple Silicon or Intel both fine.

## Where it works

| Environment | Works? |
|---|---|
| Claude Code CLI (`claude` in a terminal) | ✅ |
| Claude Code built into the Claude desktop app | ✅ same `~/.claude/skills` — install once, works in both |
| Claude Code extensions for VS Code / JetBrains | ✅ same as above |
| claude.ai web chat | ❌ the memory layer needs files and scheduled jobs on your machine; the web sandbox can't reach them |

## Placeholder reference

Identifying information from the original system was replaced with placeholders at packaging time. Swap in your own where you see them:

| Placeholder | Replace with |
|---|---|
| `user@example.com` / `user2@example.com` | your email |
| `<YOUR_DOMAIN>` | your domain |
| `$HOME` | your shell usually expands this automatically; where it's hard-coded, use your home directory |

## Known boundaries

- This content was extracted from a living personal system, so paths and process conventions from the original remain in the text; if something doesn't fit your setup, just edit the `SKILL.md` — it's plain Markdown.
- Everything went through automated scrubbing and a release gate before shipping (no real IDs, emails, private keys, or internal addresses left behind); if you do find a leftover, please open an issue.
- External tools referenced by each component keep their own licenses; the contents of this package follow the repo's LICENSE.

## History

- 2026-07-08: **Memory layer shipped** — one-command install.sh, 10-minute summaries, handoff files, memory card formats, single-session token watchdog (claw). Shipped after all 58 sandbox tests passed plus dogfooding in a clean environment.
- 2026-07-07: First release of 35 skills → repositioned the same day as a **pure memory pack** and renamed to `lifeos-memory` (formerly `lifeos-skills`; old URLs redirect). Non-memory skills were removed; the git history has it all.

---

<a id="zh-tw"></a>

# Life-OS Memory — 給 Claude Code 的外掛記憶層

[English ↑](#en) | **繁體中文**

很多人有自己的工作方式——缺的是**記憶管理**。

這個 repo 不教你怎麼工作。它做一件事：讓你的 [Claude Code](https://claude.com/claude-code) **記得住**——

- 🧠 踩過的坑**當場寫成一張踩坑卡**，下次不會再踩
- 🧠 講過的偏好、拍板過的決定，落成一張張 **atom 記憶卡**——一件事一張卡，看得懂、改得動、可以進版控
- 🧠 對話**每 10 分鐘自動摘要**成 daily 日誌，就算 session 掛掉，記憶還留著
- 🐕 token 快撞到限額之前，看門狗**自動寫好交接檔、重新開一個 session** 接著做，不用靠 compact 壓縮硬撐
- 🔍 寫進去的東西**搜得回來**：可以選裝本機向量檢索（BM25＋embedding＋rerank），資料不需要上傳雲端

你的工作方式還是你的，這個 repo 只負責記憶。

一切從一套每天都在跑的個人自動化系統（Life-OS）長出來，不是紙上設計。

## 現在包裡有什麼

**記憶層（本 repo 主體，已上架）**：

```
install.sh                    一鍵安裝（依賴檢查→建目錄→掛排程→裝 claw→冒煙測試）
memory-harness/scripts/       claw（session 啟動器）、watchdog（token 看門狗）、
                              gen-handoff（交接檔）、realtime-summary（10 分鐘摘要）
memory-cards/SKILL.md         記憶卡寫法（atom 卡＋踩坑卡格式與引用流程）
tests/                        沙盒測試套件（install 33 項、claw 25 項，全部通過才出包）
```

**造技能三件套**（即裝即用）——「把你自己的工作方式教給 Claude」的入口：

- 「把我這份 SOP 文件變成一個 skill」→ `doc-to-skill` 蒸餾成正式 SKILL.md
- 「幫我從零做一個 XX skill」→ `skill-author` 標準流程，內建紅隊審查
- 「網路上抓的這個 skill 安全嗎？」→ `skill-vetting` 審查過了才格式化安裝

## 記憶層 — 需要什麼

- macOS 或 Linux（Windows 請用 WSL）
- [Claude Code CLI](https://claude.com/claude-code)（`npm i -g @anthropic-ai/claude-code`，裝完跑一次 `claude` 完成登入）
- `python3`（macOS 內建）
- `timeout`（macOS 跑 `brew install coreutils`；Linux 通常內建）
- 可選：[qmd](https://www.npmjs.com/package/@tobilu/qmd)（`npm i -g @tobilu/qmd`）——裝了記憶可以做語意搜尋，沒裝就用 grep

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
  區塊內含 `@MEMORY.md` 自動載入索引＋四條使用規則——這塊就是「裝了就會動」的關鍵）

## 記憶層 — 使用

```bash
cd 你的專案
claw            # 用 claw 代替 claude 開工作 session
```

其他都跟平常用 `claude` 一樣。差別在背景多了兩件事：

1. **自動摘要**：每 10 分鐘把對話重點寫進 `~/lifeos-memory/daily/`
2. **交接重啟**：token 用量超過 150,000 門檻時，自動寫交接檔 → 結束舊 session →
   開新 session 並讓它讀交接檔接續工作。你會看到 session 重啟，工作不會中斷。

想讓每個 session 開場就帶著記憶，在專案的 `CLAUDE.md` 加一行：

```
@~/lifeos-memory/MEMORY.md
```

記憶卡怎麼寫（讓 Claude 記住事實、記住踩過的坑）見 `memory-cards/SKILL.md`。

## 記憶層 — 卸載

```bash
./install.sh --uninstall   # 移除排程與 claw 指令；記憶資料不動
```

## 記憶層 — 出問題

- **claw 說找不到 claude**：Claude Code CLI 沒裝，或不在 PATH
- **摘要沒出現**：先跑一次 `claude` 確認登入態；macOS 查
  `launchctl print gui/$(id -u)/com.lifeos-memory.realtime-summary`
- **連續重啟幾次之後停住**：這是防風暴煞車（60 秒內死 3 次就停），查 `~/lifeos-memory/.logs/` 再手動跑 `claw`
- 其他狀況：開 issue，附上 `~/lifeos-memory/.logs/` 裡對應的 log

## 造技能三件套 — 安裝

已經有 Claude Code 的話一分鐘裝完。把三個技能目錄放進 `~/.claude/skills/`：

```bash
mkdir -p ~/.claude/skills
for s in doc-to-skill skill-author skill-vetting; do
  cp -R "$s" ~/.claude/skills/
done
```

技能落在 `~/.claude/skills/<name>/`，Claude Code 啟動時自動發現，不用改設定。驗證方式：開一個 `claude` 對話，說「把這份文件變成一個 skill」，能觸發 `doc-to-skill` 就是裝好了。

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
| Claude Code CLI（終端機 `claude`） | ✅ |
| Claude 桌面 App 內建的 Claude Code | ✅ 同一個 `~/.claude/skills`，裝一次兩邊生效 |
| VS Code / JetBrains 的 Claude Code 插件 | ✅ 同上 |
| claude.ai 網頁對話 | ❌ 記憶層要在你的機器上落檔與排程，網頁沙箱摸不到 |

## 佔位符對照

打包時已把原系統的識別資訊換成佔位符，遇到時替換成你自己的：

| 佔位符 | 換成什麼 |
|---|---|
| `user@example.com` / `user2@example.com` | 你的 email |
| `<YOUR_DOMAIN>` | 你的網域 |
| `$HOME` | 多數情境 shell 會自動展開，寫死的地方換成你的家目錄 |

## 已知邊界

- 這些內容從一套活的個人系統萃取，內文帶著原系統的路徑與流程慣例；不合用直接改 `SKILL.md`，它就是普通 Markdown。
- 出包前經過自動 scrub 與 release gate（沒有真實 ID、email、私鑰、內網位址殘留）；若發現殘留，請開 issue 回報。
- 各元件引用的外部工具授權依其原專案；本包內容依 repo 的 LICENSE。

## 沿革

- 2026-07-08：**記憶層主體上架**——install.sh 一鍵安裝、10 分鐘摘要、handoff 交接、記憶卡格式、單 session token 看門狗（claw）。沙盒測試 58 項全部通過＋乾淨環境 dogfooding 驗證後出包。
- 2026-07-07：首發 35 個 skills → 同日重定位為**純記憶包**並改名 `lifeos-memory`（原 `lifeos-skills`，舊網址自動轉址）。非記憶類技能已下架，git 歷史可考。
