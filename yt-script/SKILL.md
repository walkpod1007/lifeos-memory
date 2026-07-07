---
name: yt-script
description: YouTube 前製：從主題推到可拍腳本（競品逆向→選題→腳本代寫）。觸發：做一支 YT 腳本、YouTube 選題、競品頻道逆向、yt-script、無臉頻道
version: "0.1-draft"
created: "2026-06-16"
status: draft-pending-human-review
---

# yt-script — YouTube 前製生產線（選題 → 競品逆向 → 可拍腳本）

> DRAFT，待人審。本 skill 是 `brand-creative-loop/playbooks/youtube.md` 三框架的**可執行版**：playbook 是參考框架，yt-script 是一步步跑完並交棒下游的 runnable pipeline。兩者互補不重複——口吻 / 品牌定位一律回頭讀 brand-creative-loop，不在此重抄。

## 何時用

使用者要**把一個 YouTube 頻道方向或單支主題，從想法推到可以開拍的腳本**時：
- 「我想做 X 利基的頻道，幫我逆向對標頻道、排選題、寫腳本」
- 「這個月 YT 要拍什麼，幫我排優先序」
- 「把『Y 主題』拆成一支 10 分鐘的可拍腳本」

判準：產出物是**一份可交付給拍攝 / 生成 / 配音的 YouTube 腳本（含選題依據）** → 走這裡。
若只是要決定「整個品牌橫跨各平台要寫什麼、用什麼口吻」→ 回 `brand-creative-loop`。
若是要把**已上傳的現成影片**配音 / 翻字幕 → 直接走 `yt-dub` / `yt-sub-translate`。

## 與 brand-creative-loop 的關係（先讀，不重抄）

`brand-creative-loop` 若存在（`$HOME/life-os/skills/brand-creative-loop/`），yt-script 開跑前**先讀它的兩份不變底層**，不要在這裡重新定義品牌人格：

| 讀什麼 | 為什麼 |
|--------|--------|
| `brand-creative-loop/brand-profile.md` | 內容支柱 / 受眾 / 禁忌 → 決定「逆向哪些對標頻道、選題往哪靠」 |
| `brand-creative-loop/voice.md` | 口吻 / 人稱 / 禁用詞 → 腳本代寫（Prompt #3）與縮圖文字要繼承 |

- `brand-creative-loop/playbooks/youtube.md` = 三框架的**參考說明**（為什麼這樣做）。
- 本 skill = 三框架的**執行步驟**（怎麼一步步跑、輸入貼什麼、輸出長什麼、跑完交給誰）。
- 兩邊的三提示詞**指向同一組** `prompts/*.md`（本 draft 收錄 verbatim 可用版）。改 prompt 只改一處，避免雙份漂移。

> 若 brand-creative-loop 不存在（已被移除 / 尚未建），yt-script 仍可獨立跑——此時品牌支柱 / 口吻由使用者當場口述，腳本標 `<!-- TODO: 品牌口吻待確認 -->`，不腦補。

## Pipeline 總覽

```
Step 0  選利基 / 確認支柱   →  讀 brand-profile（或使用者口述）
Step 1  競品逆向工程        →  prompts/01-competitor-reverse.md
        貼對標頻道 Top 20 標題  →  輸出：選題框架（Fear vs Aspiration）、標題拆解、利基機制
Step 2  選題優先序排列      →  prompts/02-priority-selection.md
        承接 Step 1          →  輸出：Priority Video Selection 表（Idea / Traction / Search Term / Subscribe Trigger）
Step 3  腳本法醫 + 代寫      →  prompts/03-script-forensic.md
        貼 2-3 支對標腳本/逐字稿  →  輸出：可拍腳本（Title / Runtime / Thesis / Segment 逐段）
Step 4  留存複查            →  Tom Scott 留存原則（見下，已有出處）
Step 5  交棒下游            →  人/AI 把腳本拍成或生成影片並上傳
                            →  yt-dub（多語配音音軌） + codex-image（縮圖）
```

**Claude 當導演（貫穿全程）**
來源：[[raw/2026-05-16-garytu-claude-電影感短片製作流程]]（Garytu）。
核心：**語言模型決定創意方向，生成工具執行輸出。** Claude 在前端把敘事、節奏、鏡頭意圖（「導演視野」）定下來，後端工具（Seedance / Kive / codex-image / yt-dub）只執行，不自己亂跑。這跟本系統「機制優先、不通用罐頭」的調性一致。

