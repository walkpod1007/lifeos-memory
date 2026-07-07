# SKILL-task-manager.md
# 龍蝦非同步任務框架（LB-017R）

建立日期：2026-02-23
依賴：LB-007R（Google Drive）、LINE Push API

---

## Section 1：觸發條件

### 任務類型識別

| 用戶說 | 任務類型 | 預估時間 | Handler | 狀態 |
|--------|---------|---------|---------|------|
| 「幫我研究 XXX」「深度研究 XXX」「調查 XXX」 | `deep-research` | 3-5 分鐘 | handler-deep-research.sh | LB-018R |
| 「生成一段 XXX 影片」「幫我做 XXX 的影片」 | `video-gen` | 2-4 分鐘 | handler-video-gen.sh | LB-019R |
| 「做成 Podcast」「轉成播客」「做個廣播」 | `podcast-gen` | 3-5 分鐘 | handler-podcast-gen.sh | LB-020R |
| 傳送語音且 **> 2 分鐘** | `long-transcription` | 1-3 分鐘 | handler-long-transcription.sh | 未來 |
| 要求一次生 **> 3 張圖** | `batch-image` | 1-2 分鐘 | handler-batch-image.sh | 未來 |
| 「demo 任務」「測試非同步」 | `demo` | ~30 秒 | handler-demo.sh | ✅ 已實作 |

### 任務類型標籤（顯示用）

| type | 顯示名稱 |
|------|---------|
| deep-research | 🔍 深度研究 |
| video-gen | 🎬 影片生成 |
| podcast-gen | 🎙️ Podcast 生成 |
| long-transcription | 📝 語音轉錄 |
| batch-image | 🎨 批次生圖 |
| demo | 🧪 測試任務 |

---

## Section 2：任務建立流程

### 步驟 1：生成 taskId

```bash
# 格式：task-{YYYYMMDD}-{3位流水號}
DATE=$(date +%Y%m%d)
# 計算當日已有多少任務（找最大流水號+1）
TASKS_DIR="$HOME/.openclaw/workspace/tasks"
LAST_NUM=$(ls "$TASKS_DIR" | grep "task-${DATE}-" | sed "s/task-${DATE}-\([0-9]*\)\..*/\1/" | sort -n | tail -1)
NEXT_NUM=$(printf "%03d" $(( ${LAST_NUM:-0} + 1 )))
TASK_ID="task-${DATE}-${NEXT_NUM}"
```

### 步驟 2：建立 task JSON

**位置：** `workspace/tasks/{taskId}.json`

```bash
TASK_FILE="$TASKS_DIR/$TASK_ID.json"
python3 - <<PYTHON
import json
from datetime import datetime, timezone

task = {
    "taskId": "$TASK_ID",
    "type": "TASK_TYPE",         # 替換為實際類型
    "status": "pending",
    "progress": 0,
    "statusMessage": "等待執行",
    "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    "estimatedMinutes": 5,       # 替換為對應類型的預估時間
    "userId": "USER_ID",         # 替換為用戶 LINE ID
    "request": {
        "prompt": "用戶的原始請求",
        "options": {}
    },
    "result": {},
    "delivered": False
}
json.dump(task, open("$TASK_FILE", "w"), ensure_ascii=False, indent=2)
PYTHON
```

### 步驟 3：回覆 Flex「任務已接收」卡片

```bash
LAB="$HOME/.openclaw/workspace/projects/line-experience-lab"
LINE_TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.openclaw/openclaw.json')); print(d['channels']['line']['channelAccessToken'])")

# 替換模板變數
FLEX=$(python3 - <<PYTHON
import json
t = open("$LAB/templates/task-accepted.json").read()
t = t.replace("{{TASK_ID}}", "$TASK_ID")
t = t.replace("{{TASK_TITLE}}", "TASK_TITLE_HERE")       # 根據類型設定
t = t.replace("{{TASK_TYPE_LABEL}}", "TASK_TYPE_LABEL")  # 根據類型設定
t = t.replace("{{ESTIMATED_TIME}}", "約 3-5 分鐘")        # 根據類型設定
print(t)
PYTHON
)

curl -s -X POST https://api.line.me/v2/bot/message/push \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LINE_TOKEN" \
    -d "{
        \"to\": \"USER_ID\",
        \"messages\": [{
            \"type\": \"flex\",
            \"altText\": \"✅ 任務已接收：$TASK_ID\",
            \"contents\": $FLEX
        }]
    }"
```

