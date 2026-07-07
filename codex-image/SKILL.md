# codex-image — AI 生圖（gpt-image-2）

> 觸發：「生圖」「畫圖」「做封面」「YT 封面」「YouTube 封面」「縮圖」「thumbnail」「codex 生圖」「幫我生一張」「做圖」
> 不觸發：截圖（用 peekaboo）、照片編輯（用原生 app）、SVG/icon（用 frontend skill）

## 引擎

Codex CLI 訂閱制內建 gpt-image-2（built-in `image_gen` tool），不需 API key。

## 三階段工作流

### 階段 1：範本收集（可選）

使用者提供參考素材時：
1. 將參考圖存到 `/tmp/codex-image-ref/` 目錄
2. 每張圖標記角色：`edit target` / `style reference` / `layout reference` / `color reference`
3. 確認：「收到 N 張範本，角色分別是 [X]。要用什麼風格生成？」

參考圖來源：
- 本地檔案路徑 → 直接 cp
- URL → WebFetch 下載到 `/tmp/codex-image-ref/`
- Drive 檔案 → `gws drive` 下載

### 階段 2：生成

組裝 prompt 後交給 codex：

```bash
/Applications/Codex.app/Contents/Resources/codex exec "<assembled_prompt>" --skip-git-repo-check -s danger-full-access
```

> ⚠️ **必用 App 內建 binary**：系統 homebrew `codex`（v0.125.x）不認識 config.toml 裡的 `service_tier = "priority"`，會靜默退出（exit 0 但什麼都沒跑）。App binary（`/Applications/Codex.app/Contents/Resources/codex` v0.142.x+）才支援。兩個版本的指令語法相同，直接換路徑即可。

**Prompt 組裝規則**（依 codex imagegen prompting.md）：
- 結構順序：scene/backdrop → subject → key details → constraints → output intent
- 有範本時標記 index + role：`Image 1: style reference, Image 2: edit target`
- 文字渲染：把要出現的文字放引號或 ALL CAPS，指定字體風格/大小/顏色/位置
- 約束明確：`no watermark`、`no logos`、尺寸、用途

**YouTube 封面專用 prompt 模板**：

```
Use case: YouTube thumbnail
Primary request: {使用者描述}
Scene/backdrop: {背景描述}
Subject: {主體描述}
Style/medium: bold, eye-catching YouTube thumbnail
Composition/framing: landscape 1280x720, high contrast, clear focal point
Text (verbatim): "{標題文字}"
Typography: bold sans-serif, large, high contrast outline/shadow for readability
Lighting/mood: {氛圍}
Constraints: no watermark; no small text; readable at mobile size; 1280x720 landscape
```

生成後：
1. 圖會存在 `~/.codex/generated_images/` 下
2. 複製到 `/tmp/codex-image-output/` 並以語義命名（如 `yt-thumbnail-topic-v1.png`）
3. 回報：「生成完成，[描述]。要調整嗎？」並用 Read 顯示圖片

### 階段 3：細部修改（迭代）

修改原則（依 codex imagegen prompting.md）：
- 每次只改一件事，不要整段 prompt 重寫
- 重申不變的約束：`keep background unchanged`、`keep text unchanged`
- 具體描述要改什麼：「把標題字改大」「背景換暖色調」「人物表情改成微笑」

修改指令格式：
```bash
/Applications/Codex.app/Contents/Resources/codex exec "Edit the image at /tmp/codex-image-output/{filename}: {具體修改}. Keep everything else unchanged." --skip-git-repo-check -s danger-full-access
```

每輪修改後用 Read 顯示新圖，問：「這樣 OK 嗎？還要調？」

### 完成：上傳 Drive

使用者確認定稿後：

```bash
gws drive +upload /tmp/codex-image-output/{final}.png --parent 1dUgNsLwCEcxKKwZZP247n7uWQ4LSwcSw --name "{語義檔名}.png"
```

Drive 資料夾：`AI-Generated`（ID: `1dUgNsLwCEcxKKwZZP247n7uWQ4LSwcSw`，已開公開連結）

回報 Drive 連結給使用者。

## 尺寸速查

| 用途 | 尺寸 |
|------|------|
| YouTube 封面（thumbnail） | 1280 x 720 |
| Instagram 貼文 | 1080 x 1080 |
| IG Story / Reels 封面 | 1080 x 1920 |
| 部落格 hero | 1200 x 630 |
| 4K 桌布 | 3840 x 2160 |
| 透明背景素材 | 依需求（走 chroma-key 流程） |

## 透明背景

gpt-image-2 不支援原生透明。流程：
1. Prompt 加 `on a perfectly flat solid #00ff00 chroma-key background, no shadows, no gradients, crisp edges, generous padding`
2. 生成後用 codex 內建 `remove_chroma_key.py` 去背
3. 主體含綠色時改用 `#ff00ff`

## 注意事項

- codex exec 每次約吃 40K-60K tokens（計入訂閱額度），複雜圖 + 迭代會更多
- 有參考圖時圖片消耗更大（每張參考圖約 2-3x）
- 一個主題的完整流程（範本→生成→2-3 輪修改→定稿）預估 150K-200K tokens

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