---

## Step 0 — 選利基 / 確認內容支柱

來源：[[raw/2026-04-17-用Claude建AI無臉YouTube頻道的3個提示詞策略]]（@razvanpbusiness）。

原案（純被動收入無臉頻道）的選利基準則：**高 RPM × 病毒潛力 × 題材豐富**三者兼具（原文用 NexLev 之類工具找）。

> ⚠️ 若本品牌是**個人知識型頻道**而非純被動收入無臉頻道：選利基改成「對齊 brand-profile 的內容支柱」，借用的是 Step 1/2/3 的**逆向→排序→拆腳本流程**，而不是盲目追高 RPM 利基。先讀 `brand-profile.md` 的內容支柱再進 Step 1。

---

## Step 1 — 競品逆向工程

完整 prompt：`prompts/01-competitor-reverse.md`。

1. 選 2-3 個對標頻道（同利基 / 同支柱、有規模、選題打法清楚）。
2. 各取 **Top 20 最高觀看的影片標題**，貼進 prompt。
3. Claude 逆向出：
   - **選題框架**：Fear vs Aspiration 兩極（恐懼 ↔ 嚮往），**不選中性話題**。
   - 標題拆解 pattern（數字 / 懸念 / 對比 / 損失規避）。
   - 利基機制（這個利基為什麼有人看、卡點在哪）。

輸出留存進對話 context，Step 2 直接承接。

## Step 2 — 選題優先序排列

完整 prompt：`prompts/02-priority-selection.md`。

承接 Step 1 的逆向結論，要求 Claude 輸出 **Priority Video Selection 表格**，每列：

| 欄位 | 意義 |
|------|------|
| Video Idea | 具體影片題目（不是模糊方向） |
| Why It Earns Early Traction | 為什麼這支早期就能跑起來（恐懼？常青搜量？） |
| Search Term Targeted | 鎖定的搜尋詞（SEO 長尾） |
| Subscribe Trigger | 看完為什麼會訂閱（價值承諾） |

原文範例：
- #1「Why 90% of Truck Buyers Regret This Choice Within 3 Years」→ fear charge，搜 "truck buyer regret"。
- #2「The 5 SUVs With the Lowest Cost of Ownership in 2025」→ 常青高搜量 listicle。

## Step 3 — 腳本法醫 + 代寫

完整 prompt：`prompts/03-script-forensic.md`。

1. 從 Step 2 選定一個主題。
2. 找 2-3 支同利基高表現影片的**腳本 / 逐字稿**（沒有現成逐字稿可用 `yt-dlp` 抓字幕，或用 Tubelens 之類擴充把影片轉文字——見 [[raw/2026-05-16-yangme-tubelens-youtube-claude擴充]]）。
3. 餵給 Claude 做「法醫分析」：抽出**每一個可複製的 pattern**（開場鉤子、段落節奏、轉場、CTA 位置），讓零背景寫手也能複製。
4. Claude 接著**代寫**選定主題的可拍腳本，輸出含：
   - Title / Runtime（目標時長）/ Core Topic / Thesis（核心論點一句話）
   - Segment 1..N 逐段腳本（每段：旁白逐字稿 + 視覺 / 鏡頭意圖註記，供下游生成或拍攝）

代寫時**繼承 `voice.md` 的口吻與禁用詞**（去雞湯、去浮誇行銷套話、台灣譯名優先）。

## Step 4 — 留存複查（Tom Scott 留存原則）

> ✅ **已有出處**（2026-06-16 更新）：[[raw/2026-06-15-現在開始拍YouTube還來得及嗎-Tom-Scott傳授網紅必備觀念]]（Tom Scott via GQ Taiwan，6.63M 訂閱頻道主）。**修正前一版「出處待補」的判斷**——vault 現有此捕捉筆記。以下原則來自該筆記的去魅化問答，非杜撰。

用 Step 3 產出的腳本對照以下複查：

1. **建議影片（Suggested Videos）是最重要的流量來源**，遠超外部引流 → 演算法友善的片名、縮圖、**前 30 秒留存率**才是核心戰場。
2. **無片頭 / 極短片頭**：傳統 10 秒 Logo 動畫是流失點，觀眾已習慣立即進入主題。腳本第一個 Segment 直接給價值。
3. **差異化**：演算法更傾向推送既有頻道，新創者必須在利基建立辨識度（呼應 Step 0 的支柱對齊）。
4. **收入多元化心態**（廣告 / 贊助 / 周邊 / 授課組合）比追單一訂閱數現實——影響選題不必只追爆量、可留長尾常青題。

