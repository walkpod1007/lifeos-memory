# Life-OS · Linear Dark（暗色科技系）

近黑底＋靛藍品牌色＋多彩狀態點綴，精密、高密度、工程感。適合 dashboard、監控頁、系統報表。

> 來源：linear.app 首頁 HTML 取樣（2026-07-05，hex 按出現頻率統計，**中信心**——非官方 token 名，角色是我判讀的）。

## Color Palette

- **Background**: `#08090a` - 主背景（Linear 招牌近黑，316 次出現壓倒性主色）
- **Surface**: `#191d20` / `#2e2e32` - 卡片/浮層
- **Border**: `#3e3e44` - 邊框
- **Text Primary**: `#e2e4e7` - 主文字
- **Text Muted**: `#8a8f98` / `#62666d` - 次要/最弱文字
- **Brand Indigo**: `#4354b8` - 品牌主色（連結/CTA）
- 狀態點綴色：綠 `#89d196`、琥珀 `#ffc47c`、青 `#02b8cc`、天藍 `#55cdff`、粉 `#f79ce0`、長春花 `#8fa4ff`（小面積用，如狀態燈/圖表系列）

## Typography

- 原版：Inter Variable（推測，未在 HTML 證實）＋ 等寬碼字型
- **本機替代**：Outfit（canvas-fonts 自帶）或系統 SF Pro、等寬 JetBrains Mono
- **繁中搭配**：Noto Sans TC 或 PingFang TC

## Spacing / Feel

資訊密度高但呼吸感靠 1px 邊框與微妙層次差；圓角中等（8-12px）；陰影極淡或用邊框代替。
Feel：精密、工程、夜間、專注、高對比可讀。

## Best Used For

frontend dashboard、金絲雀/健檢報表、監控頁、工單看板、任何「系統在說話」的介面。

## Anti-patterns

不要純黑 `#000000` 當背景（要 `#08090a` 的柔黑）、彩色不要大面積鋪、不要粗邊框。