### 步驟 4：背景啟動 task-runner

```bash
LAB="$HOME/.openclaw/workspace/projects/line-experience-lab"
nohup bash "$LAB/scripts/task-runner.sh" "$TASK_ID" \
    >> "$HOME/.openclaw/workspace/tasks/$TASK_ID.log" 2>&1 &
echo "[task] 啟動 runner PID $! 任務：$TASK_ID"
```

---

## Section 3：每次回覆前的任務狀態檢查

**每次回覆用戶前，先掃描 `workspace/tasks/` 目錄。**

### 規則

| 狀態 | 條件 | 行為 |
|------|------|------|
| 無任務 | tasks/ 空或只有 delivered=true | 不顯示任何東西 |
| running | 有 status=running 的任務 | 回覆尾巴附加進度摘要 |
| done + undelivered | status=done 且 delivered=false | 回覆中附上完整結果，標記 delivered=true |
| failed | status=failed | 報告失敗原因，詢問是否重試 |

### 狀態報告格式（插在回覆最後一行）

```
────────────────────
📋 背景任務：
• 🔍 深度研究 (42%) │ 預估剩餘 2 分鐘
✓ 🎙️ Podcast 已完成 │ 點此查看：https://...
⚠️ 🎬 影片生成 失敗 │ 傳「重試任務 task-xxx」
```

### 掃描腳本

```bash
TASKS_DIR="$HOME/.openclaw/workspace/tasks"

check_tasks() {
    python3 - "$TASKS_DIR" <<'PYTHON'
import json, os, sys
from datetime import datetime, timezone

tasks_dir = sys.argv[1]
running = []
done = []
failed = []

for f in os.listdir(tasks_dir):
    if not f.endswith(".json"):
        continue
    try:
        task = json.load(open(f"{tasks_dir}/{f}"))
        status = task.get("status", "")
        if status == "running":
            running.append(task)
        elif status == "done" and not task.get("delivered", True):
            done.append(task)
        elif status == "failed" and not task.get("delivered", True):
            failed.append(task)
    except Exception:
        pass

if not running and not done and not failed:
    sys.exit(0)

TYPE_LABELS = {
    "deep-research": "🔍 深度研究",
    "video-gen": "🎬 影片生成",
    "podcast-gen": "🎙️ Podcast",
    "long-transcription": "📝 語音轉錄",
    "batch-image": "🎨 批次生圖",
    "demo": "🧪 測試任務"
}

lines = ["────────────────────", "📋 背景任務："]

for t in running:
    label = TYPE_LABELS.get(t["type"], t["type"])
    pct = t.get("progress", 0)
    msg = t.get("statusMessage", "執行中")
    lines.append(f"• {label} ({pct}%) │ {msg}")

for t in done:
    label = TYPE_LABELS.get(t["type"], t["type"])
    summary = t.get("result", {}).get("summary", "完成")
    url = t.get("result", {}).get("driveUrl", "")
    if url:
        lines.append(f"✓ {label} 已完成 │ {url}")
    else:
        lines.append(f"✓ {label} 已完成 │ {summary}")

for t in failed:
    label = TYPE_LABELS.get(t["type"], t["type"])
    reason = t.get("statusMessage", "未知錯誤")
    lines.append(f"⚠️ {label} 失敗 │ {reason}")

print("\n".join(lines))
PYTHON
}
```

### 標記 done 任務為已交付

完成任務結果夾帶在回覆後，立即更新 delivered=true：

```bash
python3 - "$TASKS_DIR" <<'PYTHON'
import json, os, sys
from datetime import datetime, timezone
tasks_dir = sys.argv[1]
for f in os.listdir(tasks_dir):
    if not f.endswith(".json"):
        continue
    try:
        path = f"{tasks_dir}/{f}"
        task = json.load(open(path))
        if task.get("status") == "done" and not task.get("delivered", True):
            task["delivered"] = True
            task["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
            json.dump(task, open(path, "w"), ensure_ascii=False, indent=2)
    except Exception:
        pass
PYTHON
```

---

## Section 4：用戶主動查詢

| 用戶說 | 行為 |
|--------|------|
| 「任務進度」「背景任務」「什麼在跑」「任務狀態」 | 列出所有未完成任務完整狀態 |
| 「重試任務 task-xxx」 | 重設 status=pending，重新啟動 runner |
| 「取消任務 task-xxx」 | 設 status=cancelled，不再追蹤 |

