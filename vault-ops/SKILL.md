---
name: vault-ops
description: Obsidian Vault 組織整理：inbox-archive/vault-health/trash-expire。觸發：整理 inbox、掃 vault、vault 健康度、清 trash
version: "1.0"
created: "2026-04-22"
metadata: {"clawdbot":{"emoji":"🗂️"}}
---

# vault-ops — Obsidian Vault 組織整理

> 三個 routine 手動觸發。主 session 執行（不派 worker —— 涉及 vault 結構變動）。
> 全 routine 一律 **dry-run → 使用者 go → 執行**，不自動動檔。

---

## 政策引用（不複製，只引）

- **Vault 寫入契約**：`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/AGENTS.md`
- **子代理紅線**：`~/life-os/CLAUDE.local.md`
- **衝突時權威**：`CLAUDE.local.md` > `AGENTS.md`

本 skill 只動以下路徑（主 session 授權 create / append / move）：
`00_Inbox/` `10_Projects/<主題>/` `20_Areas/<主題>/` `30_Resources/<主題>/` `50_Research/<主題>/` `60_Deliverables/` `80_apu/atoms/apu/<type>/` `90_System/*` `_trash/` `log.md`

禁碰（雙方紅線）：`.obsidian/` `.git/` 既有 `INDEX.md / _index.md / _MOC.md` 整檔覆寫、`./index.md` 整檔、`AGENTS.md` 整檔、`STATE.md`、`memory/`、`80_apu/atoms/apu/<type>/INDEX.md`（rules-patch.sh 自動維護）。

---

## Convention

### 「刪除」= 移到 `_trash/`（絕不 hard delete）

```bash
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
TARGET_BASE=$(basename "<target>")
mv "<target>" "$VAULT/_trash/${TARGET_BASE}.${TIMESTAMP}"
```

時間戳避免撞名。`_trash/` 是 vault 內資料夾（不是 `.trash/` 或 macOS Trash）。

### iCloud 寫入守則（來自 AGENTS.md）

1. 原子寫：用 Write tool 一次寫完，不要分多次 Edit 同一檔
2. 同批次寫多檔：間隔 ≥ 1 秒（`sleep 1`）
3. 寫完不立即 re-read：等 2-3 秒讓同步穩定
4. 大檔（≥100 KB）寫入後 `sleep 5` 再驗
5. 並行 agent 同寫禁止

### log.md append（契約要求）

任何動到 vault 結構（新建主題資料夾、歸檔、永刪）後，在 `<Vault>/log.md` append 一行：

```
<YYYY-MM-DDTHH:MM:SSZ> vault-ops <routine> — <一句話動作摘要>
```

---

## Routine 1: inbox-archive

**觸發詞**：「整理 inbox」「inbox 歸檔」「inbox 分類」「清 inbox」「vault-ops inbox-archive」

**目標**：把 `00_Inbox/` 的筆記分類後遷到 PARA 對應資料夾。

**原則**：Inbox 是暫存區，**所有東西（.md 檔 + 子資料夾 + 空殼）都必須被處理**，不存在「子結構獨立所以跳過」這種特權。唯一例外：vault 系統檔（`.obsidian/` `.git/`）。

**前置檢查**

```bash
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
cd "$VAULT/00_Inbox"
# 列根檔 + 子資料夾 + 子資料夾大小
find . -maxdepth 1 -type f -name "*.md" | sort
echo "---"
for d in */; do
  [ -d "$d" ] || continue
  CNT=$(find "$d" -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$d ($CNT 檔)"
done
```

**分類決策順序**（規則先行，省 LLM token）：

