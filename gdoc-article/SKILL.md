---
name: gdoc-article
description: >
  把一個主題做成帶圖、帶格式的 Google Doc 文章，走起承轉合五段結構，配 Codex 改寫，輸出 Doc URL。
  觸發：做成 doc 文章、寫起承轉合到 google doc、把分析做成 google doc、開源文章、寫 doc 報告。
  不觸發：只要純文字 markdown（直接輸出就好）、只要 Drive 檔案（用 gog 技能）。
version: "1.0"
created: "2026-06-26"
---

# gdoc-article

把一個主題做成帶圖、帶格式的 Google Doc 文章。固化 2026-06-26 做 Skill 元系統 & 任務 SOP 兩篇文章時走通的完整流程。

## 為什麼存在這個技能

手動一步步建 Google Doc 很容易踩坑：圖片位置偏移、清除內容時圖也消失、中文字型缺失、Codex 不認識特定 flag。本技能固化所有已知坑的解法。

## 流程（6 步）

### 1. 內容草稿

按【前言】【1/5】到【5/5】的起承轉合結構寫文章，存成 `scratchpad/TOPIC_article.txt`。

結構：
- 【前言】：Why does this matter？用比喻拉近讀者
- 【1/5】起：問題是什麼
- 【2/5】承：各元件做什麼（多個小節）
- 【3/5】承：它們如何協同運作
- 【4/5】轉：跟現有方案的差距
- 【5/5】合：最獨特 + 如何開源

### 2. Codex 改寫（初學者友善版）

```bash
cat scratchpad/TOPIC_codex_prompt.txt | codex exec > scratchpad/TOPIC_codex_result.txt
```

Prompt 模板：
```
你是一位技術寫作者，專門把 AI 工具的概念轉化成初學者也能看懂的文章。

請審查以下文章並改善，目標讀者是完全沒有 AI 工具開發背景的一般用戶（只有 Claude 訂閱，不會寫程式）。改善重點：
1. 語句更口語、易讀，去掉所有程式術語黑話
2. 第一次出現的技術詞都要用括號補白話解釋
3. 前言部分要更吸引人，讓不懂 AI 的人也想繼續讀
4. 五段起承轉合邏輯更流暢，段落間的銜接更自然
5. 語言：繁體中文

請直接輸出完整改善後的文章，不要解釋你改了什麼，保留【前言】【1/5】到【5/5】的段落標題格式。

原文：
[貼入文章]
```

⚠️ Codex 已知坑：
- 不要用 `-m gpt-4.1`（ChatGPT 帳號不支援）→ 不指定 model，預設跑 gpt-5.5
- 不要用 `--quiet` 或 `--approval-mode`（此版本無此 flag）
- result 檔頭部有 session header，實際文章從 `echo hello` 回應之後開始（用 `grep -n "【前言】" file` 找起始行）

### 3. 建立 blocks 陣列

從 Codex result 提取文章，組成 Python blocks 陣列：
```python
blocks = [
    ("標題\n", "HEADING_1"),
    ("副標題\n", "SUBTITLE"),
    ("\n", "NORMAL_TEXT"),
    ("【前言】...\n", "HEADING_2"),   # 每個 H2 自動套寶藍色粗體
    ("內文...\n\n", "NORMAL_TEXT"),
    ("【1/5】起：...\n", "HEADING_2"),
    ("...", "NORMAL_TEXT"),
    ("小節標題\n", "HEADING_3"),
    ("小節內文...\n\n", "NORMAL_TEXT"),
    # ... 依此類推
]
```

### 4. 生圖（每個 【N/5】 一張）

```bash
python3 ~/life-os/scripts/imagen-gen.py --fast --out scratchpad/imgs/section_N "圖片描述（英文）"
```

圖片描述原則：概念示意圖（抽象好看）優於截圖模擬（AI 會亂造日期/文字）。

上傳到 Drive：
```bash
gws drive +upload PATH
gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"reader","type":"anyone"}'
```

Drive 圖片 URL 格式：`https://drive.google.com/uc?export=view&id=FILE_ID`

### 5. 建立/更新 Google Doc

```python
import subprocess, json

DOC_ID = "..."  # 已存在的 doc，或先用 gws docs 建立新的
ROYAL_BLUE = {"red": 65/255, "green": 105/255, "blue": 225/255}

# Step A: 清除舊內容
doc = get_doc(DOC_ID)
end_index = doc["body"]["content"][-1]["endIndex"]
delete_req = [{"deleteContentRange": {"range": {"startIndex": 1, "endIndex": end_index - 1}}}]

# Step B: 插入全文
all_text = "".join(b[0] for b in blocks)
requests = [{"insertText": {"location": {"index": 1}, "text": all_text}}]

# Step C: 套 paragraph styles + H2 寶藍色
current = 1
for text, style in blocks:
    end = current + len(text)
    if style != "NORMAL_TEXT":
        requests.append({"updateParagraphStyle": {...}})
    if style == "HEADING_2":
        requests.append({"updateTextStyle": {
            "range": {"startIndex": current, "endIndex": end - 1},
            "textStyle": {"bold": True, "foregroundColor": {"color": {"rgbColor": ROYAL_BLUE}}},
            "fields": "bold,foregroundColor"
        }})
    current = end

# Step D: 插入圖片（逆序，避免 index 偏移）
# 找 H2 headings 的 【N/5】 位置 → 插圖在 H2 之後
# 逆序插入：先插最後一張，再往前
```

⚠️ 已知坑：
- 清除文件後圖片會消失 → 必須重新 insertInlineImage
- insertInlineImage 必須逆序（從後往前）才不會讓 index 偏移
- Google Drive 圖片 URL 必須是 `uc?export=view` 格式，不是 share 連結
- 插入文字後立刻套樣式，不要分兩次 batchUpdate（index 會偏移）

### 6. 替換/更新特定圖片

如需替換 Doc 內某張圖：
```python
# 找 inline image positions
for elem in content:
    if "paragraph" in elem:
        for pe in elem["paragraph"]["elements"]:
            if "inlineObjectElement" in pe:
                inline_images.append((pe["startIndex"], pe["endIndex"]))

# 先 deleteContentRange 刪舊圖，再 insertInlineImage 插新圖
# 兩個 request 放同一個 batchUpdate，順序：先刪後插
```

## 交付格式

完成後回覆 LINE：
```
Doc 完成：[標題]

[一句話說明改了什麼/加了什麼]

👉 https://docs.google.com/document/d/[DOC_ID]/edit
```

## 常用命令速查

```bash
# 讀 Doc
gws docs documents get --params '{"documentId":"ID"}'

# 批次更新
gws docs documents batchUpdate --params '{"documentId":"ID"}' --json '{"requests":[...]}'

# 上傳 Drive
gws drive +upload /path/to/file

# 設公開
gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"reader","type":"anyone"}'
```
