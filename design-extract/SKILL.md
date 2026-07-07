---
name: design-extract
description: 逆向參考網站/截圖設計，產出結構化 DESIGN.md。觸發：逆向這個網站的設計、抓這個站的風格、做一份 DESIGN.md、設計 token、URL 轉 design
---

# design-extract — 參考站 → DESIGN.md（設計 token 規格）

> 概念來源：@aiposthub 介紹 Meng To 的 **Aura.build「URL → DESIGN.md」逆向工程**功能（[[raw/2026-05-15-aiposthub-aura-build-url轉design-md]]）。核心命題：使用者「喜歡某個網站的美學」，但 frontend 的預設輸出偏「AI slop / 千篇一律」。解法是先把那份美學**逆向成結構化設計文件**（色彩、字體、間距、元件），再讓 frontend 照著做 → 產出看起來「有意圖」，不是預設值。
> 本 skill 只做上游的「提煉規格」這一步；**不寫 HTML**（那是 frontend 的事）。

## 何時用

使用者**指了一個參考對象**（一個 URL、一張截圖、或「我想要像 X 那種感覺」）並希望接下來的頁面長那個樣子。判準：產出是**一份 DESIGN.md 規格文件**，而不是圖、不是 HTML。

典型開場：「幫我抓 linear.app 的風格做成 design」「我喜歡這個網站，逆向成設計系統」「下次 dashboard 照這個截圖的調性做」。

- 已經有設計規格、只是要把它變成頁面 → 直接走 `frontend`，不必來這裡。
- 要的是一張圖／封面／插畫 → `codex-image` / `imagen-gen`。
- 要一整套風格一致的輪播圖卡 → `carousel-gen`（它自帶 casper 靜態風格庫，不需現場逆向）。
- 只是想把這個網頁存起來 → `capture`。

## 老實話：能逆向到什麼程度（工具限制，先講清楚）

本機沒有真正的瀏覽器、沒有 headless render，JS 注入後的樣式與 computed style 拿不到；Aura.build 那種「貼網址就吐精準 token」是它後端跑了真實 render，本機**做不到像素級精確逆向**。但工具不只 WebFetch——**Bash curl 可以直抓 HTML 原始碼與外部 .css 檔**（2026-07-05 實證，見路徑 A+），對「有 SSR/靜態 CSS 的站」能拿到**變數原值等級**的 token。誠實的做法是**三條路併用**：

### 路徑 A：WebFetch 抓結構（拿版面與語意，色彩字體只能「推測」）

WebFetch 那個 URL，能可靠拿到的是：
- **版面結構**：有幾個區塊、導覽列／hero／卡片網格／footer 的排列、單欄還多欄、內容密度。
- **內嵌樣式線索**：HTML 裡若有 inline style、`<style>` 區塊、CSS 變數宣告（`--color-…`）、Tailwind class 名（`bg-zinc-900`、`text-2xl`、`rounded-xl`），可以**反推**色票/字級/圓角。
- **字體**：`font-family` 宣告、Google Fonts 的 `<link>`。

拿不到 / 不可靠：JS 注入後的樣式、背景圖、實際 render 的顏色、精確間距像素。WebFetch 的 markdown 轉換會把 `<style>`/class 剝掉大半——**要樣式線索優先走路徑 A+，WebFetch 只當版面結構摘要用**。

### 路徑 A+：curl 直抓 CSS（2026-07-05 實證，樣式線索的首選）

WebFetch 拿不到的外部 `.css`，**curl 拿得到**。管線：

```bash
curl -sL -A "Mozilla/5.0 ..." "https://site" -o page.html          # 1. 抓 HTML
grep -oE '<link[^>]*rel="stylesheet"[^>]*>' page.html               # 2. 找 CSS 連結
curl -sL "https://.../style.css" -o site.css                        # 3. 抓 CSS
grep -oE -- '--[a-z-]+:\s*(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))' site.css | sort -u   # 4a. CSS 變數原值
grep -oE '#[0-9a-fA-F]{6}\b' page.html | sort | uniq -c | sort -rn | head -20      # 4b. hex 頻率統計（無變數時：最高頻≈主背景/主文字）
grep -oE 'font-family:[^;}]{3,80}' site.css | sort -u               # 4c. 字型
```

實測信心分級：CSS 變數原值＝**高信心**（anthropic.com `--swatch--*` 全套直出）；hex 頻率法＝**中信心**（linear.app 316 次 `#08090a` 判主背景，角色是推的）；抓不到＝退 WebFetch＋截圖。JS-heavy 站（token 在 JS bundle 裡）此路也會空手，退路徑 B。

### 路徑 B：截圖 → Claude vision 讀（拿調性與色感，最可靠的一條）

請使用者**貼一張參考站的截圖**（首屏即可）。Claude 用視覺直接讀：
- **色票**：主背景、文字、主色（accent）、次要色、邊框、危險色 → 給出**近似 hex**（眼睛取色，非精確，標「approx」）。
- **字體感覺**：襯線/無襯線/等寬、字重對比、標題與內文的層級感。
- **空間感**：留白多寡（鬆/緊）、圓角大小、有沒有陰影/光暈、邊框風格。
- **整體「氣質」**：極簡 / 高對比 / 柔和 / 復古 / 科技感 / 暖調…（轉成 feel 關鍵字）。

