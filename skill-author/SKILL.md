---
name: skill-author
description: 從零做新 skill 標準流程：派 worker 寫 script→codex 紅隊→補 SKILL.md。觸發：做一個 skill、製作 skill、新增 skill、skill-author
version: "1.0"
created: "2026-05-04"
---

# skill-author

從零做新 skill 的 SOP。固化 2026-05-04 做 `switch-channel-model` skill 時走通的流程，避免下次重新摸索。

## 為什麼存在這個技能

`skill-vetting` 處理外來 skill、`skill-optimizer` 優化已存在 skill，但「從零自己做新 skill」沒有 SOP。實務上會踩坑：
- 派 glm-code 寫 script 被它自己的 permission 攔（`~/life-os/skills/` 寫不進去）
- mini-agent 不在 PATH 沒設 invocation
- 沒走紅隊就交付 → 帶著 HIGH severity bug 上線

本 skill 把流程固化：派工優先、撞牆 fallback opus 自寫、紅隊強制。

## 6 步流程

### 0. 三層研究（搜尋優先於建造）

在動手之前，強制走三層：

**Layer 1 — 現有 life-os 有沒有**
```bash
ls ~/life-os/skills/
```
找觸發詞重疊、功能相近的。有的話：是要擴展它，還是確實要新建？

**Layer 2 — 社群有沒有現成方案**
快速搜 gstack / GitHub / 社群（≤ 10 分鐘）。找到就讀，評估是否直接用或 fork。

**Layer 3 — 他們的假設在我們脈絡裡哪裡錯了**
看完 L1+L2 後，問：「我們的限制或需求跟他們的假設有什麼不同？」
這個 diff 就是新 skill 的存在理由。沒有 diff → 大概不需要新建。

三層都走完，再進 Step 1。

### 1. 釐清範圍
- 一句話定義：這 skill 解什麼問題？觸發詞是什麼？
- 對照 Step 0 確認觸發詞不重疊，且有 Layer 3 的 diff
- 估計需要：純 SKILL.md（純文件指引）/ + script / + reference 子目錄

### 2. 建目錄
```bash
mkdir -p ~/life-os/skills/<skill-name>/scripts  # script 不需要就省略
```

### 3. 主 session 寫 SKILL.md（**worker 禁止寫**，子代理紅線）
參考 `skill-vetting` 規範的 frontmatter 格式：
```yaml
---
name: <skill-name>
description: >
  動詞開頭一句功能描述。
  觸發：觸發詞 1、觸發詞 2、使用場景。
  不觸發：不適用場景（指向其他 skill 名稱）。
  消歧：歧義關鍵字的判斷規則。
version: "1.0"
created: "YYYY-MM-DD"
---
```
- 內容 ≤ 80 行，前 10 行必含「為什麼存在」段（記錄踩坑驅動，避免下次重蹈）
- **主體必須包含三段**（缺任何一段視為未完成）：
  - **Happy path**：主流程，正常情況下怎麼跑
  - **Degraded path**：工具失敗 / MCP 斷 / 檔案不存在時，怎麼降級但不中斷
  - **Guard（紅線）**：禁止做的事 + 為什麼（❌ ✅ 格式）
- 結尾必含「紅線」清單（❌ ❌ ✅ 格式）

### 4. 派 worker 寫 script（如果需要）
- 估 ≥ 10 步迴圈 → mini-agent；3-10 步 → glm-code
- 任務包格式（CLAUDE.md 規定）：目標 / 輸入 / 產出 / 驗收 / 限制
- **撞牆 fallback**：worker 兩次寫不進去（glm-code permission 攔最常見）→ opus 直接 Write，不要再 retry。理由見 memory `feedback_pragmatic_dispatch.md`。

### 5. codex 紅隊（無差別必跑）
```bash
codex exec "<紅隊指示，列出要審的點>"
```
紅隊指示模板：
- 列你期望它審的 N 個點（command injection / race / 邊界 / 誤觸發）
- 要求格式：finding 1: <描述> [severity: CRITICAL/HIGH/MEDIUM/LOW] + 整體結論 PASS/FAIL/需要修
- 找到 finding → 派回 worker（或 opus fallback）修 → **再跑一次紅隊** Round 2
- Round 2 PASS 才算收工

### 6. sanity check + 結案回報
- `bash -n <script>` syntax check
- 跑引數錯誤路徑（不擾動實際系統）：no-args / bad arg → exit 3
- 真實流程驗收：對 no-op 目標跑一次（例如 model 切換成「跟現在相同」的 model 應該成功不變化）
- 結案回報必含：派工履歷、紅隊結論、規範違規透明化（如有）

## Degraded Path（撞牆時的降級處理）

| 失敗點 | 降級方式 |
|--------|---------|
| Step 0 L2 搜尋無結果 / 超過 10 分鐘 | 記「無相關社群方案」，繼續 Step 1，不阻斷 |
| Step 3 worker 寫不進 skills/（permission 攔） | 不 retry，opus 直接 Write SKILL.md |
| Step 4 glm-code / mini-agent 兩次失敗 | fallback opus 自寫 script，記入結案報告 |
| Step 5 codex 無法執行 | 主 session 手動審閱紅隊點，逐一標記 severity，補 Round 2 |
| Step 6 真實驗收環境不可用 | 用 no-op 目標跑語法 + 邊界路徑，記「完整驗收待補」 |

所有降級都**必須在結案回報中透明化**，不能靜默帶著降級上線。

## Guard（紅線）

- ❌ 跳過 Step 0 三層研究直接開始寫（「需求很明確」不是理由——Layer 3 diff 才是新建的正當性）
- ❌ 跳過紅隊直接交付（「這個應該沒問題」是腦補，不是驗證）
- ❌ Round 1 紅隊有 HIGH/CRITICAL 但只修一半就交付（HIGH 沒清掉等於沒過關）
- ❌ 用 worker 寫 SKILL.md（CLAUDE.local.md 子代理紅線：skills/ 核心層禁止 worker 寫入）
- ❌ skill description 沒寫「不觸發」「消歧」（觸發詞重疊會讓錯 skill 被呼叫）
- ❌ SKILL.md 缺少三段中任何一段（Happy path / Degraded path / Guard 三段缺一視為未完成品）
- ✅ 撞牆 fallback 用 opus 直寫，但紅隊不能省

## 不適用

- 改現有 skill 的小字 / typo → Edit 直接改
- 把外來 skill 引入 → `skill-vetting`
- 評估現有 skill 該怎麼改 → `skill-optimizer`

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