| 目標 | 判斷依據 | 目標位置 |
|---|---|---|
| 單檔 .md | frontmatter `type: podcast-*` | `30_Resources/溝通與關係/` 或對應類別 |
| 單檔 .md | frontmatter `type: youtube-*` 或 `video-summary` | `30_Resources/YouTube 摘要/` |
| 單檔 .md | frontmatter `type: article-*` 或 `web-capture` | `30_Resources/深度報導/` 等對應類別 |
| 單檔 .md | frontmatter `project: <name>` | `10_Projects/<name>/` |
| 單檔 .md | tags 含 `#longterm` / `#area` | `20_Areas/<area-name>/` |
| 單檔 .md | tags 含 `#research` | `50_Research/<topic>/` |
| 單檔 .md | 以上皆無 | 讀前 500 字，LLM 一句話決定類別 + 既有資料夾 |
| **子資料夾**（空） | `find -type f` 回空 | `_trash/<name>.<timestamp>` |
| **子資料夾**（1-5 檔） | 展開逐檔分類（當獨立 .md 處理） | 各檔獨立去處 |
| **子資料夾**（≥ 6 檔，主題一致） | 整包當 unit 搬 | `30_Resources/<folder-name>/`（保留資料夾名） |
| **子資料夾**（≥ 6 檔，主題混雜） | 默認整包搬到 `30_Resources/<folder-name>/`，在 plan 標記「可後續拆分」 | 同上 |

**深度整頓五步**（非 optional，全部內建於 archive。設計目標：**跑一次搞定所有整理面向，不用常常跑**）

每檔搬移前，依序做：

#### 1) Rename（去日期 / 正規化）

- 移除 `YYYY-MM-DD-` 前綴 / `-YYYY-MM-DD` 後綴 / `_YYYYMMDD` 尾碼
- 保留：IG/YouTube post ID、hash、版本號
- 檔名仍要可讀（中英混皆可），不強制 slug 化

正則範例：

```bash
NEW=$(echo "$OLD" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/-[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$/.md/; s/_[0-9]{8}\.md$/.md/')
```

#### 2) 完整 frontmatter（不是最小補丁）

```yaml
---
title: <可讀標題，中英混，必填>
type: <summary | podcast-summary | video-summary | article-summary | reference-tips | analysis | portfolio | news | tutorial | commentary>
tags: [<3-7 個 tag，中英混，反映主題 + 形式>]
source: <URL | "unknown">
created: <YYYY-MM-DD，從檔案 mtime，fallback 今日>
captured: <YYYY-MM-DD，今日>
status: draft
---
```

`title` 從檔名去底線 / hyphen 還原成可讀標題；LLM 讀前 500 字校正。
現有 frontmatter 有缺欄就補齊、已有的欄位保留。

#### 3) 雙向連結（2-5 條 outbound wikilinks）

body 結尾固定附加：

```markdown

## 相關

- [[<target1>]]
- [[<target2>]]
- [[<target3>]]
```

目標來源（依序取，直到湊齊 2-5 條）：
- 同 cluster 內其他即將搬到同目錄的檔（高相關，先取）
- `qmd-search vault_query` 用該檔 title + 主 tag 查，取 top 3-5 命中檔案（排除 `_trash/` / `00_Inbox/` / 本檔自己）
- Obsidian 本來就是 filename 解析，所以只寫 `[[basename]]` 即可，不寫路徑
- backlinks 由 Obsidian 自動產生，不需反向編輯目標檔（`雙向` 透過 Obsidian 的 backlinks panel 實現）

#### 4) 废檔案掃描（資料夾 → 丟 _trash）

搬資料夾前對其內容掃一次：

```bash
# 0-byte 檔
find "$FOLDER" -type f -name "*.md" -size 0
# 只有 frontmatter 沒內容（< 300 bytes 粗篩 + awk 內容行數驗證）
find "$FOLDER" -type f -name "*.md" -size -300c
# OS 垃圾
find "$FOLDER" -type f \( -name ".DS_Store" -o -name "*.tmp" -o -name "*.swp" -o -name "Icon?" \)
# 非 .md 廢檔（除了資料夾作者刻意放的附件）
find "$FOLDER" -type f ! -name "*.md" ! -path "*/attachments/*"
```

命中的檔：搬前先 `mv` 到 `_trash/<basename>.<timestamp>`，不帶入新家。

#### 5) 分類搬移

按既有分類決策順序（見上表）決定目的地，`mkdir -p` + `mv`。

---

**Plan 輸出格式**（dry-run，一份完整計劃，不拆多階段）

