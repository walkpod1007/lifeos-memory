# SKILL-image-gen.md
# 龍蝦 AI 生圖規則（LB-009R / LB-021R）

## 1. 生圖策略
**⚠️ 執行規範**：本任務預計耗時較長，應依照 `SKILL-task-dispatch.md` 分派給 Subagent 執行。

預設使用 Google Gemini 原生模型以節省配額並提高速度。

### 引擎優先順序 (Fallback 機制)：
1.  **Imagen 4 Standard** (`imagen-4.0-generate-001`)：預設引擎，品質與速度平衡。
2.  **Imagen 4 Ultra**：高品質備援。
3.  **Imagen 4 Fast**：極速備援。
4.  **DALL-E 3**：最終備援，僅在 Google 服務全數失效時觸發。

## 2. 輸出規範
- **雙重傳送**：必須同時傳送一張 **Flex 資訊卡片** 以及一張 **原始圖片訊息**（方便用戶直接下載）。
- **CDN 託管**：生成的圖片 Base64 會自動上傳至 `catbox.moe`。

## 3. 相關腳本
- `projects/line-experience-lab/scripts/image-gen.sh`
- `projects/line-experience-lab/scripts/image-speed-test.sh`

## 輸出規則
生圖完成後，必須使用 Flex Message 回覆，模板路徑：
~/.openclaw/workspace/projects/line-experience-lab/templates/image-result.json
讀取模板 → 填入圖片 URL 與說明 → 用 LINE reply API 發送。
失敗時使用 templates/task-failed.json。
不得用純文字回覆生圖結果。
