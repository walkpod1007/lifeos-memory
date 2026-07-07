---
name: rule-change-review
description: 改規則文件（CLAUDE.md/soul/memory/SKILL.md）前的 review SOP。觸發：改 CLAUDE.md、改 soul、改規則、改 .local.md、改 SKILL.md description
---

# rule-change-review — 規則文件改動的 6 步 SOP

> ⚠️ **草案上線中（2026-05-02）**：codex 紅隊 FAIL with 13 WARNING。使用者選 C 路線：先用、缺口跟蹤至 `worktickets/2026-05-02-rule-change-review-warnings.md`，與 ROI #1/#2/#3 同期推進。長期方向應升級為 PreToolUse hook，非繼續加固 advisory skill（研究依據見 gist：https://gist.github.com/yourchannel21007/015cdb1abfc866319810c41cc1c90d97）。

## 為什麼要這個 skill

`ws/terminal/CLAUDE.md` 鐵律「程式碼一律走派工」是強硬保證；但「**改規則文件**」這件事本身**沒有任何 enforcement**：

- 沒 hook 攔截 Edit/Write CLAUDE.md
- 沒紅隊（紅隊只 cover code 改動）
- 沒 supersession check（既有 supersession 規則只 cover「寫 pitfall 卡 + 編輯 soul.md」）
- 沒 diff give review

結果：opus 想改規則就改，使用者看到時已成定局，要 revert 或重寫成本都很高。本 skill 補這個缺口。

## 涵蓋範圍（哪些檔案改動需走 SOP）

✅ 走 SOP：

- `~/.claude/CLAUDE.md`（global user instructions）
- `~/life-os/CLAUDE.local.md`
- `~/life-os/ws/*/CLAUDE.md`（project instructions）
- `~/life-os/soul.md` / `soul-behaviors.md`
- `~/life-os/skill-routes.md`
- `~/.claude/projects/*/memory/*.md`（feedback / project / user / reference memory）
- `~/.claude/projects/*/memory/MEMORY.md`
- `<vault>/80_apu/atoms/apu/pitfall/*.md` 的編輯（**新建**走 supersession 規則，**修改既有**走本 SOP）
- 任何 SKILL.md 的 `description:` frontmatter

❌ 不走 SOP（一般 markdown）：

- vault 一般筆記、handoff.md、worktickets/、drafts/、cold-storage/
- code（走派工）、config（json/yaml）、log

## 6 步流程

### Step 1：grep 矛盾

改動前先掃既有規則找矛盾：

```bash
KEYWORDS="<本次改動的核心字>"  # 例如：派工 / 不寫程式碼 / 紅隊 / kill / 程式碼
# 同類規則文件
grep -rn "$KEYWORDS" ~/.claude/CLAUDE.md ~/life-os/CLAUDE.local.md \
  ~/life-os/ws/*/CLAUDE.md ~/life-os/soul.md \
  ~/life-os/soul-behaviors.md 2>/dev/null
# 既有 feedback memory
grep -rn "$KEYWORDS" ~/.claude/projects/*/memory/ 2>/dev/null
# Vault 上 solidified pitfall（最高位階）
grep -rn "$KEYWORDS" "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/80_apu/atoms/apu/pitfall/" 2>/dev/null | head -20
```

如有結論相反的既有規則 → 走 supersession 流程（標 `superseded: true` + `superseded_by` + `superseded_date`），不要直接覆寫。

### Step 2：印預期 diff

改動前先把計畫的 before/after 印到 stdout 給使用者看：

- 用 `Read` 拿 before
- 用 markdown code block 顯示 after
- 簡短說明「改了什麼、為什麼」

如果改動超過 3 處 → 列表標號（每處 1 句說明）。

### Step 3：等使用者一句確認

明確問「OK 改 / B 一些調整 / C revert」之類，等使用者一句話。

**例外**：使用者本輪訊息已明確授權（「直接改」「上」「OK 改吧」），可以直接到 step 4。但**首次改某個檔案類型時 step 2 的 diff 印出仍是必要的**——使用者要看才能授權。

### Step 4：動手改

用 Edit / Write tool 執行。改動範圍 = step 2 印出的 diff，**不可擴大**（擴大要重走 step 2-3）。

### Step 5：派 codex 紅隊

```
codex exec "請紅隊審驗 <檔案路徑> 剛剛的改動。重點：(1) 與既有規則的衝突 (2) 措辭歧義（負向書寫、模糊條件、自我擴大解釋空間）(3) 涵蓋範圍是否漏（特殊副檔名、特殊情境）(4) 例外條款是否被縮窄到「真的就一行」級別。給 PASS/FAIL + WARNING list"
```

紅隊 fail → 修；紅隊 pass → 走 step 6。

### Step 6：寫 audit log

寫一行到 `~/life-os/cold-storage/rule-changes.md`（沒就建）：

```
## 2026-MM-DD HH:MM — <檔案>
- 改動：<1 句摘要>
- 動機：<為什麼改>
- 紅隊：PASS / FAIL + warnings
- 觸發 session：<session id>
```

audit log 是給「半年後想知道為什麼改成這樣」用的——人類記憶不行，跨 session 記憶也不行，只有 log 不會變。

## 例外（縮窄）

唯一可跳過 SOP 的情境：**typo 修正 + 標點符號 + 死連結 url 替換**。所有「措辭調整 / 規則框架調整 / 加減 bullet」都不算 typo，必走 SOP。

## 為什麼需要 step 5 紅隊（而非自評）

opus 改規則的同一場 session 裡，自評有強烈 confirmation bias——剛才這場我自己改完 CLAUDE.md「不寫程式碼」→「程式碼一律走派工」就沒紅隊，事後使用者才指出措辭跟例外條款還有漏洞。codex 是不同 family，看得到 opus 自己看不到的 hole。

## 為什麼需要 step 6 audit log

CLAUDE.md / memory 的修改在 git 之外（memory）或 git 內（CLAUDE.md）。即使在 git 內，commit message 也很少寫「為什麼改這條規則」。半年後再看 diff，背景脈絡全失。audit log 是把「動機」這個會被遺忘的部分捕捉下來。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
