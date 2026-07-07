---
name: magazine-doc
description: 把清單/攻略/行前包排成雜誌風 A4 PDF（封面目錄＋內頁＋AI 生圖）。觸發：做成雜誌、雜誌風 PDF、排漂亮一點印成 PDF、行前包/攻略做成文件、magazine-doc
---

# magazine-doc — 清單內容 → 雜誌風 A4 PDF

> 沉澱自 2026-07-05《一鍋到底 × 5》食譜特輯（6 頁 A4，使用者驗收：「雜誌樣板技能 ok」）。
> 核心價值：任何「N 個條目＋每條有圖有細節」的內容（食譜、片單、行前包、開箱清單），
> 都能套同一套版式出對外可交付的 PDF，不用每次重新設計。

## 何時用

產出是**一份要給人翻閱/轉發的多頁文件**（PDF），內容是條目式清單。判準：「排版美感」是交付價值的一部分。

- 只要資料本身（文字清單就好）→ 直接回訊息，不必走這裡。
- 要互動網頁/儀表板 → `frontend`。
- 要多張社群圖卡 → `carousel-gen`。

## 與底層 skill 的關係（不重造輪子）

| 角色 | 由誰負責 | 本 skill 怎麼用 |
|------|----------|----------------|
| 生菜色圖/hero 圖 | `imagen-gen` 或 `codex-image` | 委派生圖，存進工作目錄 `img/`，檔名 `NN-slug.png` |
| 內容素材 | Vault（`vault_search`）/ 對話 / 工單 | 內容忠於來源，不編造；標出處＋收藏日期 |
| 上傳交付 | `gog`（gws drive +upload） | PDF 完成後上 Drive，連結遞使用者 |

## 樣板與設計 token

樣板：`skills/magazine-doc/template-recipe.html`（A4、6 頁、封面目錄＋5 內頁）。
設計 token（改主題時保持一致性）：

- 底色暖米白 `#FAF6EF`、主色陶土橘 `#C4572E`、深字 `#2A2724`、卡片鼠尾草綠系
- 大標 serif（Noto Serif TC/Songti TC）、內文 PingFang TC
- 內頁結構：滿版出血 hero 圖（上半）→ 標題＋一句引言 → 左「食材/要點卡」右「編號步驟」→ 頁腳出處列（IG/Vault 日期/YouTube 連結）
- `@page { size: A4; margin: 0 }`＋`.page { width: 210mm; height: 297mm }`＋`print-color-adjust: exact`（缺這行背景色印出來全白）

## SOP

1. **收料**：從 Vault/對話拉條目內容（每條：名稱、細節清單、步驟、出處連結）。內容不足就先問，不要編。
2. **建工作目錄**：`drafts/<主題>-YYYYMM/`，複製樣板進去改名 `index.html`，同層建 `img/`。
3. **生圖**：每條目一張 hero 圖（`imagen-gen`），存 `img/NN-slug.png`；封面目錄縮圖直接重用同檔。
4. **改版面**：置換文字內容；條目數 ≠ 5 時增刪 `.page` 區塊與封面 index-row，頁碼同步改。
5. **印 PDF**（2026-07-05 實測指令，三個 flag 都是必要的，見 GOTCHAS）：
   ```bash
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless=new --disable-gpu \
     --user-data-dir=/tmp/chrome-pdf-profile \
     --print-to-pdf=out.pdf --no-pdf-header-footer \
     --virtual-time-budget=8000 \
     "file:///absolute/path/index.html"
   ```
6. **驗收**：Read PDF 逐頁看。重點：圖有沒有破（破圖顯示 alt 文字小框）、食材/要點卡有沒有溢出、頁腳出處齊不齊。
7. **交付**：`gws drive +upload` → 連結遞使用者；HTML＋img/ 整目錄留在 drafts/ 供下次複用。

## GOTCHAS（實測踩過）

- **Chrome headless 沒帶 `--user-data-dir` 會撞到正在跑的 Chrome singleton，靜默卡死**（2026-07-05 實測卡滿 2 分鐘 timeout）。一律帶獨立 profile 目錄。
- **HTML 樣板的圖是 `img/` 相對路徑**：存檔/搬家時要連 `img/` 目錄一起帶，只搬 HTML 重印就全破圖（2026-07-05 實案：drafts 只留了 HTML，圖被清場清掉，樣板重印五格全是 alt 框）。
- **食材/要點卡 12+ 項會溢出版面**（工兵 2026-07-05 自查抓到義大利麵頁溢出）：項目多時縮 row padding 或把卡改兩欄，印完務必回看該頁。
- 全形字元不要進 regex/檔名處理段（沿用全域 bash 坑卡）。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: "2026-07-05 一鍋到底×5 食譜特輯（LINE DM 任務）；使用者驗收後指示技能化"
status: active
closeout_gist: ""
