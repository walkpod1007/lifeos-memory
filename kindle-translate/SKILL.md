---
name: kindle-translate
description: Kindle/HONTO 電子書日翻繁中。觸發：kindle translate、電子書翻譯、日翻中、epub 翻譯、翻譯這本書
---

# kindle-translate — 電子書日翻中


---

## 概述

從 Kindle Cloud Reader 或 HONTO BinB Reader 擷取日文電子書內容，翻譯為繁體中文，輸出雙語 EPUB。

## Pipeline

```
來源（Kindle Cloud Reader / HONTO BinB Reader）
  → 擷取原文（TextMuncher OCR / Playwright 截圖+Tesseract）
  → OCR 品質掃描 + 補強
  → 章節分段
  → Haiku 翻譯（低成本）/ Claude API（主力）/ DeepL（fallback）
  → 雙語 EPUB 組裝
  → 增訂 patch（針對特定章節補強）
```

---

## Step 0：前置準備

### 工具依賴

| 工具 | 用途 | 安裝 |
|------|------|------|
| TextMuncher | Kindle Cloud Reader OCR 擷取 | Chrome 擴充（免費 30 頁 / Pro $6/月無上限） |
| Playwright | 自動化瀏覽器操作 | `npx playwright install chromium` |
| Claude API | 翻譯引擎（語感優先） | `ANTHROPIC_API_KEY` in `~/.claude/.env` |
| DeepL API | 速度 fallback | `DEEPL_API_KEY` in `~/.claude/.env`（optional） |
| Calibre (`ebook-convert`) | EPUB 組裝 | `brew install calibre` |

### TextMuncher 限制

- 免費版：30 頁自動擷取 + 無限手動 OCR
- Pro：$6/月無上限自動擷取
- 準確率 97%（純文字，不含圖表排版）
- 僅支援 Kindle Cloud Reader（Chrome 擴充）

---

## Step 1：擷取原文

### 方式 A：TextMuncher 自動擷取（推薦）

1. 開啟 Kindle Cloud Reader (`read.amazon.co.jp`)
2. 開啟目標書籍
3. 啟動 TextMuncher 擴充 → 自動翻頁擷取
4. 匯出純文字檔

### 方式 B：Playwright 半自動（Kindle）

```bash
# 需要先手動登入 Kindle Cloud Reader，取得 cookie
npx playwright codegen read.amazon.co.jp
```

用 Playwright 自動翻頁 + `page.innerText()` 擷取每頁文字。適合 TextMuncher 免費額度用完後。

### 方式 C：HONTO BinB Reader 截圖+OCR

BinB Reader 使用字型混淆 DRM，DOM 文字是亂碼，需截圖+OCR。

```bash
node skills/kindle-translate/honto-extract.js \
  --reader-only \
  --title "書名關鍵字" \
  --slug my-book \
  --max-pages 250
```

流程：登入 HONTO → My 本棚 → 自動找書點開 viewer → 逐頁截圖 → Tesseract OCR。

Cookies 存在 `/tmp/honto-playwright-profile/`，首次需手動登入，之後自動。

```bash
# 批次 OCR（截圖完成後）
bash skills/kindle-translate/honto-ocr-batch.sh
```

### 輸出

```
/tmp/kindle-translate/<book-slug>/raw/
  page-001.txt    # HONTO 截圖+OCR 輸出
  page-002.txt
  ...
  chapter-01.txt  # pipeline 自動合併
  chapter-02.txt
  ...
```

---

## Step 1.5：OCR 品質掃描

翻譯前先掃描 OCR 品質，找出需要補強的頁面。

```bash
# 每頁計算亂碼比例（非日文字元 / 總字元）
WORK="/tmp/kindle-translate/<slug>"
for f in "$WORK/raw"/page-*.txt; do
  total=$(wc -m < "$f")
  # 計算可讀日文字元比例（平假名+片假名+漢字+標點）
  readable=$(grep -oP '[\p{Hiragana}\p{Katakana}\p{Han}、。「」（）\p{N}]' "$f" | wc -l)
  if (( total > 0 )); then
    ratio=$((readable * 100 / total))
    (( ratio < 30 )) && echo "LOW  $ratio% $f" || echo "OK   $ratio% $f"
  fi
done
```

品質分級：
- **OK (≥30%)**：可直接翻譯
- **LOW (<30%)**：圖表頁或嚴重亂碼，需補強

### 補強策略

