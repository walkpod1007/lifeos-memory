# carousel-spec — 輪播圖規格單（填空模板）

> 一套輪播 = 一份這個。先填滿再生圖；填好的這份就是「不變量」，slide 2..N 逐字共用其中的「主風格規格塊」。
> 來源工作流：be.ai.curator（文案→9 張一致）＋ wilson_pro_ai（參考圖＋主題→輪播）。

---

## 0. 這套是什麼

- 主題 / 文案來源：`<貼上原始文案，或 brand-creative-loop 產出的文案>`
- 平台：`<IG 貼文 / Threads / FB>`
- 張數 N：`9`（預設；重點型懶人包可 7）
- 尺寸：`1080×1080`（4:5 滿版用 `1080×1350`）
- 口吻來源：`brand-creative-loop/voice.md`（若存在 → 套禁用詞與調性）

## 1. Slide breakdown（每張說什麼）

| slide | 功能 | 標題（verbatim，會印上圖） | 內文一句 |
|------|------|----------------------------|----------|
| 1 | Hook 封面 | `<三積木標題：Interest Topic × Format × Viral Vector>` | `<副標一句>` |
| 2 | 論點 1 | | |
| 3 | 論點 2 | | |
| 4 | 論點 3 | | |
| 5 | 論點 4 | | |
| 6 | 論點 5 | | |
| 7 | 論點 6 | | |
| 8 | 論點 7 | | |
| 9 | CTA / 私域導流 | `<「留言 X 領 Y」「收藏這篇」去浮誇化>` | `<導流動作>` |

> slide 1 標題吃 `brand-creative-loop/playbooks/ig.md` 的三積木框架，且過 voice.md 禁用詞（無「保證爆紅／秒殺／躺賺」）。

## 2. 選風格

- 選定風格（從 `style-library.md`）：`<例：1 極簡編輯>`
- 該風格 spec 片段（抄過來）：`<例：minimalist editorial layout, generous white space, ...>`
- 輔風格（可空）：`<只當點綴，不平分版面>`

## 3. 主風格規格塊（master style-spec）★ 每張逐字重複 ★

> 這整塊是一致性的承重點。slide 2..N 的 prompt 原封不動貼這塊，只換上面表格裡「這張的文字」。一個字都別改。

```
Style: <貼第 2 節的風格 spec 片段>
Palette (hex, 用這幾個，不要其他顏色): bg <#______>, text <#______>, accent <#______>, secondary <#______>
Typography: heading <字體/粗細>, body <字體/粗細>, 一致字級階層
Layout: <版面網格，例：標題上 1/3、內文中段、留白下 1/5>；margin <例：每邊 8% 安全邊距>
Size: <1080×1080>
Constraints: no watermark, no logos, 同一套配色字體版面跨所有張, 文字 verbatim 不得改寫, readable on mobile
```

## 4. 一致性鎖（怎麼餵 codex-image）

- [ ] **先生 slide 1**（封面）→ 反覆調到順眼當「視覺錨」→ 定稿在 `/tmp/codex-image-output/`
- [ ] slide 2..N：把**定稿 slide 1** 放 `/tmp/codex-image-ref/`，標 **`style reference`**
- [ ] 每張 prompt = 第 3 節主風格規格塊（逐字）＋ 該張文字 ＋ `Image 1: style reference, 沿用其配色字體版面只換文字`
- [ ] 全部生完 → 並排 Read → 挑離群張 → **只重生離群張**（同錨同 spec）
- [ ] 定稿 → 走 codex-image 的 `gws drive +upload` 整套傳 `AI-Generated` 資料夾

## 5. 成本預估（先講清楚）

- 每張帶參考圖 → codex-image 註明約 2–3× 放大；9 張一套（含迭代＋重生）易達數十萬 tokens。
- 不確定值不值得 9 張前，先只生 slide 1 + slide 2 看風格鎖不鎖得住，再決定整套。