```
=== inbox-archive plan（深度整頓）===

📊 概況
  根檔: N | 子資料夾: M（其中空殼 / 待拆 / 主題一致）
  废檔案: X 件（0-byte / skeleton / OS 垃圾）→ _trash
  Rename: Y 件（去日期）
  需建新目的地資料夾: Z 個

📦 搬移計劃
  <cluster 1> → <destination>  (N 檔)
    <old-name>.md → <new-name>.md   # 若 rename
    ...

🗑️ 廢檔案（進 _trash）
  <path>  (reason: 0-byte / skeleton / OS trash)

📝 Frontmatter 補齊
  <N 件> 無 frontmatter → 全補
  <M 件> 缺 type/tags → 補缺

🔗 雙向連結
  每檔末尾加 `## 相關` section，2-5 條 wikilinks
  來源：同 cluster 內 + qmd-search vault_query top hits

回「go」全執行 / 「skip <檔名>」排除某件 / 「move <檔名> <新路徑>」改目的地。
```

**執行**（使用者 go 後）

為每檔依序做：(1) rename → (2) 補 frontmatter → (3) 加 `## 相關` wikilinks → (4) `mkdir -p` 目的地 → (5) `mv`。每檔間 `sleep 1`（iCloud 守則）。

```bash
for each <old-path, new-name, dest, frontmatter, wikilinks> in plan:
  # 1. 讀原內容
  CONTENT=$(cat "$old_path")
  # 2. 用新 frontmatter + 原 body + 尾端 wikilinks 組合
  NEW_BODY="---\n$frontmatter\n---\n\n$(strip_old_frontmatter "$CONTENT")\n\n## 相關\n\n$wikilinks\n"
  # 3. 寫到目的地（新檔名）
  mkdir -p "$VAULT/$dest"
  [ ! -f "$VAULT/$dest/_index.md" ] && \
    printf "# %s\n\n<一句話用途>\n" "$(basename "$dest")" > "$VAULT/$dest/_index.md"
  printf '%s' "$NEW_BODY" > "$VAULT/$dest/$new_name"
  # 4. 原檔刪除（移到 _trash 保險）
  mv "$old_path" "$VAULT/_trash/$(basename "$old_path").archived-$(date +%Y%m%d%H%M%S)"
  sleep 1
done
```

**收尾**

- append log.md：`<ISO8601> vault-ops inbox-archive — 歸檔 N 件、rename X 件、補 FM Y 件、加 wikilinks Z 條、trash W 件`
- 輸出報告：成功幾件、失敗幾件、路徑變動清單、_trash 清單

---

## Routine 2: vault-health

**觸發詞**：「掃 vault」「vault 健康度」「vault health」「vault-ops health」

**目標**：盤查 vault 結構問題，**只讀不寫**，產出清單報告。

**四項掃描**（全部跑、一次輸出）

### 2.1 Orphan 筆記（沒被 wikilink 到的 .md）

```bash
cd "$VAULT"
# 收集所有 [[xxx]] 目標
grep -rhoE '\[\[[^]]+\]\]' --include='*.md' . 2>/dev/null | \
  sed -E 's/\[\[([^]|#]+)(\||#)?.*/\1/' | sort -u > /tmp/linked.txt
# 收集所有 .md basename（去副檔名）
find . -type f -name "*.md" ! -path './_trash/*' ! -path './.obsidian/*' \
  -exec basename {} .md \; | sort -u > /tmp/all.txt
# 差集
comm -23 /tmp/all.txt /tmp/linked.txt | head -50
```

### 2.2 Dead wikilinks

```bash
# [[X]] 中 X 對應不到任何 .md
for link in $(cat /tmp/linked.txt); do
  [ ! -f "$(find . -type f -name "${link}.md" ! -path './_trash/*' 2>/dev/null | head -1)" ] && echo "$link"
done | head -50
```

### 2.3 Frontmatter 缺欄

掃所有 `.md`（排除 `_trash/`、`.obsidian/`、root level 三檔 index/log/AGENTS）。missing 判斷：無 frontmatter block、或 frontmatter 缺 `type` 欄位。

### 2.4 資料夾命名違規