| 亂碼原因 | 補強方式 |
|----------|----------|
| 圖表/表格頁 | Claude Vision 直接讀截圖翻譯，跳過 OCR |
| 縱書辨識差 | 重跑 Tesseract `--psm 5`（縱書模式）或 PaddleOCR |
| 參考文獻頁 | Claude Vision 讀截圖，結構化輸出 |

```bash
# Claude Vision 補強（讀截圖直接翻譯，跳過 OCR）
# 適用於 OCR 品質差但截圖清楚的頁面
/opt/homebrew/bin/claude -p --model claude-haiku-4-5-20251001 \
  "這是日文書籍的截圖，請翻譯為繁體中文。純文字輸出。" \
  --image "$WORK/raw/page-050.png"
```

## Step 2：日文 OCR 校正

TextMuncher OCR 的 3% 錯誤主要集中在：
- 漢字異體字（繁←→日本新字體）
- 假名長音「ー」vs 漢字「一」
- 句讀：「。」「、」位置偏移
- **Tesseract 縱書**：字間多餘空格、圖表頁嚴重亂碼

校正方式：

```bash
# Claude API 校正（每章獨立）
for f in /tmp/kindle-translate/<slug>/raw/chapter-*.txt; do
  claude -p "以下是 OCR 擷取的日文原文，請修正明顯的 OCR 錯字（漢字異體、假名錯誤、標點偏移），不改動原意：\n\n$(cat "$f")" \
    > "/tmp/kindle-translate/<slug>/corrected/$(basename "$f")"
done
```

---

## Step 3：翻譯

### 推薦：Haiku（低成本、速度快）

```bash
# 整本書 ~$0.05-0.1，幾分鐘完成
for f in /tmp/kindle-translate/<slug>/raw/chapter-*.txt; do
  base="$(basename "$f")"
  out="/tmp/kindle-translate/<slug>/translated/$base"
  [ -s "$out" ] && continue  # 跳過已翻譯
  { printf '請將以下日文翻譯為繁體中文。這是 OCR 文字，可能有空格和少量亂碼，盡力翻譯可讀部分，跳過亂碼。保持段落結構，譯文自然流暢。專有名詞首次出現附原文。純文字輸出。\n\n<TEXT>\n'; cat "$f"; printf '\n</TEXT>'; } | \
    /opt/homebrew/bin/claude -p --model claude-haiku-4-5-20251001 > "$out"
done
```

### 主力：Claude API（語感優先、長章節）

```bash
ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY ~/.claude/.env | cut -d= -f2)

for f in /tmp/kindle-translate/<slug>/corrected/chapter-*.txt; do
  curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "$(jq -n --arg text "$(cat "$f")" '{
      model: "claude-sonnet-4-20250514",
      max_tokens: 8192,
      messages: [{
        role: "user",
        content: ("請將以下日文翻譯為繁體中文。保持原文段落結構，譯文要自然流暢，不要翻譯腔。專有名詞第一次出現時附原文。\n\n" + $text)
      }]
    }')" | jq -r '.content[0].text' \
    > "/tmp/kindle-translate/<slug>/translated/$(basename "$f")"
done
```

### Fallback：DeepL API（速度優先）

```bash
DEEPL_KEY=$(grep DEEPL_API_KEY ~/.claude/.env | cut -d= -f2)

curl -s https://api-free.deepl.com/v2/translate \
  -d auth_key="$DEEPL_KEY" \
  -d text="$(cat chapter-01.txt)" \
  -d source_lang="JA" \
  -d target_lang="ZH" | jq -r '.translations[0].text'
```

### 翻譯原則

- 語感自然，不要翻譯腔（「被動式直譯」「的的的」）
- 專有名詞首次出現附原文括號
- 保持原文段落結構
- 對話口語化，敘述保持書面語
- 純文字輸出，不加 markdown 格式符號（#、*、- 等）
- 長章節（> 6000 字）分段送 API，避免 token 截斷

---

## Step 4：雙語 EPUB 組裝

### 目錄結構

```
/tmp/kindle-translate/<slug>/epub/
  OEBPS/
    chapter-01.xhtml   # 雙語排版
    chapter-02.xhtml
    ...
    style.css
    toc.ncx
    content.opf
  META-INF/
    container.xml
```

### 雙語排版格式（每章 xhtml）

```html
<div class="paragraph">
  <p class="ja" lang="ja">日文原文段落</p>
  <p class="zh" lang="zh-TW">繁體中文翻譯</p>
</div>
```

