# style-library — 輪播圖可用視覺風格庫

> 來源：casper「Claude Code Skill 設計風格圖鑑：40 種設計語言」（[[raw/2026-05-15-casper-claude-code-skill-設計風格圖鑑]]，gallery: casper.tw/claude-skill-design-gallery）。
> casper 原圖鑑 40 種裡有 25 種靜態 + 15 種動態；**動態（視差滾動 / scroll-driven / 入場動畫…）是給 HTML 網頁的，輪播圖（靜態 PNG）用不到**，只抽靜態。下面是抽出的 **12 個適合社群輪播的子集**，每個一句可直接貼進 prompt 的 master style-spec 片段（英文寫，gpt-image-2 對英文 spec 較穩）。
> casper 原文只點名了幾個靜態風格（玻璃擬態、Y2K、包浩斯、瑞士國際設計、台灣廟會）；其餘為依「適合社群圖卡」原則補的常見設計語言，**標 [casper 點名] 者為原貼文明列**。實際 spec 用字建議跑過後再依品牌微調。

## 用法

挑 1 個當主風格 → 把該行的 spec 片段抄進 `carousel-spec-template.md` 的「主風格規格塊」→ 每張 slide 逐字重複。需要主＋輔時，主風格定版面、輔風格只當點綴（別兩個風格平分版面，會打架更難鎖一致）。

## 12 個風格

| # | 風格 | 適用調性 | prompt spec 片段（貼進 master style-spec） |
|---|------|----------|---------------------------------------------|
| 1 | **極簡編輯 Minimalist Editorial** | 知性、教學、個人品牌（最好鎖一致） | `minimalist editorial layout, generous white space, one accent color, thin sans-serif, strong typographic hierarchy, lots of margin` |
| 2 | **雜誌封面 Magazine / Editorial** | 觀點文、封面 slide 1 | `glossy magazine cover style, large bold display headline, masthead grid, high-contrast photography, editorial captions` |
| 3 | **瑞士國際設計 Swiss / International** [casper 點名] | 系統化、數據、清單型懶人包（最好鎖一致） | `Swiss International Typographic Style, strict grid, Helvetica-like grotesque sans, flush-left ragged-right, red+black on white, no decoration` |
| 4 | **包浩斯 Bauhaus** [casper 點名] | 設計感、幾何、課程 | `Bauhaus geometric style, primary red/yellow/blue + black, circles triangles squares, bold geometric sans, asymmetric balance` |
| 5 | **暗色模式 Dark Mode / Tech** | 科技、AI、工具教學 | `dark-mode UI aesthetic, near-black background, neon/electric accent, glowing edges, monospace + sans, high contrast, minimal` |
| 6 | **玻璃擬態 Glassmorphism** [casper 點名] | 現代感、產品、SaaS | `glassmorphism, frosted translucent glass panels, soft blur, subtle gradients, light borders, depth via layered transparency` |
| 7 | **柔色粉彩 Pastel / Soft** | 生活、療癒、女性向 | `soft pastel palette, muted lavender/peach/mint, rounded shapes, gentle gradients, friendly rounded sans, airy and calm` |
| 8 | **粗獷主義 Neo-Brutalism** | 反差、爭議觀點、年輕受眾 | `neo-brutalist web style, raw thick black borders, high-saturation flat color blocks, hard offset shadows, oversized chunky type` |
| 9 | **Y2K 千禧復古** [casper 點名] | 潮流、娛樂、Z 世代 | `Y2K retro-futurist style, chrome/metallic gradients, bubble shapes, iridescent holographic accents, early-2000s tech nostalgia` |
| 10 | **手繪 / 筆記 Hand-drawn** | 教學、知識懶人包、親和 | `hand-drawn notebook style, doodle arrows and highlights, marker/crayon texture, handwritten-style headings, sketchy underlines` |
| 11 | **3D 渲染 3D Render** | 產品、吸睛封面 | `clean 3D render, soft studio lighting, glossy rounded objects, single backdrop color, subtle shadows, isometric or floating composition` |
| 12 | **台灣廟會 Taiwan Folk / 廟會** [casper 點名] | 在地、文化、節慶題材 | `Taiwanese temple-fair folk style, vermilion/gold/deep-blue palette, traditional ornamental motifs, festive bold lettering, lively texture` |

## 鎖一致性的難易提示

- **最好鎖**：1 極簡編輯、3 瑞士、5 暗色——版面簡單、色少、靠排版，gpt-image-2 重複度高。社群懶人包預設從這幾個挑。
- **較難鎖**：9 Y2K、11 3D、12 廟會——元素多、質感重，跨張容易飄；務必走 SKILL.md Step 3 的 review-regenerate，或接受小差異。
- 不論哪個，**色票一定要落到 hex**（如 `#0A0A0A / #E8E8E8 / accent #FF4D4D`）並逐字重複，比形容詞（「暖色調」）穩得多。
