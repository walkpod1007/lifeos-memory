# DESIGN.md — 「冷調極簡 SaaS」（範例，虛構參考站）

> ⚠️ **這是 design-extract 的填寫範例**，參考對象是「假想的一個 Linear/Vercel 風格的深色極簡 SaaS 著陸頁」，用來示範 DESIGN.md 該長什麼樣。**色票為示意虛構值**，非真實逆向結果。

## Meta

- **參考來源**：（範例）https://example-saas.invalid + 一張首屏截圖
- **逆向方式**：截圖 vision 定色彩 + WebFetch 撈版面與 Tailwind class 名
- **逆向日期**：2026-06-16
- **整體信心**：中（色票為截圖近似取色，版面靠 HTML class 推測）

## Feel（風格關鍵字）

- 極簡、克制
- 深色高對比
- 科技冷調（藍紫 accent）
- 大量留白
- 字體幾何感強

一句話總結：留白多、近黑底配單一藍紫強調色的幾何無襯線科技感，幾乎不用陰影、靠細邊框分層。

## Palette（色票）

- **bg（頁面背景）**：#0A0A0F（截圖取色, approx）
- **surface（卡片/區塊背景）**：#15151C（截圖取色, approx）
- **text（主要文字）**：#F4F4F6（截圖取色, approx）
- **subtle（次要文字）**：#8A8A99（截圖取色, approx）
- **accent（主色/強調）**：#6E56F7（截圖取色, approx；HTML 有 `text-violet-500` 佐證）
- **accent-2（次強調）**：無（整站只有一個強調色）
- **border（邊框）**：rgba(255,255,255,0.08)（推測，細淺白邊）
- **danger（警告/錯誤）**：未知 / 沿用 frontend 預設

## Typography（字體）

- **標題字族**：幾何無襯線（HTML `<link>` 指向 Inter）
- **內文字族**：同上（Inter）
- **等寬字族**：無（數字未見等寬處理）
- **字級 scale**：H1 ~48px / H2 ~28px / body ~16px / caption ~13px（approx）
- **字重對比**：標題 600–700、內文 400，對比明顯
- **行高**：內文 ~1.6，偏鬆

## Spacing（間距）

- **基準單位**：8px grid（Tailwind 預設間距 class，如 `py-24`、`gap-6`）
- **區塊外距 / padding**：區段間 ~96px（`py-24`）、卡片內距 ~24px
- **卡片/網格 gap**：~24px（`gap-6`）
- **整體鬆緊**：鬆（大量垂直留白）

## Radii / Shadows（圓角 / 陰影）

- **圓角**：卡片 ~12px（`rounded-xl`）、按鈕 ~8px（`rounded-lg`）
- **陰影風格**：幾乎無陰影；分層靠 surface 色差 + 細邊框

## Layout（版面）

- **欄數結構**：內容置中 max-width ~1120px；特色區三欄卡片網格（`grid-cols-3`）
- **內容密度**：疏
- **行動優先**：是，三欄在窄屏塌成單欄（`md:grid-cols-3`）
- **特徵區塊**：透明黏性導覽列 → 置中大 hero（大標 + 副標 + 主色 CTA）→ 三欄特色卡 → footer

## Components（元件筆記）

- **卡片**：surface 底 + 1px 淺白邊、無陰影、hover 邊框微亮
- **按鈕**：主 CTA 為 accent 實心圓角；次要為描邊透明底
- **導覽列**：頂部透明、scroll 後加淡背景與下邊框
- **其他**：強調文字用 accent 色而非加底色

## Anti-patterns（要避免的 AI slop 特徵）

- 不要彩虹/多色漸層——全站只有一個強調色
- 不要重陰影/光暈（這正是 frontend 預設 box-shadow 光暈要在此覆蓋掉的）
- 不要把每張卡片塞滿、不要縮小留白
- 不要等寬字當內文（這站內文是無襯線比例字）
