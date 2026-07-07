---
name: carousel-gen
description: 把文案做成風格一致的社群輪播圖（IG 九宮格）。觸發：做輪播圖、carousel、九宮格、IG 圖文、圖文懶人包
---

# carousel-gen — 文案 → N 張一致風格輪播圖

> 概念來源：@be.ai.curator「Claude × Codex × Image-2 一行命令出 9 張一致風格圖」（[[raw/2026-04-28-ClaudeCode串接CodexImage2輪播圖工作流四工具縮成一行命令]]）＋ @wilson_pro_ai「給參考圖＋主題，兩步驟出輪播」（[[raw/2026-05-18-ChatGPT兩步驟做輪播貼文理工威森]]）。
> 核心命題：gpt-image-2 一次只生一張、每張獨立，**天真地各生各的 → 9 張風格全不一樣**。本 skill 的價值不是「會生圖」（那是 codex-image 的事），而是**把 N 張綁成一套**的編排與一致性技術。

## 何時用

使用者要把**一段文案**變成**一整套對外發佈的輪播圖**（IG 九宮格、圖文懶人包、Threads/FB 圖卡串）。判準：產出是「多張、要看起來像同一套設計」。

- 只要一張（封面、縮圖、單圖）→ 回 `codex-image`，不必走這裡。
- 要可互動的網頁版面 → `frontend`（HTML 排版在「格式高度統一」時仍是更穩的選擇，見原 capture 作者提醒）。
- 還沒有文案、要先生文案 → 先走 `brand-creative-loop` 產文，再回來這裡出圖。

## 與底層 skill 的關係（不重造輪子）

| 角色 | 由誰負責 | 本 skill 怎麼用 |
|------|----------|------------------|
| 實際生圖（gpt-image-2 / codex exec / 上傳 Drive） | `codex-image` | **全部委派**。本 skill 只組 prompt 與決定呼叫順序，不自己寫 `codex exec ... image_gen`。 |
| 文字口吻（slide 上的字、CTA 措辭） | `brand-creative-loop/voice.md` | 若該 skill 存在，**讀 voice.md** 套口吻與禁用詞；slide 1 標題吃 `playbooks/ig.md` 的「三積木標題」。 |
| 視覺風格庫 | 本 skill 的 `style-library.md` | 從 casper「40 種設計語言」抽出的子集，每個風格一句可貼進 prompt 的 spec 片段。 |

> 一句話：**carousel-gen = 編排 + 一致性鎖 + 風格庫；codex-image = 引擎。** 任何 `~/.codex/generated_images → /tmp/codex-image-output → gws drive +upload` 的細節都看 codex-image SKILL.md，不在這裡重抄。

## 主流程（文案 → N 張）

### Step 0｜定規格（填 carousel-spec-template.md）

先把這套輪播的「不變量」釘死，後面每張共用：

1. **張數 N**（預設 9）與**每張要說什麼**（slide breakdown）。
2. **選風格**：從 `style-library.md` 挑 1 個（或主＋輔），抄出它的 prompt 片段。
3. **主風格規格塊（master style-spec）**：色票 hex、字體、版面網格、邊距、尺寸。這塊文字之後**每張原封不動複製**。
4. **尺寸**：IG 貼文 1080×1080（預設）；想吃滿手機高度用 1080×1350（4:5）。

slide 結構慣例（N=9 為例）：

| slide | 功能 | 內容來源 |
|------|------|----------|
| 1 | Hook / 封面 | `brand-creative-loop/playbooks/ig.md` 的三積木標題（Interest Topic × Format × Viral Vector），過 voice.md 禁用詞 |
| 2 … N-1 | 論點 / 步驟 | 文案拆成的單點，一張一個重點，標題＋一兩句 |
| N | CTA / 私域導流 | 「留言 X 領 Y」「收藏這篇」式收尾，措辭去浮誇化（voice.md） |

### Step 1｜先生 slide 1（封面＝風格錨點）

把「主風格規格塊 + slide 1 文字」組成 prompt，交給 `codex-image` 生**第一張**。這張要反覆看順眼再往下，因為它要當後面所有張的**視覺錨**。定稿後它會落在 `/tmp/codex-image-output/`（路徑/命名規則見 codex-image）。

