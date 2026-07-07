---
name: region-streaming-check
version: 1.0
created: 2026-06-25
description: 查影視作品在哪些國家哪個串流平台看得到。觸發：這片哪裡看、XX國 Netflix 有沒有、跨區片庫、justwatch＋具體片名
---

# region-streaming-check — 跨區串流片庫查詢

給片名（任何語言）→ 回報這部片在指定國家、哪些官方串流平台上架（放題/租/購買），哪裡沒有。引擎用 **JustWatch 未文件化但可用的 GraphQL endpoint（免 API key、120+ 國家、涵蓋 Netflix 在內所有平台）**——非官方保證，當它是「可能變動的 web endpoint」，壞了就退 WebSearch。

## 資料源決策（2026-06-25 Tier 0 實測）

- **JustWatch GraphQL（主引擎）**：`https://apis.justwatch.com/graphql`，免 key、實測多國查詢可用、涵蓋 Netflix/Disney+/Prime/HBO Max/U-NEXT 等。**這一個就覆蓋整個需求**（含 Netflix，不需另查 unogs）。
- **unogs**：免費 API 已改走 RapidAPI（需付費 key，實測 401）。**不自動查**；只當「想瀏覽某國 Netflix 獨家整櫃片單」時，人工開 unogs.com UI 的補充工具。
- **MubiFinder（mubifinder.com）**：MUBI 輪播即時狀態專用。2026-06-27 實測：**WebFetch 可用**（非官方粉絲站，HTML 爬取，無公開 API）。JustWatch 對 MUBI 有延遲，mubifinder 更即時——當需要確認「這部片現在 MUBI 哪個國家可播」時用這層補查。
  - 單片查詢：`WebFetch https://mubifinder.com/movie/<film-slug>/`（slug 格式：片名小寫 + 連字號，如 `little-otik`、`no-7-cherry-lane`）
  - 某國全片單：`WebFetch https://mubifinder.com/movies/country/<ISO碼>/`（如 `tw`、`jp`、`us`）
  - 回傳「not available in any country」＝目前全球都不在輪播；找不到頁面（404）＝從未被 mubifinder 收錄。
  - **VPN 選區建議場景**（使用者問「該掛哪個VPN國家看得到」，尤其多片一次問）：可把**澳洲（AU）列為第一個候選驗證國，不得直接視為答案**——2026-07-03 實測 11 部片（含只授權大洋洲+太平洋島國package的冷門片）AU 全部命中，覆蓋率比德/英/美/日這些「常見大國」都高，且 AU 本身是主流穩定 VPN 節點不算冷門。做法：對每部片的完整國家清單逐一確認 AU 是否在列，若使用者堅持要德/英/美/日四選一，再另外算哪個覆蓋最多、誠實列出缺片。這是操作經驗、不是保證每次都成立，仍要抓實際清單驗證，不要跳過查證直接斷言「掛AU就好」。
- **YouTube（第二平台源，2026-06-25 加）**：本機 `yt-dlp` 免 key 搜 YouTube。JustWatch 只收授權串流，**YouTube 原生內容**（網路怪談、錄影帶都市傳說、紀錄片、個人頻道劇集）查不到時用這層補——YouTube 本身就是合法「哪裡看」的平台。只列公開影片連結，不下載、不播放、不碰盜版。腳本 `yt-search.py`。
- **WebSearch fallback**：JustWatch 查不到時，退回 WebSearch 人工確認，並誠實標「查不到」。

## 用法

```bash
DIR=~/life-os/skills/region-streaming-check/scripts

# 授權串流查詢（主引擎，JustWatch）
python3 $DIR/jw-check.py "<片名>" "TW,JP,US"
# 第二參數省略 → 預設 TW,JP,US；可依使用者問的國家調整

# 片名歧義時先列候選消歧（同名多片、譯名不確定）
python3 $DIR/jw-check.py --list "<片名>" "JP"
# 列前 6 筆候選（片名/年份/類型/平台/URL），挑對的再正式查

# 第二平台源：YouTube 原生內容（JustWatch 查不到時補）
python3 $DIR/yt-search.py "<關鍵字>" 5
# 列 YouTube 前 N 筆（標題/頻道/長度/連結），免 key、不下載不播放
```

腳本輸出已是手機好讀格式（🎬 片名／✅ 國家: 平台（放題/租/購）／❌ 沒有；📺 YouTube）。直接把輸出整理給使用者即可。

