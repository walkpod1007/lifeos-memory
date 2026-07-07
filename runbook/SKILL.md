---
name: runbook
description: 故障排除 Runbook。收到錯誤訊息後自動查 Log、定位問題、輸出結構化報告。觸發詞：報錯、error、掛了、Exception、crash、失敗、異常、timeout、502、503、掛掉、壞掉、不動了。
---

# Runbook — 自動化故障排除

腳本：`bash ~/life-os/skills/runbook/scripts/diagnose.sh "<錯誤描述>"`

## 觸發條件

使用者訊息含以下任一關鍵字時啟動：
- 中文：報錯、掛了、掛掉、壞掉、不動了、失敗、異常、當機
- 英文：error、exception、crash、timeout、failed、not working
- HTTP：502、503、500、404（搭配問題描述）

## 使用方式

```bash
bash ~/life-os/skills/runbook/scripts/diagnose.sh "<錯誤描述關鍵字>"
```

**範例：**
```bash
# 查 LINE webhook 相關錯誤
bash ~/life-os/skills/runbook/scripts/diagnose.sh "line webhook"

# 查 gateway crash
bash ~/life-os/skills/runbook/scripts/diagnose.sh "gateway crash"

# 查所有近期錯誤（無關鍵字模式）
bash ~/life-os/skills/runbook/scripts/diagnose.sh ""
```

## 運作流程

1. 接收錯誤描述（關鍵字或完整錯誤訊息）
2. 掃描 Log 位置：
   - `~/.claude/logs/`（如存在）
   - `~/life-os/logs/`
   - `/tmp/openclaw-*.log`（臨時 log）
3. 過濾相關錯誤行（ERROR、WARN、Exception、關鍵字）
4. 輸出結構化報告：
   - 時間戳
   - 錯誤類型分類
   - Log 摘要（最近 20 筆）
   - 建議行動

## 輸出格式

```
=== 🔍 Runbook 診斷報告 ===
時間：2026-03-20 20:00:00
關鍵字：<輸入的錯誤描述>

【錯誤類型】
...

【Log 摘要】（最近相關 20 筆）
...

【建議行動】
1. ...
2. ...

【Log 來源】
...
=========================
```

## 常見故障快查

| 症狀 | 關鍵字 | 常見原因 |
|------|--------|---------|
| Gateway 沒回應 | gateway | crash loop、port 衝突 |
| LINE 無回覆 | line webhook | token 過期、webhook URL 失效 |
| Gemini 失敗 | gemini 429 | Rate limit，等待後重試 |
| n8n 掛了 | n8n | Docker container 停止 |
| 腳本執行失敗 | permission | chmod 未設 |

## 依賴

- `grep`、`tail`、`find`（系統內建）
- `jq`（選用，解析 JSON log）
- Log 位置需存在且有讀取權限

## Hard Bug Mode（結構化偵錯）

Log 掃完沒答案，或問題不在 log 裡時，切換這個模式：

### Phase 1 — 建 feedback loop（最重要）

先有一個可重現、可跑的失敗信號，才能偵錯。按順序試：
1. 寫一個會失敗的測試
2. curl / HTTP script 打 dev server
3. CLI 打 fixture input，diff stdout
4. 如果以上都不行：throwaway harness，最小化環境複現

**沒有 feedback loop 就停**——告訴用戶缺什麼，不要靠感覺猜。

### Phase 2 — 複現

跑 feedback loop，確認：
- 觸發的是用戶描述的問題，不是旁邊剛好有的別的問題
- 多跑幾次，確認可穩定複現

### Phase 3 — 提 3–5 個假設

列出來再測，不要測第一個感覺對的就停。
每個假設必須可以被否證：「如果是 X，那改 Y 後 bug 應該消失」。

### Phase 4 — 插樁（一次改一個變數）

偏好：debugger / REPL > 有目標的 log > 亂 log 全部。
所有 debug log 加 `[DEBUG-tag]` 前綴，最後一次 grep 清掉。