### 列出所有任務（查詢回應）

```bash
python3 - "$HOME/.openclaw/workspace/tasks" <<'PYTHON'
import json, os, sys
from datetime import datetime, timezone

tasks_dir = sys.argv[1]
tasks = []
for f in sorted(os.listdir(tasks_dir)):
    if not f.endswith(".json"):
        continue
    try:
        task = json.load(open(f"{tasks_dir}/{f}"))
        tasks.append(task)
    except Exception:
        pass

if not tasks:
    print("目前沒有背景任務")
    sys.exit(0)

STATUS_EMOJI = {
    "pending": "⏳",
    "running": "🔄",
    "done": "✅",
    "failed": "⚠️",
    "cancelled": "✕"
}

lines = [f"📋 背景任務列表（共 {len(tasks)} 個）"]
for t in tasks:
    emoji = STATUS_EMOJI.get(t.get("status", ""), "❓")
    task_id = t.get("taskId", "?")
    task_type = t.get("type", "?")
    pct = t.get("progress", 0)
    msg = t.get("statusMessage", "")
    lines.append(f"{emoji} {task_id} ({task_type}) {pct}% - {msg}")

print("\n".join(lines))
PYTHON
```

---

## Push 額度管控

- 優先以 reply 夾帶任務狀態（免費）
- 只有用戶離線（5 分鐘無訊息）才使用 Push
- 多個任務同時完成 → 合併成一則 Push
- 月額度 200 則，需謹慎使用

**活動追蹤：** 每次處理用戶訊息時，更新 `workspace/tasks/.last-activity`：
```bash
date +%s > "$HOME/.openclaw/workspace/tasks/.last-activity"
```

---

## 任務 JSON 完整結構

```json
{
  "taskId": "task-20260223-001",
  "type": "deep-research",
  "status": "running",
  "progress": 42,
  "statusMessage": "正在讀取第 15/35 篇網頁",
  "createdAt": "2026-02-23T11:30:00+00:00",
  "updatedAt": "2026-02-23T11:32:15+00:00",
  "estimatedMinutes": 5,
  "userId": "<LINE_USER_ID>",
  "request": {
    "prompt": "台灣電動車市場分析",
    "options": {}
  },
  "result": {
    "driveUrl": "https://drive.google.com/...",
    "summary": "報告已存入 Google Drive",
    "thumbnailPath": ""
  },
  "delivered": false
}
```

---

## 驗收測試

### 測試 1：手動建 demo 任務 + 啟動 runner

```bash
TASKS_DIR="$HOME/.openclaw/workspace/tasks"
LAB="$HOME/.openclaw/workspace/projects/line-experience-lab"

# 建任務 JSON
python3 - <<'PYTHON'
import json
from datetime import datetime, timezone
task = {
    "taskId": "task-20260223-001",
    "type": "demo",
    "status": "pending",
    "progress": 0,
    "statusMessage": "等待執行",
    "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    "estimatedMinutes": 1,
    "userId": "<LINE_GROUP_ID>",
    "request": {"prompt": "測試非同步框架", "options": {}},
    "result": {},
    "delivered": False
}
import os
os.makedirs(os.path.expanduser("~/.openclaw/workspace/tasks"), exist_ok=True)
json.dump(task, open(os.path.expanduser("~/.openclaw/workspace/tasks/task-20260223-001.json"), "w"), ensure_ascii=False, indent=2)
print("✅ task-20260223-001.json 建立完成")
PYTHON

# 背景啟動
nohup bash "$LAB/scripts/task-runner.sh" "task-20260223-001" \
    >> "$TASKS_DIR/task-20260223-001.log" 2>&1 &
echo "Runner 啟動 PID $!"

# 監看進度
sleep 5 && cat "$TASKS_DIR/task-20260223-001.json" | python3 -c "import json,sys; t=json.load(sys.stdin); print(f'status={t[\"status\"]} progress={t[\"progress\"]}%')"
```

### 測試 2：查詢進度

傳「任務進度」到 LINE → 龍蝦應列出所有任務。

### 測試 3：進行中夾帶狀態

任務執行中，傳其他訊息 → reply 尾巴應附帶任務進度摘要。

### 測試 4：完成後夾帶結果

任務完成後，傳任何訊息 → reply 帶完整結果 + delivered 設為 true。

---

*最後更新：2026-02-23（LB-017R）*