### Step 2｜slide 2..N＝鎖一致性（本 skill 的承重段）

**這是整個 skill 的核心。** gpt-image-2 各生各的，要靠雙重約束把 N 張綁成一套——兩招同時上：

**招 1 — 文字側：master style-spec 逐字重複。**
每一張的 prompt 都**原封不動貼上同一塊主風格規格**（色票 hex、字體、版面網格、邊距、風格庫片段），只換「這張要顯示的文字內容」。風格描述用字一變，輸出就會漂移，所以是「逐字」不是「大意相同」。

**招 2 — 視覺側：把 slide 1 當 `style reference` 餵下去。**
codex-image 階段 1 支援參考圖，且明確有 **`style reference`** 這個角色（見 codex-image SKILL.md「階段 1：範本收集」）。所以生 slide 2..N 時，把**定稿的 slide 1** 放進 `/tmp/codex-image-ref/` 標記成 `style reference`，prompt 標 `Image 1: style reference`，要求新圖**沿用同一套配色、字體、版面、留白**，只替換文字。

```
（交給 codex-image 的意圖，非逐字命令）
參考圖：slide 1 定稿 → 角色 style reference
本張文字（verbatim）：「<slide N 的標題與內文>」
主風格規格塊：<原封不動貼 Step 0 那塊>
約束：沿用參考圖的配色 / 字體 / 版面網格 / 邊距，只換文字；同尺寸；no watermark
```

> 為什麼這招對得上 codex-image：它本來就吃「`style reference` 參考圖 + 逐字文字 + 明確約束」三件套（看它的 prompt 組裝規則）。我們只是把「同一張 slide 1」固定當參考、把「同一塊 spec」固定重複，**一致性來自固定變量，不是祈禱**。

### Step 3｜審查 + 補生離群張（誠實的迴圈）

**完美一致不保證。** 即使雙重約束，仍可能有 1–2 張色偏／字體飄／版面歪。流程必須含一個 review-regenerate loop：

1. 把 N 張並排 Read 出來，肉眼挑「跟這套不像」的離群張。
2. 只**重生離群張**（同樣餵 slide 1 當 style reference + 同 spec），不要整套重來。
3. 重生 1–2 輪仍壓不住，就退一步：要嘛接受小差異，要嘛承認這套風格對 gpt-image-2 太難鎖、換 `style-library.md` 裡更簡潔的風格（極簡 / 單色系比繁複插畫好鎖）。

### Step 4｜交付

定稿 N 張都在 `/tmp/codex-image-output/`，**沿用 codex-image 的上傳步驟**把整套傳到 Drive 的 `AI-Generated` 資料夾（folder ID 與 `gws drive +upload` 指令都在 codex-image SKILL.md，這裡不重抄）。回報整套連結 + 提醒哪幾張是重生過的。

## 成本誠實

- codex-image 註明：每次 `codex exec` 約 40K–60K tokens，**有參考圖時每張參考圖約 2–3 倍**。
- 本 skill 從 slide 2 起**每張都帶 slide 1 當參考圖** → 每張都吃放大係數。單張帶參考圖約 80–180K，9 張一套（含 slide 1 迭代 + 1–2 張重生）保守 **數十萬 tokens 級、極端（8 張全帶參考圖）可逾百萬**，遠比單張貴。建議先用 slide 1+2 試水，滿意再生整套。
- 省法：張數別超量（重點型懶人包 7 張常比 9 張好）；slide 1 一次調到位再往下；離群張才重生，別整套刷。
- 印刷別用：gpt-image-2 是 72 DPI、無 ICC，只適合**數位／社群發佈**；要印刷得設計師完稿（見 [[raw/2026-05-23-GPTImage2-Claude-AI設計工作流高階技巧與印刷限制]]）。

## 注意

- 這是 **draft，待人審**。風格庫片段、spec 模板都是起點，實際好不好鎖要跑過才知道。
- Rule 0：slide 上若出現作品／媒體名，照台灣譯名標注。
- 文字渲染交給 gpt-image-2 仍可能出錯字（尤其中文長句），定稿前逐張核字。
- 一致性是**機率不是保證**——Step 3 的 review loop 不是可選步驟。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