### Phase 5 — 先寫回歸測試，再修

如果有正確的測試 seam：先讓測試紅→修→綠→重跑原始 feedback loop。
沒有合適 seam：記錄下來（這本身就是架構問題的 finding）。

### Phase 6 — 清理 + 問根因

確認：原始問題不再複現、debug log 清除、throw away 程式碼刪除。
然後問：**什麼改動可以讓這個 bug 不會發生**（不是只修好這次）。

---

## Gotchas
- 執行前先確認前置檔案/旗標存在；缺少時直接回報並停止，不要硬做。
- 需要改檔時先備份（.bak），避免錯誤覆寫不可回復。
- 回覆外部訊息前，先完成核心產出檔落地，避免「只說完成但無檔案」。
- 若模型或 API 出現 rate limit / 400 錯誤，改用備援模型並重跑，不要把空跑當成功。

## Confirmation Gate（確認閘機制）

> 整合自 WO-032 Phase B Step 4（2026-03-22）
> 規格來源：confirmation-gate-spec.md

### 危險操作分類

#### 🔴 紅線操作（必須人類明確確認）

**定義**：執行後無法輕易復原，或會造成系統/資料/金錢影響。

| 類別 | 操作 | 風險說明 |
|------|------|----------|
| **刪除** | `rm -rf`、`git push --force`、清空資料庫、刪除檔案 | 資料永久遺失 |
| **改 Config** | 修改 openclaw.json、.env、任何系統設定檔 | 系統行為改變，可能造成服務中斷 |
| **付費** | 呼叫付費 API、訂閱服務、購買資源 | 金錢損失 |
| **版本變更** | `openclaw gateway install --force`、`npm install`、`pnpm install`、升級/降級任何套件 | 依賴衝突、功能回歸、服務不穩 |
| **重啟服務** | `openclaw gateway restart`、重啟 daemon | 服務暫時中斷 |
| **權限變更** | chmod、chown、修改 SSH 設定 | 安全漏洞或無法存取 |
| **對外發送敏感** | 發布到公開平台、發送郵件給多人、社交媒體貼文 | 無法撤回的公開發言 |

**處理方式**：
1. 自動進入討論模式
2. 輸出「⚠️ 風險：」說明最壞情況
3. 等待人類明確說「做」「改」「執行」或 `/執行`
4. 60 秒無回應視為拒絕

#### 🟡 黃線操作（說一句再做）

**定義**：執行後可復原，但會對外部造成影響。

| 類別 | 操作 | 風險說明 |
|------|------|----------|
| **對外發送** | LINE Push（非 Reply）、Telegram 發送、Email 發送 | 消耗配額、打擾接收者 |
| **API 呼叫** | 呼叫外部 API（非付費） | 可能觸發 rate limit |
| **建立資源** | 建立 Google Drive 檔案、建立文件 | 產生新檔案（可刪除） |
| **修改遠端** | 更新 GitHub repo、修改雲端檔案 | 遠端狀態改變 |

**處理方式**：
1. 說明即將執行的操作
2. 等待 60 秒
3. 無回應視為拒絕
4. 有回應（即使只是「嗯」「好」）則執行

#### 🟢 綠線操作（直接執行）

**定義**：只讀或可輕易復原。