### CSS

```css
.ja { color: #666; font-size: 0.9em; margin-bottom: 0.2em; }
.zh { color: #000; font-size: 1em; margin-bottom: 1.2em; }
.paragraph { margin-bottom: 1.5em; }
```

### 打包

```bash
cd /tmp/kindle-translate/<slug>/epub
zip -X0 "../<slug>-bilingual.epub" mimetype
zip -rX9 "../<slug>-bilingual.epub" META-INF OEBPS
```

---

## 完整流程一鍵跑

```bash
# Usage: kindle-translate <book-slug> <raw-text-dir>
SLUG="$1"
RAW_DIR="$2"
WORK="/tmp/kindle-translate/$SLUG"

mkdir -p "$WORK"/{raw,corrected,translated,epub/OEBPS,epub/META-INF}

# 1. 複製原文
cp "$RAW_DIR"/chapter-*.txt "$WORK/raw/"

# 2. OCR 校正（Claude）
for f in "$WORK"/raw/chapter-*.txt; do
  claude -p "修正 OCR 錯字，不改原意：$(cat "$f")" > "$WORK/corrected/$(basename "$f")"
done

# 3. 翻譯（Claude）
for f in "$WORK"/corrected/chapter-*.txt; do
  claude -p "日文翻繁中，自然流暢，專有名詞附原文：$(cat "$f")" > "$WORK/translated/$(basename "$f")"
done

# 4. 組裝 EPUB（需要另外寫 xhtml 模板）
echo "翻譯完成，EPUB 組裝請手動確認排版後執行"
```

---

---

## Step 5：增訂 Patch（針對特定章節補強）

EPUB 打包完成後，如果特定章節品質差，不需整本重跑：

```bash
WORK="/tmp/kindle-translate/<slug>"
CHAPTER="08"  # 要補強的章節編號

# 1. 找出該章節對應的原始頁面範圍
#    chapter-08 = page-XXX ~ page-YYY（看 raw/full-text.txt 的分段位置）

# 2. 對品質差的頁面用 Claude Vision 重新 OCR
for pg in 100 101 102 103; do
  /opt/homebrew/bin/claude -p --model claude-haiku-4-5-20251001 \
    "這是日文書籍的截圖頁面。請擷取所有日文文字，保持段落結構。純文字輸出，不加格式符號。" \
    --image "$WORK/raw/page-$(printf '%03d' $pg).png" \
    > "$WORK/raw/page-$(printf '%03d' $pg).txt"
done

# 3. 重新合併該章節
#    手動或重跑 pipeline Step 1 的合併邏輯

# 4. 只重翻該章節
{ printf '翻譯指示...\n\n<TEXT>\n'; cat "$WORK/raw/chapter-${CHAPTER}.txt"; printf '\n</TEXT>'; } | \
  /opt/homebrew/bin/claude -p --model claude-haiku-4-5-20251001 \
  > "$WORK/translated/chapter-${CHAPTER}.txt"

# 5. 重組 EPUB（pipeline epub-only 或手動 zip）
bash skills/kindle-translate/kindle-translate-pipeline.sh <slug> epub-only
```

---

## Gotchas

- TextMuncher 免費版 30 頁限制：一本 300 頁的書需要 Pro（$6/月，用完退訂）
- Kindle Cloud Reader 需要 Amazon.co.jp 帳號 + 已購書籍
- HONTO BinB Reader 使用字型混淆 DRM，DOM innerText 是亂碼，必須走截圖+OCR
- Tesseract 縱書日文（jpn_vert）對圖表/表格/參考文獻頁辨識很差（<30% 可讀率），需 Claude Vision 補強
- Claude API 翻譯 cost：Haiku ~$0.05-0.1/本，Sonnet ~$2-4/本
- Haiku 對嚴重亂碼可能拒絕翻譯，需加「盡力翻譯可讀部分，跳過亂碼」指示
- 長章節分段送 API 時，段落邊界要對齊自然斷點（句號結尾），不要切在句子中間
- EPUB 驗證：用 `epubcheck` 確認格式合規再送 Kindle
- DRM：此流程僅適用於已購買書籍的個人使用
- **截圖存放**：一律存到永久目錄（`~/life-os/drafts/<slug>/`），不要只放 /tmp（Mac 重開機會清空）
- **EPUB 命名規則**：原文 `{slug}.epub`、雙語 `{slug}-bilingual.epub`，兩個檔案獨立，雙語版不得覆蓋原文版

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