```bash
# PARA 數字前綴目錄旁的非標準目錄
find . -maxdepth 1 -type d | grep -vE '^\./(_|\.)' | grep -vE '^\./[0-9]{2}_' | grep -v '^\.$'
```

**輸出報告**

```
=== vault-health 報告 ===
📁 Vault: <path>
🕐 掃描時間: <ISO8601>

## Orphan 筆記（N 件，顯示前 50）
- path/to/foo.md
- ...
建議：移到 _trash 或補 wikilink

## Dead wikilinks（N 件，顯示前 50）
- [[bar]] 在 path/to/note.md 但找不到 bar.md
- ...
建議：建檔或修正連結

## Frontmatter 缺欄（N 件）
- path/to/note.md — 缺 type
- ...

## 資料夾命名違規
- ./weird-folder
```

**不執行任何 mv / rm**。使用者可接著用 inbox-archive 或 trash-expire 處理。

---

## Routine 3: trash-expire

**觸發詞**：「清 trash」「trash 過期」「trash expire」「_trash 掃一下」「vault-ops trash-expire」

**目標**：盤查 `_trash/` 內項目年齡，permadelete **二度確認**後移到 macOS Trash（不 rm -rf，仍可救）。

**步驟**

```bash
TRASH="$VAULT/_trash"
# 列項目 + mtime age（天）
for item in "$TRASH"/*; do
  [ -e "$item" ] || continue
  NAME=$(basename "$item")
  MTIME=$(stat -f %m "$item")
  NOW=$(date +%s)
  AGE_DAYS=$(( (NOW - MTIME) / 86400 ))
  SIZE=$(du -sh "$item" | awk '{print $1}')
  echo "$AGE_DAYS 天 | $SIZE | $NAME"
done | sort -rn
```

**Plan 輸出**：以「預設門檻 30 天」標紅建議永刪，使用者可改門檻或點名。

```
=== trash-expire plan ===
_trash/ 現況：<N> 項，總 <size>

⚠️ 超過 30 天（建議永刪，共 X 項）：
  180 天 | 2.3M | 30-resources
  120 天 | 450K | 90-system

✓ 30 天內（保留）：
  15 天 | 120K | draft-xxx.md

回「go」永刪超過 30 天項目 / 「go 90」改門檻 90 天 / 「delete <name>」點名 / 「cancel」放棄
```

**執行**（使用者 go 後）

```bash
for item in <confirmed list>:
  # 移到 macOS Trash（仍可救）—— 不用 rm -rf
  osascript -e "tell application \"Finder\" to delete POSIX file \"$item\""
  sleep 1
done
```

**收尾**

- append log.md：`<ISO8601> vault-ops trash-expire — 永刪 N 項（移到 macOS Trash）`

---

## 路由表更新提醒

skill 首次使用完後，主動檢查是否已登錄：

```bash
grep "vault-ops" ~/life-os/skill-routes.md || echo "⚠️ skill-routes.md 尚無 vault-ops"
```

---

## 不做的事（劃界）

- ❌ 抓新內容進 vault（走 `capture` / `podcast-grabber` / `youtube-grabber` / `agent-reach`）
- ❌ vault 內搜尋（走 `qmd-search` 的 `vault_query` / `vault_search`）
- ❌ 對話存筆記（目前沒設計，需要再議）
- ❌ `.canvas` / `.base` 檔生成（你沒用）
- ❌ vault 初始化 / scaffolding（vault 結構已建好）
- ❌ MOC 自動生成（wiki schema 自己管）
- ❌ pitfall 卡分類 INDEX（`rules-patch.sh` cron 自動維護）
- ❌ cron / 定時任務（本 skill 明確設計為手動觸發）

## 邊界處理

- 碰到 `10_Projects/` 下已存在的專案資料夾 → 只 append，不動結構
- 碰到 root level `index.md / log.md / AGENTS.md` → 只 append log.md，其餘不碰
- 碰到 `.obsidian/` `.git/` `_trash/` `.trash/` → 永遠跳過
- 分類不確定時（rule 沒打到 + LLM 信心低）→ 保留在 00_Inbox，標注 "needs-human-review"

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