| 類別 | 操作 | 說明 |
|------|------|------|
| **讀取** | read、ls、grep、cat | 無副作用 |
| **查詢** | 搜尋網頁、查天氣、查字典 | 無副作用 |
| **腳本執行** | 執行 read-only 腳本 | 腳本本身負責安全檢查 |
| **派工** | sessions_spawn、claude-dispatch | 子 agent 有自己的閘門 |
| **寫 memory** | 寫入 MEMORY.md、memory/*.md | 內部記錄，可刪除 |
| **摘要** | 網頁摘要、影片摘要 | 只讀操作 |
| **Reply** | LINE Reply、Telegram Reply | 使用者主動觸發，免確認 |

### 判斷流程

```
收到指令
    │
    ▼
┌─────────────────────┐
│ 是否為紅線操作？     │──是──▶ 進討論模式，等明確確認
└─────────────────────┘
    │ 否
    ▼
┌─────────────────────┐
│ 是否為黃線操作？     │──是──▶ 說明操作，等 60 秒
└─────────────────────┘
    │ 否
    ▼
直接執行
```

### 關鍵字偵測規則

#### 紅線關鍵字

```
刪除類：刪除、delete、remove、rm、清空、drop
付費類：付費、購買、訂閱、pay、subscribe、purchase
Config類：改config、修改設定、openclaw.json、.env
版本類：升級、降級、install、update、upgrade、npm、pnpm
重啟類：重啟、restart、reload、reboot
權限類：chmod、chown、權限、permission
```

#### 黃線關鍵字

```
發送類：發送、send、push（非 reply）、寄信、email
建立類：建立、create、新增（檔案/資源）
更新類：更新、update（遠端資源）
```

#### 綠線關鍵字

```
讀取類：讀、看、查、找、search、read、list
摘要類：摘要、summarize、總結
記憶類：記住、備忘、memory
```

### 特殊情境

#### 使用者明確指令

若使用者使用 `/執行` 或明確說「做」「改」「執行」：
- 綠線：直接做
- 黃線：直接做（跳過等待）
- 紅線：仍需顯示風險並確認

#### 緊急情境

若 runbook 偵測到緊急情況（服務掛掉、資安事件）：
- 黃線操作可跳過等待
- 紅線操作仍需確認，但等待時間縮短為 30 秒

#### 討論模式

使用者說 `/討論` 或「先看看」「查一下」：
- 所有操作只讀不寫
- 結束時宣告意圖，等人類確認

### 實作介面（Bash 函數）

#### 判斷函數

```bash
# 判斷操作類型
# 回傳：red / yellow / green
gate-classify() {
  local operation="$1"

  # 紅線檢查
  if echo "$operation" | grep -qiE '(刪除|delete|remove|rm|清空|drop|付費|購買|訂閱|改config|修改設定|openclaw\.json|\.env|升級|降級|install|update|upgrade|npm|pnpm|重啟|restart|reload|chmod|chown)'; then
    echo "red"
    return
  fi

  # 黃線檢查
  if echo "$operation" | grep -qiE '(發送|send|push|寄信|email|建立|create|新增.*檔案|更新.*遠端)'; then
    echo "yellow"
    return
  fi

  echo "green"
}
```

#### 確認流程

```bash
# 紅線確認
gate-red-confirm() {
  local operation="$1"
  local risk="$2"

  echo "⚠️ 風險：$risk"
  echo "這是紅線操作，需要你明確確認。"
  echo "請說「做」或「執行」繼續，或說「取消」放棄。"

  # 等待 60 秒
  # 實作方式依 runbook 架構而定
}

# 黃線確認
gate-yellow-confirm() {
  local operation="$1"

  echo "即將執行：$operation"
  echo "60 秒內無回應將視為取消。"

  # 等待 60 秒
}
```

### 與現有機制的整合

#### AGENTS.md 安全線

本規格是 AGENTS.md 安全線的詳細展開，兩者保持一致：
- 紅線 = 🔴 紅線操作
- 黃線 = 🟡 黃線操作
- 綠線 = 🟢 綠線操作

#### 紅隊三檢查

紅線操作執行前，runbook 應觸發紅隊三檢查：
1. 反向思考（最壞情況）
2. 誠實邊界（標注不確定）
3. 反脆弱（單點故障分析）

## 確認閘使用方式
呼叫 gate-confirm.sh 判斷操作等級：
```bash
bash ~/life-os/skills/runbook/scripts/gate-confirm.sh red '刪除設定檔' '設定檔刪除後需重新設定所有 API key'
# exit 2 = 等待使用者確認
# /tmp/gate-pending.json 已寫入，主 session 應偵測此旗標並推 LINE 通知
```

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