> 標示：1–3 是該筆記明確點出的；前 30 秒 / 縮圖 CTR 為演算法友善的**通用共識**，Tom Scott 筆記佐證其方向但未給數字門檻——勿在腳本裡編造「前 X 秒留存率要 ≥ Y%」這類假指標。

---

## Step 5 — 下游交棒（誠實的接縫，不是魔法直通）

yt-script 的產出是**一支「還沒被拍出來」的影片的腳本**。下游的 yt-dub / yt-sub-translate 是對**「已經上傳的現成影片」**動作的。中間有一段必須由人 / 生成工具完成，**不存在一條指令直接把腳本變成配音影片**。真實接縫：

```
yt-script 產出可拍腳本
   │
   ▼
（人手拍攝  或  Seedance/HeyGen/Higgsfield 等生成工具把腳本變成影片）
   │   ←── 這一段 yt-script 不做，也別假裝它做
   ▼
影片上傳到 YouTube（拿到 video URL / video ID）
   │
   ├──► yt-dub          ：對該影片音軌生成多語言 TTS 配音軌並上傳（edge-tts + ffmpeg）
   ├──► yt-sub-translate ：對該影片字幕翻多語（ko/ja/en/th）並上傳
   └──► codex-image      ：依腳本 Thesis + Title 生 1280×720 YouTube 縮圖
```

**縮圖交棒（可在影片做好前先做）**：`codex-image` 已有 YouTube 縮圖專用 prompt 模板（1280×720、文字 verbatim、bold sans-serif）。把 Step 3 腳本的 Title 文字 + Thesis 氛圍 + `voice.md` 禁用詞一併帶過去：
```
Use case: YouTube thumbnail
Text (verbatim): "{腳本 Title 的縮圖短句}"
Subject / mood: {Thesis 對應的視覺}
Constraints: no watermark; readable at mobile size; 1280x720 landscape
```

**配音 / 字幕交棒（必須等影片上傳後）**：
- yt-dub 觸發詞：「配音」「dubbing」「多語言音軌」——輸入是**現成影片 / video URL**，不是腳本。
- yt-sub-translate 輸入是 **.srt/.vtt 或 YouTube URL**，預設翻 ko/ja/en/th。

> 給使用者的話術：yt-script 把「拍什麼、怎麼拍、講什麼」定好；拍 / 生成 + 上傳那一步是人或生成工具做；上傳完才輪到 yt-dub 配音、yt-sub-translate 翻字幕、codex-image 出縮圖。**別承諾「一鍵腳本變多語配音影片」。**

---

## 三個 prompt 一覽（verbatim 可用，收於 prompts/）

| 檔案 | 角色 | 貼什麼進去 | 輸出 |
|------|------|-----------|------|
| `prompts/01-competitor-reverse.md` | YouTube 成長策略師 | 對標頻道 Top 20 標題 | 選題框架（Fear/Aspiration）+ 標題拆解 + 利基機制 |
| `prompts/02-priority-selection.md` | 無臉頻道策略師 | （承接上一輪） | Priority Video Selection 表格 |
| `prompts/03-script-forensic.md` | 腳本法醫 + 代寫手 | 2-3 支對標腳本 / 逐字稿 | 法醫拆解 + 選定主題可拍腳本 |

三個 prompt 的原始出處皆為 [[raw/2026-04-17-用Claude建AI無臉YouTube頻道的3個提示詞策略]]。

## 注意

- 這是 **draft，待人審**。品牌支柱 / 口吻未確認前，腳本帶 `<!-- TODO -->`，不替使用者編造定位或數字。
- 三框架是**市場驗證過的重組積木**，不是保證爆紅的魔法。原案的 $5k/2 週收益是單一案例宣稱，不可當期望值。
- 演算法會變：留存 / 流量來源類原則使用前快速確認現況（Tom Scott 筆記為 2026-06 時點觀察）。
- Prompt 原文是英文（角色設定用英文觸發 Claude 的策略師人格效果較穩）；輸出與腳本代寫可指定繁中（台灣）。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