## 流程

1. 抓片名（必要）＋目標國家（使用者有指定就用；沒指定預設 TW＋詢問國＋US，或直接問使用者要查哪幾國）。
2. 跑 `jw-check.py "<片名>" "<國家碼>"`。國家用 ISO 兩碼（TW/JP/US/GB/KR…）。
3. 整理輸出：哪國哪平台看得到（標放題/租/購）、哪國沒有。
4. 若全部查不到 → 先判斷是否「YouTube 原生內容」（網路怪談/錄影帶都市傳說/紀錄片/個人頻道劇集這類本來就不會上授權串流的東西）。是 → 跑 `yt-search.py "<關鍵字>" 5` 把 YouTube 連結當第二平台源回報；否 → 照腳本提示誠實回報，並可主動補一次 WebSearch 再確認。
5. 命中後可順帶提醒：想看某國限定 → 該平台帳號切區 + Chrome 沉浸式翻譯字幕（使用者已有此能力）。

## 輸出格式（範例）

```
🎬 全裸監督
✅ JP: Netflix（放題）
✅ TW: Netflix（放題）
❌ KR: 沒有
```

## 依賴與紅線

- 只需 `python3`（標準庫 urllib，無第三方套件）＋對外網路。YouTube 第二源另需本機 `yt-dlp`（已裝；`brew install yt-dlp`）。
- **只回報官方串流上架**；不提供播放/下載、不推薦盜版站。若使用者問到盜版，明確區隔信心等級、不混報。
- JustWatch 是非官方/未文件化 endpoint，rate-limit 紀律：**一次最多查 ~10 國**（腳本已限），國家逐一查即可、別 batch 掃 120 國、別迴圈狂打；腳本遇 4xx（429/403）會提示被限流 → 停手改 WebSearch。
- **WebSearch fallback 具體步驟**：JustWatch 查不到或被限流 → `WebSearch "site:justwatch.com <片名> <國家>"` 或 `WebSearch "<片名> <國家> netflix/disney+ 串流"` → 命中就回報並標「來自網頁查證、非 API」，仍查不到就誠實說不確定。

## 錯誤處理

- 查無資料 → 「沒查到，不代表絕對沒有，可能是新片或 JustWatch 未收錄」，不要編造片名/平台。
- 片名歧義（同名多片）→ 取 JustWatch 最相關第一筆，並把回傳的片名＋年份一起標出讓使用者確認。
- API 逾時/錯誤 → 回報失敗 + 退 WebSearch。

## JP Netflix 獨家查詢（補充場景）

使用者問「日本 Netflix 有什麼其他地方沒有的」→ 這不是「某片哪裡看」，而是「跨區片庫比較」，回答邏輯如下：

**背景知識（常識層）**：
- Netflix JP 原創（Originals）大多**全球同步**——地面師たち、城市獵人、Alice in Borderland 台灣都拿得到。
- 真正 JP-only 的通常是：(1) 日本電視台授權 Netflix 但只買 JP 版權的劇（FujiTV/TBS 舊作等）；(2) 日本本土真人秀（バチェラー日本版等）。

**查具體片單**：推薦人工開 **unogs.com**（免費 UI，可選國家→篩「只有該國有的」）。自動 API 已改付費 key，不自動跑；但 UI 可用。
→ 回覆格式：「查個別片用 unogs.com → 搜片名看哪些國 Netflix 有；要瀏覽整個 JP 獨家片單，開 unogs.com > Netflix > Japan > 篩 Japan-only。」

## 不做什麼

- 不播放、不下載、不找盜版。
- 不自動查 unogs（需付費 key）；要瀏覽整國片單再人工開 unogs.com。

## Lineage
- 來源：line-note 工單 worktickets/2026-06-24-cross-region-streaming-skill.md（《粗日怪談》查詢延伸）
- Tier 0 實測：JustWatch GraphQL 免 key 多國可用；unogs 免費 API 已需付費 key → 改 JustWatch 單源 + WebSearch fallback
- 升級 2026-06-25 claude-line Tier 0：jw-check.py 加 `--list` 消歧模式（列年份/類型/URL，解同名配錯片）；新增 yt-search.py YouTube 第二平台源（yt-dlp 免 key，補 JustWatch 不收的 YouTube 原生內容）。
- 建立：2026-06-25，claude-line Tier 0
