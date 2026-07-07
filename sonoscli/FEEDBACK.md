# sonoscli Skill Maintenance Feedback

Date: 2026-03-09
Task: cc-20260309-115134-27775

---

## 1. SKILL.md Frontmatter 檢查結果

### 問題發現

| # | 位置 | 問題 | 嚴重度 |
|---|------|------|--------|
| 1 | metadata JSON | 多處 trailing comma（JSON 語法錯誤，如 `"label": "...",` 和 `},` 結尾） | 中 |
| 2 | 全文 | `sonos play spotify "..."` 指令不存在（舊文件錯誤） | 高 |
| 3 | 全文 | `sonos play spotify ... --enqueue` 指令不存在 | 高 |

### 修復內容

- **frontmatter JSON trailing commas 移除**：所有 JSON 值末尾多餘逗號已清除，確保 JSON 合法性
- **指令文件修正**：
  - `sonos play spotify "..."` → `sonos search spotify "..." --open --name "..."`
  - `sonos play spotify ... --enqueue` → `sonos search spotify "..." --enqueue --name "..."`
  - 補充 `sonos open <uri>` 和 `sonos enqueue <uri>` 直接 URI 播放方式

---

## 2. 腳本語法檢查

### 現有腳本

- 原始目錄中無獨立腳本，僅有 SKILL.md。
- `bash -n` 語法驗證已對新建腳本執行 → **通過**

### 新增腳本：`spotify-uri-play.sh`

**語法檢查結果**：`bash -n spotify-uri-play.sh` → ✅ Syntax OK

---

## 3. Spotify URI 解析與分組播放功能增強

### 新增檔案：`spotify-uri-play.sh`

**功能特性**：

#### URI 格式支援（全部通過測試）

| 輸入格式 | 解析結果 |
|----------|----------|
| `spotify:track:XXXX` | 直接使用 |
| `spotify:album:XXXX` | 直接使用 |
| `spotify:playlist:XXXX` | 直接使用 |
| `https://open.spotify.com/track/XXXX` | → `spotify:track:XXXX` |
| `https://open.spotify.com/track/XXXX?si=...` | → `spotify:track:XXXX`（strip query） |
| `track:XXXX`（shorthand） | → `spotify:track:XXXX` |

**測試結果**：6/6 URI 解析正確 ✅

#### 播放模式

| 模式 | 指令 | 說明 |
|------|------|------|
| 搜尋並播放 | `--search "query"` | 呼叫 `sonos search spotify ... --open` |
| 搜尋並加入佇列 | `--search "query" --enqueue-only` | 呼叫 `sonos search spotify ... --enqueue` |
| URI 直接播放 | `./script.sh --room X uri` | 第一個 `open`，後續 `enqueue` |
| URI 批次加入 | `--enqueue-only uri1 uri2` | 全部 `sonos enqueue` |
| 全員派對模式 | `--party` | 先 `sonos group party`，再播放 |

#### 使用範例

```bash
# 單首播放
./spotify-uri-play.sh --room "書房" "spotify:track:6NmXV4o6bmp704aPGyTVVG"

# 分享連結播放
./spotify-uri-play.sh --room "書房" "https://open.spotify.com/track/6NmXV4o6bmp704aPGyTVVG"

# 批次播放多首（第一首 open，後續 enqueue）
./spotify-uri-play.sh --room "書房" \
  "spotify:track:AAA" \
  "spotify:track:BBB" \
  "spotify:track:CCC"

# Party Mode：全員同步
./spotify-uri-play.sh --room "客廳" --party "spotify:track:XXXX"

# 搜尋模式
./spotify-uri-play.sh --room "書房" --search "Miles Davis Kind of Blue"
```

---

## 4. 目前目錄結構

```
~/.openclaw/skills/sonoscli/
├── SKILL.md              # 已修正：frontmatter + 指令文件
├── spotify-uri-play.sh   # 新增：URI 解析 + 分組播放腳本
└── FEEDBACK.md           # 本檔案
```

---

## 5. 建議後續改進

1. **`--group` 參數**：支援指定多個房間名稱（逗號分隔），逐一呼叫 `sonos group join`
2. **URI 批次檔讀取**：`--file playlist.txt` 從文字檔讀取 URI 清單
3. **重試邏輯**：網路不穩時自動 retry（目前無）
4. **SMAPI playlist 支援**：如果 Spotify playlist URI 失敗，fallback 到 SMAPI 逐首搜尋
