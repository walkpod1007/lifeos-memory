---
name: imagen-gen
description: 用 Gemini Nano Banana 文生圖，輸出 PNG。觸發：生圖、畫圖、做封面、做海報、imagen、Nano Banana、AI 生圖
version: 1.0.0
---

# Imagen Gen — AI 圖片生成

## 概述

呼叫 imagen-gen.py，透過 Gemini API（Nano Banana 系列）生成圖片。
支援單張、批次、fast/pro/ultra 三個等級。

## 前置條件

### 1. Python 3
```bash
python3 --version   # 需要 3.8+
```

### 2. Gemini API Key
使用 `GEMINI_API_KEY` 環境變數（存於 `~/.claude/.env`）：
```bash
echo $GEMINI_API_KEY   # 確認已設定
```

若未設定，從 `~/.claude/.env` 載入：
```bash
source ~/.claude/.env
```

### 3. 腳本路徑
```bash
ls ~/life-os/scripts/imagen-gen.py
```

---

## 使用方式

### 單張生圖
```bash
python3 ~/life-os/scripts/imagen-gen.py "prompt 內容" --out /tmp/my-image
```

### 快速版（Nano Banana 2，速度快）
```bash
python3 ~/life-os/scripts/imagen-gen.py "prompt" --fast --out /tmp/out
```

### 批次生圖（多張）
```bash
python3 ~/life-os/scripts/imagen-gen.py "prompt" --count 4 --out /tmp/out
```

### 輸出
- 圖片存到 `--out` 指定目錄
- 檔名格式：`001-prompt-前50字.png`
- 成功時 stdout 輸出每個檔案路徑

---

## Skill Store Icon 批次流程

為 Life-OS 29 個 skill 生成 iOS 風格 icon：

```bash
# 每個 skill 一行，格式：skill名稱|prompt
while IFS='|' read -r skill prompt; do
  python3 ~/life-os/scripts/imagen-gen.py \
    "$prompt" \
    --out "$HOME/life-os/skills/$skill" \
    --fast
  # 重命名為 icon.png
  mv "$HOME/life-os/skills/$skill/001-"*.png \
     "$HOME/life-os/skills/$skill/icon.png" 2>/dev/null
done < $HOME/life-os/skills/imagen-gen/icon-prompts.txt
```

prompt 清單見 `skills/imagen-gen/icon-prompts.txt`（待建立）。

---

## 模型選擇

| 旗標 | 模型 | 速度 | 品質 |
|------|------|------|------|
| 無（預設） | gemini-3-pro-image-preview | 中 | 高 |
| --fast | gemini-3.1-flash-image-preview | 快 | 中 |
| --ultra | gemini-3-pro-image-preview 4K | 慢 | 最高 |

Icon 批次建議用 `--fast`；封面圖或重要圖片用預設或 `--ultra`。

---

## 錯誤處理

| 錯誤 | 原因 | 處理 |
|------|------|------|
| `API key not found` | key 路徑不存在 | 建立 key 檔案 |
| `HTTP 429` | quota 超限 | 等待後重試，或改用 --fast |
| `No predictions returned` | prompt 被過濾 | 修改 prompt，避免敏感字詞 |

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