> **建議：A + B 併用。** 截圖給色彩與調性（B 比 A 準），WebFetch 給版面結構與「字體/Tailwind class 這種文字線索」（A 補 B 看不出的命名）。只有 URL 沒截圖也能做，但要明講「色彩是從 HTML 線索推的，可能不準，建議補一張截圖校對」。

## 主流程

### Step 1｜確認輸入與設定期待

問清楚：有 URL 嗎？能給截圖嗎？要逆向的是「整體調性」還是「某個區塊（如 hero / 卡片）」？一句話設定期待：**「我會給一份近似的設計規格，色票是推測值、建議你掃一眼校對，不是像素級複製。」**

### Step 2｜採集

- 有 URL → WebFetch 它，撈版面結構 + 內嵌樣式/字體/class 線索。
- 有截圖 → vision 讀色票、字體感、空間感、氣質。
- 兩者都有 → 交叉比對（截圖定色彩，HTML 定命名與版面）。

### Step 3｜填 DESIGN.md（用 `DESIGN.template.md`）

把採集到的填進 schema（見下節）。原則：
- **每個 hex 標來源與信心**：`#0B0B0F (截圖取色, approx)` 或 `#18181B (HTML --bg, 可信)`。
- **拿不到的不要瞎掰**：留 `（未知 / 沿用 frontend 預設）`，不要硬填一個假數字。
- **feel 關鍵字寫 3–6 個**：這是給 frontend 最有用的「方向錨」。

### Step 4｜交給 frontend（重要：frontend 不會自動讀檔）

> **誠實前提（已查證 plugin）**：目前 `plugins/frontend/` 的 SKILL.md / PRINCIPLES.md / recipes 都**沒有讀 DESIGN.md 的機制**。frontend 是引用固定的 `60_Deliverables/dashboards/style.css`（寫死的深綠主題 CSS 變數）+ PRINCIPLES.md。所以 DESIGN.md **不會被 frontend 自動吃進去**。

交付方式（二選一，都要由主 session / 使用者手動帶入，子代理不改 plugin）：

1. **貼進派工 prompt（預設、最省事）**：派 frontend 子代理時，把整份 DESIGN.md 的內容貼在任務描述裡，明講「**用這份 DESIGN.md 的色票/字體/版面覆蓋 PRINCIPLES.md 與 style.css 的預設值**」。子代理就會照 DESIGN.md 的 token 寫 inline CSS 或改 CSS 變數。
2. **存成檔給人複用**：把 DESIGN.md 存到該專案的工作目錄（如 `60_Deliverables/dashboards/<專案>/DESIGN.md`），下次派工時 `cat` 出來貼進 prompt。

> 不要在 SKILL.md 或對話裡宣稱「frontend 會自動讀 DESIGN.md」——它不會。要嘛貼進 prompt，要嘛之後有人去改 frontend plugin 讓它讀（那是 Tier 0 改架構的事，不在本 skill 範圍）。

## DESIGN.md schema（規格欄位）

完整空白版見 `DESIGN.template.md`，一份填好的範例見 `DESIGN.example.md`。骨架：

| 區塊 | 內容 | 給 frontend 用來… |
|------|------|------------------|
| **Meta** | 參考來源（URL/截圖）、逆向日期、信心等級 | 標示這份規格的可信度 |
| **Feel（風格關鍵字）** | 3–6 個調性詞（極簡/高對比/暖調/科技…） | 整體方向錨，最重要 |
| **Palette（色票）** | bg / surface / text / subtle / accent / border / danger 的 hex（標來源+信心） | 換掉 style.css 的色彩變數 |
| **Typography（字體）** | 字族（標題/內文/等寬）、字級 scale、字重、行高 | 定字體層級 |
| **Spacing（間距）** | 基準單位（如 4px/8px）、區塊 padding、卡片 gap | 定鬆緊 |
| **Radii / Shadows（圓角/陰影）** | 圓角值、陰影/光暈風格 | 定卡片質感 |
| **Layout（版面）** | 單欄/多欄、grid 結構、內容密度、行動優先與否 | 定版型 |
| **Components（元件筆記）** | 卡片/按鈕/導覽列的視覺特徵 | 定元件外觀 |
| **Anti-patterns（不要做的）** | 從參考站歸納出「要避免的 AI slop 特徵」 | 反向約束 |

## 與 frontend 的分工（不重造輪子）

| 角色 | 由誰負責 |
|------|----------|
| 提煉設計規格（DESIGN.md） | **本 skill** |
| 把規格寫成單頁 HTML、輸出到 `60_Deliverables/dashboards/` | `frontend`（下游） |
| 靜態風格庫（玻璃擬態/Y2K/包浩斯… 40 種） | `carousel-gen` 的 style-library（casper 圖鑑），與本 skill 無關 |

一句話：**design-extract = 逆向出規格；frontend = 照規格產 HTML。** 本 skill 不碰 HTML、不碰 style.css。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
