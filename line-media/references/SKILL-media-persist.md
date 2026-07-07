# SKILL-media-persist.md
# 工單：LB-015R 媒體持久化
# 用途：確保 LINE 傳入的媒體檔案不會因暫存清理而遺失

## 背景
OpenClaw 收到 LINE 媒體時，下載到 /var/folders/（macOS 暫存）。
此路徑在 agent 沙盒之外，無法直接讀取。
line-media-persist hook 會自動複製到 workspace/media-cache/{basename}。

## 媒體沙盒 Fallback 規則（最重要）
當嘗試讀取媒體檔案遇到以下錯誤時：
- "Local media path is not under an allowed directory"
- "Permission denied" 指向 /var/folders/
- 任何 /var/folders/ 路徑的存取失敗

立即執行 fallback：
1. 從錯誤訊息或 content 中取得原始檔名（basename）
2. 到 workspace/media-cache/{basename} 尋找對應檔案
3. 使用 media-cache 中的副本繼續處理

## 適用範圍
此規則適用於所有媒體類型：
- 圖片（.jpg, .png, .gif, .webp）
- 語音（.m4a, .ogg, .mp3）
- 影片（.mp4）
- 文件（.pdf, .docx, .xlsx）

## Hook 機制
- Hook 名稱：line-media-persist
- 位置：workspace/hooks/line-media-persist/
- 事件：message:received（fire-and-forget）
- 動作：偵測 /var/folders/ 路徑 → cp 到 media-cache/{basename}

## 清理機制
media-cleanup.sh 定期清理超過 7 天的快取檔案：


bash workspace/projects/line-experience-lab/scripts/media-cleanup.sh


## Google Drive 備份
媒體處理完成後，依類型上傳至：
- 圖片 → 🦞 龍蝦系統/user-uploads/images/
- 語音 → 🦞 龍蝦系統/user-uploads/voice/
- 文件 → 🦞 龍蝦系統/user-uploads/documents/
