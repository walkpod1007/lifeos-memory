---
name: memory-cards
description: 讓 Claude Code 用 Markdown 卡片記住事實與踩過的坑：atom 記憶卡（單卡單事實）＋坑卡（pitfall card）＋ MEMORY.md 索引＋可選的本機向量檢索。觸發：記住這件事、寫一張卡、踩坑了記下來、坑卡、記憶卡、memory card、pitfall
---

# memory-cards — Markdown 記憶卡機制

一句話：**長期記憶是可讀、可版控的 Markdown 檔案，不是壓縮到失真的對話摘要。**

這個 skill 定義三種寫入格式與一套索引/回搜流程。零依賴：不需要 Obsidian、不需要任何筆記軟體，普通資料夾就能跑。

## 目錄約定

記憶根目錄 `~/lifeos-memory/`（可用環境變數 `LIFEOS_MEMORY_ROOT` 改）：

```
~/lifeos-memory/
  MEMORY.md            # 索引：一卡一行，session 開場讀它
  cards/               # atom 記憶卡（單卡單事實）
  cards/pitfall/       # 坑卡（踩過的坑）
  daily/               # 10 分鐘摘要落這裡（由 memory-harness 寫）
  state/               # 滾動狀態（由 memory-harness 寫）
  handoff/             # session 交接檔（由 memory-harness 寫）
```

第一次使用時建立目錄與空的 MEMORY.md 即可啟用。

## 1. Atom 記憶卡 — 單卡單事實

**什麼時候寫**：使用者說「記住」；或出現日後會再用到、但不寫下來下個 session 就消失的事實（偏好、環境特性、外部座標）。

**規則**：一張卡只放**一個**事實。兩個事實 = 兩張卡。

檔案 `cards/<kebab-case-slug>.md`：

```markdown
---
name: <短-kebab-slug>
description: 一行摘要——回搜時靠它判斷相關性
type: user | project | reference
created: YYYY-MM-DD
---

事實本體，2-5 句。相關卡片用 [[卡名]] 連結。
```

- `user`＝使用者是誰（偏好、習慣、專業）；`project`＝進行中工作的約定與脈絡；`reference`＝外部座標（URL、機器、帳號位置）。
- 寫卡前先搜有沒有既有卡片蓋到同一件事——**更新舊卡優於開新卡**；發現卡片內容錯了就地改或刪。
- 對話裡已經有、或 git/程式碼本身就記得的東西**不要**寫卡。

## 2. 坑卡 — 踩過的坑當場寫

**什麼時候寫**：踩坑**當下**立刻寫，不等收尾。判斷標準：這個錯誤（a）花了超過幾分鐘才搞懂，且（b）下次還可能再犯。

檔案 `cards/pitfall/<kebab-case-slug>.md`：

```markdown
---
name: <短-kebab-slug>
description: 一行講清楚坑是什麼——回搜時的判斷依據
type: pitfall
category: tools | memory | system | execution | dialogue
created: YYYY-MM-DD
last_hit: YYYY-MM-DD
hit_count: 1
---

**坑**：什麼情境下、什麼動作、炸出什麼結果。

**根因**：為什麼會這樣（一兩句，寫機制不寫情緒）。

**下次怎麼避**：具體可執行的做法或檢查點。
```

- 再次踩到同一個坑：更新 `last_hit`、`hit_count` +1，不開新卡。`hit_count` 高的卡代表教訓沒內化，值得寫進專案 CLAUDE.md 變成常駐規則。
- **替代（supersession）**：新結論跟舊卡相反時，先在舊卡 frontmatter 加 `superseded: true` / `superseded_by: <新卡名>`，再寫新卡——歷史不刪，避免同一件事兩張卡各說各話。

## 3. MEMORY.md 索引

每寫/改一張卡，就在 `MEMORY.md` 對應加一行：

```markdown
- [卡片標題](cards/xxx.md) — 一句鉤子
- [坑卡標題](cards/pitfall/yyy.md) — 一句鉤子
```

**MEMORY.md 只放索引行，永遠不放卡片內文**——它是 session 開場要整份讀進 context 的東西，一行一卡才撐得住規模。

**接進 Claude Code**：跑過 `install.sh` 的話，開機區塊（含 `@MEMORY.md` 自動載入）已寫進 `~/.claude/CLAUDE.md`，不用再動。手動接線則在專案 `CLAUDE.md` 加一行 `@~/lifeos-memory/MEMORY.md`，每個 session 自動帶著索引開場，需要細節再開卡片檔。

## 4. 回搜（可選但強烈建議）：本機向量檢索

用公開 npm 套件 [`@tobilu/qmd`](https://www.npmjs.com/package/@tobilu/qmd)——本機跑 BM25＋向量＋LLM rerank，資料不出機器：

```bash
npm i -g @tobilu/qmd
qmd collection add ~/lifeos-memory --name memory   # 建索引（一次；路徑在前，name 在前會被當相對路徑吃掉）
qmd update -c memory && qmd embed -c memory        # 更新（可交給 memory-harness 排程）
qmd search -c memory "關鍵詞或一句話"               # 語意回搜
```

回搜時機：接到新任務先搜一次坑卡（「這件事以前踩過坑嗎？」）；話題觸及具體人事物時搜記憶卡。沒裝 qmd 就用 `grep -ri`，一樣能活，只是查得笨一點。

## 反模式

- ❌ 一張卡塞多個事實（回搜命中率崩壞）
- ❌ 把卡片內文貼進 MEMORY.md（索引膨脹，開場 context 爆）
- ❌ 事後補卡（「等下再記」＝不會記；坑卡的價值在當場）
- ❌ 記程式碼本身就記得的東西（結構、歷史修正——git 都在）
