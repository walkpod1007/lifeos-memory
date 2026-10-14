#!/usr/bin/env python3
"""
inflight_snapshot.py — 限額韌性第②層：IN-FLIGHT 快照（純機械抽取，可用 LLM 但預設不用）

給定 channel 名，定位其目前活躍的 live transcript(jsonl)，抽出：
  (a) 已派出（Agent/Task tool_use）但主 session 尚未確認完成的背景委託
  (b) 最近使用者訊息中，尚未見到後續 assistant 回覆的委託
輸出成一份 markdown 快照，供撞限重啟後的新 session 或人工一眼看到「上一輪還欠什麼」。

用法：
  python3 inflight_snapshot.py <channel> [--out <path>]

<channel> 例：專案標籤（claw／watchdog 用的 cwd key 最後一段）
不帶 --out 時預設輸出到 $LIFEOS_MEMORY_ROOT/state/inflight-<channel>.md

設計限制（見腳本內註解與 TEST-LOG.md）：
  - 逐行流式讀檔（`for line in f`），不把整檔內容一次讀進記憶體；只保留有界的
    小型結構（背景任務 dispatch/notification 表、最近 N 則使用者訊息、最後一則
    assistant 回覆），對超大 transcript（數百 MB）安全。
  - transcript 選檔用 mtime 最新 + 檔頭含 `"type":"mode"`（排除 gen-handoff /
    realtime-summary 等 helper 一次性 session），邏輯與 watchdog.sh 的
    transcript 判斷同源，但本腳本不做 lsof/PID pin。
  - Schema 依 2026-07-07 對真實 transcript 的觀察歸納，非官方文件保證；未來格式
    變動需要更新本檔的 regex/欄位路徑。
"""
import sys
import os
import re
import json
import stat
import argparse
import tempfile
from collections import deque
from datetime import datetime, timedelta, timezone

USER_TRUNC = 80
ASSISTANT_TRUNC = 150
RESULT_TRUNC = 120
MAX_USER_MSGS = 3

# ── (d) 工作中檔案（2026-08-13 接線）────────────────────────────────
# 「撞限重啟後把做到一半的檔案路徑也放到 handoff」——同日的實例：工兵寫完
# 幾個檔案就隨 session 重啟陪葬，一句回報都沒送出，下一班只能靠猜。
# 這一段純機械抽 transcript 裡的檔案寫入類 tool_use，不經任何 LLM（撞限時 Haiku 同池也死）。
FILE_EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
FILE_PATH_KEYS = ("file_path", "notebook_path", "path")
MAX_TOUCHED_FILES = 12          # 快照裡列出的上限（最近動過的優先）
MAX_SUBAGENT_FILES = 20         # 最多掃幾份工兵 transcript（mtime 新的優先）
TOUCHED_HARD_CAP = 400          # 記憶體上限：超過就砍掉較舊的一半，維持有界
TOUCHED_TRIM_TO = 200

# ── 塊 B（2026-08-22）：(d) 段優先吃事件流 ────────────────────────────────
# 選配：若有 PostToolUse hook 把每次工具呼叫當下 append 成一行
# JSON 進 <事件流目錄>/<channel>/<session_id>.jsonl（目錄用 LIFEOS_EVENT_STREAM_DIR 指定）。塊 B 讓 (d) 段優先讀
# 這份即時檔，讀不到（檔案不存在／全是壞行）才退回下面既有的 transcript 掃描——
# 降級路徑一個字不改（見 load_event_stream / build_event_touch_items 與呼叫端）。
# 預設目錄用 event_stream_dir() 函式算（定義在 LIFEOS_ROOT 之後，避免模組載入順序雷）。
MAX_EVENT_ITEMS = 20            # (d) 段事件流合併清單（file+bash）上限
CMD_TRUNC = 200                 # Bash 指令原文在 (d) 段的顯示上限（2026-08-22）

CHANNEL_RE = re.compile(r'^[A-Za-z0-9_-]+$')

# ── 機密字串遮罩（紅隊 finding #1/#2：task-notification 與使用者訊息原文落地前
#    一律過濾，避免 credential/token 外洩進 markdown 快照） ──────────────────
SECRET_PATTERNS = [
    re.compile(r'sk-' r'ant-[A-Za-z0-9_-]+'),
    re.compile(r'ghp_[A-Za-z0-9]+'),
    re.compile(r'gho_[A-Za-z0-9]+'),
    re.compile(r'github_pat_[A-Za-z0-9_]+'),
    re.compile(r'xox[bap]-[A-Za-z0-9-]+'),
    re.compile(r'AKIA[A-Z0-9]{16}'),
    re.compile(r'Bearer\s+[A-Za-z0-9._-]{20,}'),
    re.compile(r'eyJ[A-Za-z0-9._-]{20,}'),           # JWT (header always base64 of {"...)
    # ↓ 2026-08-22 補的明確前綴規則。必須排在下面那條泛用規則之前，
    #   因為泛用規則改成不吃斜線之後，含斜線的憑證（Google refresh token 是 1// 開頭）
    #   只剩前綴這條接得住。
    re.compile(r'sk-[A-Za-z0-9_-]{16,}'),            # Anthropic sk-ant / MiniMax sk-cp / OpenAI sk-
    re.compile(r'ya29\.[A-Za-z0-9._-]{10,}'),        # Google OAuth access token
    re.compile(r'1//[A-Za-z0-9._-]{10,}'),           # Google OAuth refresh token（含斜線）
    re.compile(r'AIza[A-Za-z0-9_-]{20,}'),           # Google API key
    # 泛用長串：**刻意不吃斜線**（原本吃，見下）。原規則 [A-Za-z0-9+/_-]{40,} 會把長路徑
    # 當成憑證塗掉——實例：`cp ~/proj/drafts/event-stream-layer/event-stream-record.sh …`
    # 裡那段 52 字元不含點號的路徑整段變 [REDACTED]，交接卡的指令原文因此讀不懂
    # （2026-08-22 塊 B 上線後實際跑出來的畫面）。路徑幾乎必然含斜線，憑證則多半不含，
    # 所以用斜線當分界；含斜線的已知憑證格式由上面四條前綴規則負責。
    re.compile(r'[A-Za-z0-9+_-]{40,}={0,2}'),        # generic 40+ char base64/hex blob（不含 /）
]


def redact(text):
    """套用所有 SECRET_PATTERNS，命中一律換成 [REDACTED]。空字串/None 原樣通過。"""
    if not text:
        return text
    for pat in SECRET_PATTERNS:
        text = pat.sub('[REDACTED]', text)
    return text


def _self_test():
    """--self-test：對已知假 token 樣本跑 redact()，驗證命中率。"""
    cases = [
        ("sk-" "ant-api03-test1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ", "sk-ant"),
        ("gh" "p_1234567890abcdefghijklmnopqrstuvwxyz12", "ghp_"),
        ("gh" "o_1234567890abcdefghijklmnopqrstuvwxyz12", "gho_"),
        ("github" "_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "github_pat_"),
        ("xo" "xb-1234567890-1234567890123-abcdefghijklmnopqrstuvwx", "xox"),
        ("AK" "IAABCDEFGHIJKLMNOP", "AKIA"),
        ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789", "Bearer"),
        ("ey" "JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop", "eyJ"),
        ("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6", "generic 40+"),
        ("1//0e4OaBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789", "google refresh 1//"),
        ("ya29.a0AfB_xyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "google access ya29."),
        ("sk-cp-MCrABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "minimax sk-cp"),
        ("AIza" "SyABCDEFGHIJKLMNOPQRSTUVWXYZ01234567", "google AIza"),
    ]
    ok = True
    for raw, label in cases:
        out = redact(raw)
        passed = "[REDACTED]" in out and raw not in out
        ok = ok and passed
        print(f"{'PASS' if passed else 'FAIL'} [{label}] {raw!r} -> {out!r}")
    # 反向案例：長路徑不准被塗黑（2026-08-22 起）。這幾條若被 redact 命中就是regression。
    keep_cases = [
        "cp ~/proj/drafts/event-stream-layer/event-stream-record.sh /home/u/.claude/hooks/event-stream-record.sh",
        "python3 /home/u/lifeos-memory/scripts/lib/inflight_snapshot.py myproj --transcript /tmp/a.jsonl",
        "/home/u/.claude/projects/-home-u-proj-myproj/abc.jsonl",
    ]
    for raw in keep_cases:
        out = redact(raw)
        passed = "[REDACTED]" not in out
        ok = ok and passed
        print(f"{'PASS' if passed else 'FAIL'} [path-keep] {raw[:52]!r} -> {out[:52]!r}")
    plain = "這只是普通句子，沒有機密內容。"
    passed = redact(plain) == plain
    ok = ok and passed
    print(f"{'PASS' if passed else 'FAIL'} [passthrough] {plain!r} -> {redact(plain)!r}")
    print("SELF-TEST " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1

LINE_MSG_RE = re.compile(r'<line_message\b([^>]*)>(.*?)</line_message>', re.DOTALL)
# 唯一被承認會產生 <line_message> 的來源。任何別的工具回傳裡出現同樣的標籤都不算數。
LINE_PENDING_TOOL = os.environ.get('LIFEOS_LINE_PENDING_TOOL', 'mcp__line__get_pending')
TS_ATTR_RE = re.compile(r'\bts="(\d+)"')
TIME_ATTR_RE = re.compile(r'\btime="([^"]*)"')
# 2026-09-03 實爆：(b) 段只留 time，群號被丟掉，接手那班拿「下一則不同群訊息」的
# group_id 去 push，答案落到隔壁群。回覆一律回該訊息自己的群，不得從別則訊息借，
# 所以每則的 group_id／user_id 都要一路帶到輸出。
GROUP_ATTR_RE = re.compile(r'\bgroup_id="([^"]*)"')
UID_ATTR_RE = re.compile(r'\buser_id="([^"]*)"')
OWNER_UID = os.environ.get("LIFEOS_OWNER_LINE_ID", "")  # 使用者本人 LINE user_id；空值＝無人會被標本人（fail-closed）

TASK_NOTIF_RE = re.compile(r'<task-notification>(.*?)</task-notification>', re.DOTALL)
TASK_ID_RE = re.compile(r'<task-id>(.*?)</task-id>', re.DOTALL)
TOOL_USE_ID_RE = re.compile(r'<tool-use-id>(.*?)</tool-use-id>', re.DOTALL)
STATUS_RE = re.compile(r'<status>(.*?)</status>', re.DOTALL)
SUMMARY_RE = re.compile(r'<summary>(.*?)</summary>', re.DOTALL)
RESULT_RE = re.compile(r'<result>(.*?)</result>', re.DOTALL)

BOILERPLATE_SUBSTR = (
    "請呼叫 get_pending 工具讀取並回覆",
)

BG_TOOL_NAMES = ("Agent", "Task")
ASYNC_LAUNCH_MARK = "Async agent launched successfully"

LIFEOS_ROOT = os.environ.get("LIFEOS_MEMORY_ROOT", os.path.expanduser("~/lifeos-memory"))
HOME = os.path.expanduser("~")
CLAUDE_HOME = os.environ.get("CLAUDE_HOME", os.path.join(HOME, ".claude"))


# ── 孤兒 scratchpad 完成標記掃描（2026-07-20 事故補）──
#
# 背景：本腳本原本只掃 transcript 裡的 <task-notification>（Agent/Task tool 派工的
# 官方完成通知），但裸 `nohup` + Monitor 這種背景任務型態不會產生 task-notification，
# 完成事件如果剛好卡在 session 交接窗口就會兩不管（見上述事故重現）。
#
# 這裡只做「掃描 scratchpad 目錄找疑似完成標記檔」這個相對低成本、高訊號的半套：
# 找本 channel 底下所有 session-uuid scratchpad 目錄裡，檔名含「以英數字元邊界包住
# 的 done」（大小寫不拘，即 ORPHAN_DONE_RE：`-done.png`／`_DONE`／結尾 DONE 都算，
# 夾在單字中間的巧合命中如 donella 不算）的檔案，依 mtime 由新到舊列出，供人工核對
# 「這個是不是還沒被回報過」。**已知覆蓋缺口**（codex R2 2026-07-21 指出）：camelCase
# 命名（`isDone`／`taskDone.json`）因為 done 前面緊接英數字元、沒有邊界，不會命中——
# 目前預設完成標記照 `-DONE`／`_DONE` 這種既有慣例命名（實際案例：
# `report-done.png`、`export-DONE`），camelCase 是尚未涵蓋的命名風格，不是這條
# regex 的 bug，而是命名慣例還沒定契約前的已知限制。
#
# 刻意不做的另一半（判斷成本過高，裁定不做，改用人工檢查清單頂替）：即時掃描仍在跑的裸背景
# PID（ps 對照）。理由：①要正確分辨「這個 PID 是本 channel 目前存活 session 的
# 合法背景工作」還是「上一個 session 死掉留下的孤兒」，需要準確的 session 血緣
# 判定（macOS pgrep 對 CJK/locale 排祖先已知有坑，見 macOS pgrep 排除呼叫者祖先的已知坑），做錯了誤報成本不低；②「這個 PID 對應哪個任務」這件事
# transcript 裡的文字描述才有，光看 ps 輸出的 command line 猜不出來，價值有限。
# 完成標記檔案至少有明確的檔名可讀，性價比高得多，先做這半套。
SCRATCH_ROOT = f"/private/tmp/claude-{os.getuid()}"
ORPHAN_LOOKBACK_HOURS = 48
ORPHAN_MAX_SHOWN = 10
# 邊界比對（真實跑過本 channel 資料實測抓到的假陽性：naive `"done" in fn.lower()`
# 會命中 donella-meadows.html —— Donella Meadows 這個人名的前四個字母剛好拼出
# "done"。改成「done 前後都不是英數字元（或落在字串頭尾）」的邊界比對，
# 放行 `-done.png`／`_DONE`／結尾 `DONE`，擋掉夾在單字中間的巧合命中。
ORPHAN_DONE_RE = re.compile(r'(?:^|[^A-Za-z0-9])done(?:[^A-Za-z0-9]|$)', re.IGNORECASE)


def _resolve_scratch_root(channel):
    """scratchpad 專案目錄名是 cwd 路徑把 / 換成 - 的結果，結尾必為 -<channel>。
    可用 LIFEOS_SCRATCH_PROJECT_KEY 直接指定；否則在 SCRATCH_ROOT 下找名稱以 -<channel> 結尾、
    mtime 最新的那個。找不到就回一個不存在的路徑（呼叫端會走「合法的空」分支）。"""
    key = os.environ.get("LIFEOS_SCRATCH_PROJECT_KEY")
    if key:
        return os.path.join(SCRATCH_ROOT, key)
    best, best_m = None, -1.0
    try:
        for n in os.listdir(SCRATCH_ROOT):
            if n.endswith("-" + channel):
                try:
                    m = os.path.getmtime(os.path.join(SCRATCH_ROOT, n))
                except OSError:
                    continue
                if m > best_m:
                    best, best_m = n, m
    except OSError:
        pass
    return os.path.join(SCRATCH_ROOT, best or ("-none-" + channel))


def find_orphan_scratchpad_markers(channel, now_ts=None):
    """回傳 (markers, total_count, scan_error)。
    markers：[(mtime_epoch, path)] 由新到舊，已截斷至 ORPHAN_MAX_SHOWN 筆。
    total_count：截斷前的實際命中總數（用來提示「還有 N 筆較舊項目未列出」，
    codex R2 finding：原本直接切片會靜默吃掉第 11 筆以後的項目，沒有任何提示）。
    scan_error：只在「掃描本身沒能跑完（部分或全部）」時才非 None（例如中途 permission
    錯誤）——這種情況下 markers 可能是空的、也可能已經找到部分結果（兩者不互斥：一個
    session 讀不到不代表其他 session 也讀不到，找到的部分照樣回傳），但**不論哪種，
    都不代表「已確認沒有更多」**，呼叫端要區分「掃描完成、結果是空的」跟「掃描沒跑完，
    结果不完整」這兩種不同的空/部分（codex R2 finding：原本兩者都會落入同一個
    「（無）」分支，判斷分支沒有第三種狀態）。
    scratchpad 根目錄本身不存在**不算掃描出錯**——這代表這個 channel 在本機從沒留過
    任何 scratchpad 活動，是合法的「掃描完成、真的沒有」。
    """
    now_ts = now_ts if now_ts is not None else datetime.now(timezone.utc).timestamp()
    cutoff = now_ts - ORPHAN_LOOKBACK_HOURS * 3600
    root = _resolve_scratch_root(channel)
    # codex R5 HIGH：同一種吞錯模式最外層還有一處——os.path.isdir(root) 一樣把
    # 「root 的祖先路徑不可穿越（權限問題）」跟「root 真的不存在」混成同一個 False。
    # 改用跟 scratchpad 子目錄那段相同的明確 os.stat() 分流。
    try:
        root_mode = os.stat(root).st_mode
    except FileNotFoundError:
        return [], 0, None  # channel 在本機從沒留過任何 scratchpad 活動，合法的空
    except OSError as e:
        return [], 0, f"掃描中途出錯，結果不完整：{e}"
    if not stat.S_ISDIR(root_mode):
        return [], 0, None
    found = []
    # codex R3/R4/R6 HIGH（三輪各抓到同一 bug class的不同層）：os.path.isdir()／
    # os.walk() 都會把「這個路徑因權限問題讀不到」跟「這個路徑真的不是目錄／不存在」
    # 混成同一個 False/略過，呼叫端看不出差別（R6 進一步發現：即使給 os.walk() 傳了
    # onerror，它內部幫每個 entry 判斷 is_dir() 時仍會自行吞掉 OSError，這個錯誤根本
    # 不會傳進 onerror）。這裡全面不用 os.path.isdir()／os.walk()，改成明確 os.stat()
    # 搭配區分 FileNotFoundError（真的沒有這個路徑，正常）跟其他 OSError（讀不到，記
    # 成錯誤），巢狀遍歷改用下面 _walk_scratchpad() 手動 os.scandir() 遞迴，每一層、
    # 每個 entry 的 is_dir() 呼叫都自己包 try/except 記進 walk_errors。
    walk_errors = []

    def _walk_scratchpad(dirpath):
        # codex R6 HIGH：os.walk() 的 scandir 實作幫每個 entry 判斷是否要往下
        # 遞迴時會呼叫 entry.is_dir()，但它內部把這個呼叫的 OSError 直接吞掉當
        # False 處理（等同 os.path.isdir() 對外呈現的行為），這個錯誤不會傳進
        # onerror callback——所以就算傳了 onerror，巢狀目錄裡一個讀不到的
        # entry 還是會被當成「不是目錄」而悄悄跳過，不會被記錄成錯誤。改成手動
        # 用 os.scandir() 遞迴，每一層、每個 entry 的 is_dir() 都自己包
        # try/except 記進 walk_errors，不假手 os.walk() 的內部行為。
        try:
            entries = list(os.scandir(dirpath))
        except OSError as e:
            walk_errors.append(f"{dirpath}: {e}")
            return
        for entry in entries:
            try:
                entry_is_dir = entry.is_dir()
            except OSError as e:
                walk_errors.append(f"{entry.path}: {e}")
                continue
            if entry_is_dir:
                _walk_scratchpad(entry.path)
                continue
            if not ORPHAN_DONE_RE.search(entry.name):
                continue
            try:
                mtime = entry.stat().st_mtime
            except OSError as e:
                walk_errors.append(f"{entry.path}: {e}")
                continue
            if mtime < cutoff:
                continue
            found.append((mtime, entry.path))

    try:
        session_entries = list(os.scandir(root))
    except OSError as e:
        return [], 0, f"掃描中途出錯，結果不完整：{e}"

    for entry in session_entries:
        try:
            is_dir = entry.is_dir()
        except OSError as e:
            walk_errors.append(f"{entry.path}: {e}")
            continue
        if not is_dir:
            continue
        sp = os.path.join(entry.path, "scratchpad")
        try:
            sp_mode = os.stat(sp).st_mode
        except FileNotFoundError:
            continue  # 這個 session 沒建過 scratchpad，正常情況，不是錯誤
        except OSError as e:
            walk_errors.append(f"{sp}: {e}")
            continue
        if not stat.S_ISDIR(sp_mode):
            continue
        _walk_scratchpad(sp)

    found.sort(key=lambda x: x[0], reverse=True)
    scan_error = None
    if walk_errors:
        scan_error = (
            f"掃描過程中有 {len(walk_errors)} 處讀取失敗（例：{walk_errors[0]}），"
            f"結果可能不完整——即使下面列出東西，也不能排除還有東西藏在讀不到的目錄裡"
        )
    return found[:ORPHAN_MAX_SHOWN], len(found), scan_error


# ── channel → 候選 transcript 目錄 ──
def candidate_dirs(channel):
    """$CLAUDE_HOME/projects 下名稱以 -<channel> 結尾的專案目錄；
    另可用 LIFEOS_TRANSCRIPT_DIRS（冒號分隔）追加額外目錄（例如別的 config store）。"""
    import glob
    dirs = sorted(glob.glob(os.path.join(CLAUDE_HOME, "projects", "*-" + channel)))
    for extra in os.environ.get("LIFEOS_TRANSCRIPT_DIRS", "").split(":"):
        if extra.strip():
            dirs.append(extra.strip())
    return dirs


def pick_transcript(channel):
    """在候選目錄中挑 mtime 最新、檔頭含 "type":"mode" 的 jsonl（排除 helper 一次性 session）。
    若都不符合 mode 過濾，退回單純 mtime 最新（並標記 used_fallback_any）。
    回傳 (path, warning) 或 (None, error_msg)。
    """
    candidates = []
    for d in candidate_dirs(channel):
        if not os.path.isdir(d):
            continue
        try:
            for name in os.listdir(d):
                if name.endswith(".jsonl"):
                    p = os.path.join(d, name)
                    try:
                        mtime = os.path.getmtime(p)
                    except OSError:
                        continue
                    candidates.append((mtime, p))
        except OSError:
            continue
    if not candidates:
        return None, f"no jsonl found under any candidate dir for channel={channel}: {candidate_dirs(channel)}"

    candidates.sort(key=lambda t: t[0], reverse=True)

    for _, p in candidates:
        try:
            with open(p, "rb") as f:
                head = f.read(8192)
            if b'"type":"mode"' in head:
                return p, None
        except OSError:
            continue

    # 沒有任何檔案通過 mode 過濾 → 退回最新 mtime（可能是 helper session 或非典型檔頭）
    fallback = candidates[0][1]
    return fallback, f"⚠️ 沒有檔案檔頭含 \"type\":\"mode\"，退回單純 mtime 最新: {os.path.basename(fallback)}（可能非主對話 session）"


def iter_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from iter_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from iter_strings(v)


def truncate(text, limit):
    text = redact(text)
    text = " ".join(text.split())
    if len(text) > limit:
        return text[:limit] + "…"
    return text


def taipei_local_from_iso(iso_ts):
    if not iso_ts:
        return None
    try:
        s = iso_ts.rstrip("Z")
        if "." in s:
            dt = datetime.strptime(s.split(".")[0], "%Y-%m-%dT%H:%M:%S")
        else:
            dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
        dt = dt.replace(tzinfo=timezone.utc) + timedelta(hours=8)
        return dt.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return iso_ts


def extract_line_messages(entry, tool_names=None, stats=None):
    """只收 LINE 收訊 MCP 工具真的吐出來的訊息。

    2026-07-31（紅隊 R2 補）：
    原本對「任何 role=user 的字串」都跑 <line_message> 正則，於是任何回傳文字裡含那串標籤的
    工具（抓回來的網頁、讀進來的檔、子代理的回傳）都能鑄造一則假委託，寫進「(b) 使用者最近委託」
    ——那一段的語意就是「使用者交辦了什麼」，是下一班決定要做什麼的直接依據。
    這條今天真的發作過：正則字面本身被解析成三則「使用者訊息」寫進 handoff。
    判準改綁**來源身分**（tool_use_id 回查 assistant tool_use 的名稱），不綁內容長相——
    內容長相是外部可控的，來源身分不是。查不到來源一律跳過（fail-closed）並計數不靜默。
    """
    if entry.get("type") != "user":
        return []
    content = entry.get("message", {}).get("content")
    if not isinstance(content, list):
        # 使用者直接打字（string content）不是 LINE MCP 的產出，不走這條路徑。
        return []
    tool_names = tool_names if tool_names is not None else {}
    out = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        src = tool_names.get(block.get("tool_use_id"), "")
        if src != LINE_PENDING_TOOL:
            if not src and "<line_message" in "".join(iter_strings(block.get("content"))):
                # 只在「這筆真的長得像訊息、卻查不到來源」時才計數，避免整份 transcript 的
                # 一般工具回傳都被算進去，讓警告變成雜訊。
                if stats is not None:
                    stats["unknown_src"] = stats.get("unknown_src", 0) + 1
            continue
        for s in iter_strings(block.get("content")):
            if "<line_message" not in s:
                continue
            for m in LINE_MSG_RE.finditer(s):
                attrs, text = m.group(1), m.group(2).strip()
                # 正文裡若含 <line_message 字面（使用者真的打了這串字），換成全形，
                # 免得下游再解析一次把單一則拆成第二則假訊息。
                text = text.replace("<line_message", "＜line_message")
                time_m = TIME_ATTR_RE.search(attrs)
                gid_m = GROUP_ATTR_RE.search(attrs)
                uid_m = UID_ATTR_RE.search(attrs)
                out.append({
                    "text": text,
                    "time": time_m.group(1) if time_m else None,
                    "group_id": gid_m.group(1) if gid_m else None,
                    "user_id": uid_m.group(1) if uid_m else None,
                    "entry_ts": entry.get("timestamp"),
                    "source": "line_message",
                })
    return out


def extract_direct_user_text(entry):
    if entry.get("type") != "user":
        return []
    content = entry.get("message", {}).get("content")
    texts = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                texts.append(item["text"])
    out = []
    for t in texts:
        stripped = t.strip()
        if not stripped or stripped.startswith("<"):
            continue
        if any(b in stripped for b in BOILERPLATE_SUBSTR):
            continue
        out.append({
            "text": stripped,
            "time": None,
            "entry_ts": entry.get("timestamp"),
            "source": "direct_user",
        })
    return out


def extract_assistant_text(entry):
    if entry.get("type") != "assistant":
        return None
    content = entry.get("message", {}).get("content")
    if not isinstance(content, list):
        return None
    texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
    texts = [t for t in texts if t.strip()]
    if not texts:
        return None
    return {"text": "\n".join(texts).strip(), "entry_ts": entry.get("timestamp")}


def extract_agent_dispatches(entry):
    """type=assistant 的 message.content 中，name in (Agent, Task) 的 tool_use。"""
    if entry.get("type") != "assistant":
        return []
    content = entry.get("message", {}).get("content")
    if not isinstance(content, list):
        return []
    out = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in BG_TOOL_NAMES:
            inp = c.get("input", {}) or {}
            out.append({
                "tool_use_id": c.get("id"),
                "description": redact(inp.get("description") or "(無 description)"),
                "subagent_type": inp.get("subagent_type") or "?",
                "model": inp.get("model") or "(inherit)",
                "entry_ts": entry.get("timestamp"),
            })
    return out


def extract_tool_results(entry):
    """type=user 的 message.content 中 tool_result 項目：回傳 [(tool_use_id, text)]"""
    if entry.get("type") != "user":
        return []
    content = entry.get("message", {}).get("content")
    if not isinstance(content, list):
        return []
    out = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "tool_result":
            tid = c.get("tool_use_id")
            body = c.get("content")
            if isinstance(body, list):
                text = "\n".join(
                    b.get("text", "") for b in body if isinstance(b, dict) and b.get("type") == "text"
                )
            elif isinstance(body, str):
                text = body
            else:
                text = ""
            out.append((tid, text))
    return out


def extract_task_notifications(entry):
    """任何 entry 型態都可能挾帶 <task-notification> 區塊（觀察到 queue-operation / attachment 兩種載體，
    故採廣義掃描：遞迴收集 entry 內所有字串，逐一 regex 找區塊）。"""
    out = []
    for s in iter_strings(entry):
        if "<task-notification>" not in s:
            continue
        for m in TASK_NOTIF_RE.finditer(s):
            block = m.group(1)
            task_id_m = TASK_ID_RE.search(block)
            tool_use_id_m = TOOL_USE_ID_RE.search(block)
            status_m = STATUS_RE.search(block)
            summary_m = SUMMARY_RE.search(block)
            result_m = RESULT_RE.search(block)
            out.append({
                "task_id": task_id_m.group(1).strip() if task_id_m else None,
                "tool_use_id": tool_use_id_m.group(1).strip() if tool_use_id_m else None,
                "status": status_m.group(1).strip() if status_m else None,
                "summary": summary_m.group(1).strip() if summary_m else None,
                "result": result_m.group(1).strip() if result_m else None,
                "entry_ts": entry.get("timestamp"),
            })
    return out


def format_msg_time(msg):
    if msg.get("time"):
        return msg["time"]
    local = taipei_local_from_iso(msg.get("entry_ts"))
    return f"{local} (TW,推算)" if local else "時間未知"


def format_msg_origin(msg):
    """把一則訊息的發訊者與群號組成 `｜本人✓ U…｜群 C…` 尾巴。

    非 line_message 來源（直接打字／系統輸入）不帶這兩個欄位，回空字串，
    輸出與改動前逐字相同。有 line_message 但抓不到 group_id 時明寫「群別不明」——
    空白會被讀成 DM，而「不知道」與「DM」的處置相反（前者不准回、後者可以回）。
    """
    if msg.get("source") != "line_message":
        return ""
    uid = msg.get("user_id") or ""
    if uid == OWNER_UID:
        who = f"本人✓ {uid}"
    elif uid:
        who = f"他人 {uid}"
    else:
        who = "發訊者不明"
    gid = msg.get("group_id")
    # 判準：沒有 group_id 屬性＝DM（LINE MCP 只在
    # 群組訊息帶這個屬性）。這裡不可以把「沒有」讀成「不明」——那會讓每一則 DM 都被
    # 標成不准回，比原來的漏標更糟。
    where = f"群 {gid}" if gid else "DM"
    return f"｜{who}｜{where}"


def record_touch(touched, block, seq, ts):
    """(d) 把一個檔案寫入類 tool_use 登記進 touched（就地修改）。

    只認結構化的 file_path 參數——Bash 的 heredoc／重導向／cp／mv 一律掃不到，
    這是已知盲區（寫在輸出的「已知限制」段），不是漏抽。
    """
    if not isinstance(block, dict) or block.get("type") != "tool_use":
        return
    if block.get("name") not in FILE_EDIT_TOOLS:
        return
    inp = block.get("input") or {}
    path = None
    if isinstance(inp, dict):
        for key in FILE_PATH_KEYS:
            val = inp.get(key)
            if isinstance(val, str) and val.strip():
                path = val.strip()
                break
    if not path:
        return
    rec = touched.get(path) or {"tools": set(), "count": 0}
    rec["tools"].add(block.get("name", ""))
    rec["count"] += 1
    rec["seq"] = seq
    rec["ts"] = ts
    touched[path] = rec
    # 有界化：超過硬上限就丟掉較舊的一半（seq 小的先丟）。快照本來只列最近 N 筆，
    # 被砍掉的部分不影響輸出。
    if len(touched) > TOUCHED_HARD_CAP:
        for old in sorted(touched, key=lambda k: touched[k]["seq"])[: len(touched) - TOUCHED_TRIM_TO]:
            touched.pop(old, None)


def scan_subagent_touched(transcript_path):
    """(d) 掃工兵（子代理）自己的 transcript，抽它動過哪些檔案。

    2026-08-13 實例：主 session 派的工兵在 09:47-09:48 寫完 tone-gate.ts／server.ts，
    09:49 主 session 被 watchdog 重啟，工兵隨之陪葬、一句回報都沒送出。工兵的 tool_use
    **不在**主 transcript 裡（實測 isSidechain 全為 false），而在
    `<transcript 去掉 .jsonl>/subagents/agent-*.jsonl`。不掃這裡，最該被撿起來的那批
    檔案就永遠不會出現在交接卡上。

    回傳 (items, error)；沒有 subagents 目錄＝這條 session 沒派工兵，回 ([], None)。
    """
    base = transcript_path[:-6] if transcript_path.endswith(".jsonl") else transcript_path
    subdir = os.path.join(base, "subagents")
    try:
        names = [f for f in os.listdir(subdir) if f.endswith(".jsonl")]
    except OSError:
        return [], None
    try:
        names.sort(key=lambda f: os.path.getmtime(os.path.join(subdir, f)), reverse=True)
    except OSError:
        names.sort(reverse=True)
    items = []
    error = None
    for name in names[:MAX_SUBAGENT_FILES]:
        fp = os.path.join(subdir, name)
        label = name[:-6]
        desc = ""
        tool_use_id = ""
        try:
            with open(os.path.join(subdir, label + ".meta.json"), encoding="utf-8", errors="replace") as mf:
                meta = json.load(mf)
            if isinstance(meta, dict):
                desc = redact(str(meta.get("description") or ""))[:80]
                tool_use_id = str(meta.get("toolUseId") or "")
        except (OSError, ValueError):
            pass
        touched = {}
        seq = 0
        try:
            with open(fp, encoding="utf-8", errors="replace") as f:
                for raw in f:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        entry = json.loads(raw)
                    except Exception:
                        continue
                    if not isinstance(entry, dict):
                        continue
                    seq += 1
                    msg = entry.get("message")
                    content = msg.get("content") if isinstance(msg, dict) else None
                    if isinstance(content, list):
                        for block in content:
                            record_touch(touched, block, seq, entry.get("timestamp"))
        except OSError as e:
            error = f"{name}: {e}"
            continue
        for p, rec in sorted(touched.items(), key=lambda kv: kv[1]["seq"], reverse=True)[:MAX_TOUCHED_FILES]:
            items.append({
                "path": p,
                "tools": sorted(t for t in rec["tools"] if t),
                "count": rec["count"],
                "ts": rec.get("ts"),
                "agent": label,
                "desc": desc,
                "tool_use_id": tool_use_id,
            })
    return items, error


# ── 塊 B：事件流讀取與 (d) 段組裝 ────────────────────────────────────────
def event_stream_dir():
    """事件流根目錄。可用 EVENT_STREAM_DIR 環境變數覆寫（測試靠它），
    預設跟 event-stream-record.sh 那支 hook 落地的位置一致。"""
    return os.environ.get("LIFEOS_EVENT_STREAM_DIR") or os.environ.get("EVENT_STREAM_DIR") or os.path.join(LIFEOS_ROOT, "state", "event-stream")


def session_id_from_transcript(transcript_path):
    """transcript 檔名去掉 `.jsonl` 就是 session_id（hook 落檔時用的同一個值）。"""
    base = os.path.basename(transcript_path)
    if base.endswith(".jsonl"):
        base = base[:-len(".jsonl")]
    return base


def load_event_stream(channel, session_id):
    """讀 `<event_stream_dir()>/<channel>/<session_id>.jsonl`（塊 A 的 hook 落地檔）。

    每行一個事件：{ts, event, session_id, channel, tool, detail}（見
    event-stream-record.sh）。壞行（非合法 JSON、或解出來不是 dict）跳過並計數，
    不因為個別壞行整批放棄——這是 R1 紅隊點①「記錄器死掉時下游不能無聲吃空」
    在讀取端的對應：只要還有至少一行能用，就該用；一行都沒有才輪到呼叫端降級。

    回傳 (events, valid_count, invalid_count, path)。檔案不存在／目錄不存在／
    任何讀取例外 → 一律回 ([], 0, 0, path)，不拋例外——呼叫端據 valid_count==0
    判斷要不要退回 transcript 掃描。
    """
    path = os.path.join(event_stream_dir(), channel, f"{session_id}.jsonl")
    events = []
    valid = 0
    invalid = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    entry = json.loads(raw)
                except Exception:
                    invalid += 1
                    continue
                if not isinstance(entry, dict):
                    invalid += 1
                    continue
                events.append(entry)
                valid += 1
    except OSError:
        return [], 0, 0, path
    except Exception:
        return [], 0, 0, path
    return events, valid, invalid, path


def format_event_ts(ts):
    """事件流的 ts 已經是帶 `+08:00` offset 的 ISO8601（見 event-stream-record.sh
    的 `TZ=Asia/Taipei date` 那行），跟 taipei_local_from_iso()（假設輸入是 UTC
    再自己加 8 小時）語意不同、不能共用，另開一支避免用錯支叫出離題兩次的時間。"""
    if not ts:
        return "時間未知"
    try:
        dt = datetime.fromisoformat(ts)
        return dt.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return str(ts)


def build_event_touch_items(events):
    """從 load_event_stream() 讀到的事件組出 (d) 段要顯示的合併清單。

    規則（2026-08-22）：
      - Write/Edit/MultiEdit/NotebookEdit → 列 detail.file，同路徑多次動作併成一筆
        （語意跟舊版 record_touch 一致：算次數、記最後一次時間）。
      - Bash → 每一筆都保留、列 detail.command 原文，不嘗試從指令猜檔名。
      - 其他 tool（含 mcp__*，detail 只有 keys 沒有值）一律不列。
      - 回傳值已排序（最後動的排最前面）並套上 MAX_EVENT_ITEMS 上限。

    回傳 (items, file_total, bash_total)：items 是合併＋截斷後的清單；
    file_total/bash_total 是截斷前的實際筆數，供上層算「共 N 筆」文字。
    """
    file_touched = {}
    bash_items = []
    for idx, ev in enumerate(events):
        if not isinstance(ev, dict):
            continue
        tool = ev.get("tool")
        detail = ev.get("detail")
        if not isinstance(detail, dict):
            continue
        ts = ev.get("ts")
        if tool in FILE_EDIT_TOOLS:
            path = detail.get("file")
            if isinstance(path, str) and path.strip():
                path = path.strip()
                rec = file_touched.get(path) or {"tools": set(), "count": 0}
                rec["tools"].add(tool)
                rec["count"] += 1
                rec["seq"] = idx
                rec["ts"] = ts
                file_touched[path] = rec
        elif tool == "Bash":
            cmd = detail.get("command")
            if isinstance(cmd, str) and cmd.strip():
                bash_items.append({"kind": "bash", "seq": idx, "ts": ts, "command": cmd})
        # 其他 tool：規格明定不列，什麼都不做。

    file_total = len(file_touched)
    file_list = [
        {
            "kind": "file",
            "seq": rec["seq"],
            "ts": rec.get("ts"),
            "path": p,
            "tools": sorted(t for t in rec["tools"] if t),
            "count": rec["count"],
        }
        for p, rec in file_touched.items()
    ]
    bash_total = len(bash_items)

    merged = sorted(file_list + bash_items, key=lambda it: it["seq"], reverse=True)
    return merged[:MAX_EVENT_ITEMS], file_total, bash_total


def stream_extract(path):
    """單趟逐行流式掃描；只保留有界結構，不整檔讀進記憶體。"""
    dispatches = {}       # tool_use_id -> dispatch dict (+kind/notif filled in later)
    notif_by_tool_use = {}  # tool_use_id -> latest notification dict
    user_msg_deque = deque(maxlen=MAX_USER_MSGS)
    last_assistant = None
    last_assistant_seq = -1
    last_entry_ts = None
    entries_scanned = 0
    skipped = 0
    used_line_fmt = False
    seq = 0
    tool_names = {}        # tool_use_id -> 工具名稱（來源綁定用；所有 tool_use 都登記，不限背景任務）
    lm_stats = {"unknown_src": 0}
    touched = {}           # (d) 檔案路徑 -> {"tools": set, "count": n, "seq": 最後一次, "ts": 最後一次}

    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except Exception:
                skipped += 1
                continue
            if not isinstance(entry, dict):
                skipped += 1
                continue
            entries_scanned += 1
            seq += 1

            if entry.get("timestamp"):
                last_entry_ts = entry["timestamp"]

            # 來源登記：assistant 的每個 tool_use 都記 id → name。
            # 必須在下面 (b) 的訊息抽取之前做，否則同一輪的 tool_result 會查不到來源被誤殺。
            if entry.get("type") == "assistant":
                _c = entry.get("message", {}).get("content")
                if isinstance(_c, list):
                    for _b in _c:
                        if isinstance(_b, dict) and _b.get("type") == "tool_use" and _b.get("id"):
                            tool_names[_b["id"]] = _b.get("name", "")
                        # (d) 檔案寫入類 tool_use：登記路徑與最後動它的一輪。
                        record_touch(touched, _b, seq, entry.get("timestamp"))

            # (a) 背景任務 dispatch
            for d in extract_agent_dispatches(entry):
                tid = d["tool_use_id"]
                if tid:
                    d["seq"] = seq
                    dispatches[tid] = d

            # (a) tool_result：background 判斷（是否為 "Async agent launched" 佔位訊息）
            for tid, text in extract_tool_results(entry):
                if tid in dispatches:
                    if ASYNC_LAUNCH_MARK in text:
                        dispatches[tid]["kind"] = "background"
                    else:
                        dispatches[tid]["kind"] = "foreground-resolved"
                        dispatches[tid]["inline_result"] = truncate(text, RESULT_TRUNC)

            # (a) task-notification：任何 entry 型態都掃
            for n in extract_task_notifications(entry):
                tid = n.get("tool_use_id")
                if tid:
                    notif_by_tool_use[tid] = n  # 後出現覆蓋前者（同 task 可能多次通知，取最新）

            # (b) 使用者訊息（line_message 優先，沒有才退回直接文字）
            line_msgs = extract_line_messages(entry, tool_names, lm_stats)
            if line_msgs:
                used_line_fmt = True
                for m in line_msgs:
                    m["seq"] = seq
                    user_msg_deque.append(m)
            else:
                for m in extract_direct_user_text(entry):
                    m["seq"] = seq
                    user_msg_deque.append(m)

            # 最後一則 assistant 文字回覆
            a = extract_assistant_text(entry)
            if a:
                last_assistant = a
                last_assistant_seq = seq

    touched_sorted = sorted(touched.items(), key=lambda kv: kv[1]["seq"], reverse=True)
    return {
        "touched_files": [
            {
                "path": p,
                "tools": sorted(t for t in rec["tools"] if t),
                "count": rec["count"],
                "seq": rec["seq"],
                "ts": rec.get("ts"),
            }
            for p, rec in touched_sorted[:MAX_TOUCHED_FILES]
        ],
        "touched_total": len(touched),
        "dispatches": dispatches,
        "notif_by_tool_use": notif_by_tool_use,
        "user_msgs": list(user_msg_deque),
        "last_assistant": last_assistant,
        "last_assistant_seq": last_assistant_seq,
        "last_entry_ts": last_entry_ts,
        "entries_scanned": entries_scanned,
        "skipped": skipped,
        "used_line_fmt": used_line_fmt,
        "lm_unknown_src": lm_stats["unknown_src"],
    }


COMPLETED_STATUSES = {"completed", "success", "done"}
FAILED_STATUSES = {"failed", "cancelled", "canceled", "killed"}


def build_markdown(channel, transcript_path, pick_warning, data, generated_at, explicit_override=False, orphan_markers=None, orphan_total=0, orphan_scan_error=None, subagent_touched=None, subagent_scan_error=None, event_stream=None):
    lines = []
    lines.append(f"# IN-FLIGHT 快照 — {channel}")
    lines.append("")
    lines.append(f"**產生時刻**：{generated_at}")
    lines.append(
        f"**來源 transcript**：`{transcript_path}`（解析 {data['entries_scanned']} 筆 entry，"
        f"跳過 {data['skipped']} 筆壞行；transcript 最後活動：{data['last_entry_ts'] or '未知'}）"
    )
    if explicit_override:
        lines.append("> 來源判定：整合方以 `--transcript` 明確指定，未經 mtime 猜測。")
    else:
        lines.append("> 來源判定：未提供 `--transcript`，以 mtime 最新 + 檔頭 mode 過濾**猜測**得出，非保證命中目前活躍 session。")
    if pick_warning:
        lines.append(f"> {pick_warning}")
    lines.append("")

    # ── (a) 背景任務 ──
    lines.append("## (a) 已派出的背景任務")
    lines.append("")

    unresolved = []
    failed = []
    completed = []
    foreground = []

    for tid, d in data["dispatches"].items():
        kind = d.get("kind", "unknown")
        notif = data["notif_by_tool_use"].get(tid)
        if kind == "foreground-resolved":
            foreground.append((tid, d, notif))
            continue
        # kind == "background" 或 "unknown"（沒看到 tool_result，理論上不該發生，但保守處理）
        status = notif.get("status") if notif else None
        status_norm = (status or "").strip().lower()
        if status_norm in COMPLETED_STATUSES:
            completed.append((tid, d, notif))
        elif status_norm in FAILED_STATUSES:
            failed.append((tid, d, notif))
        else:
            unresolved.append((tid, d, notif))

    lines.append("### ⚠️ 未確認完成（撞限時最需要搶救的委託）")
    if not unresolved:
        lines.append("- （無）")
    else:
        # Latest 10 items (tail of list)
        shown = unresolved[-10:] if len(unresolved) > 10 else unresolved
        for tid, d, notif in shown:
            t = taipei_local_from_iso(d.get("entry_ts")) or "時間未知"
            status = notif.get("status") if notif else None
            status_disp = status or "無通知（可能仍在跑，或通知尚未送達 / 已遺失）"
            last_bit = ""
            if notif:
                bits = []
                if notif.get("summary"):
                    bits.append(truncate(notif["summary"], RESULT_TRUNC))
                if notif.get("result"):
                    bits.append(truncate(notif["result"], RESULT_TRUNC))
                last_bit = " — 最後已知進度：" + " / ".join(bits) if bits else ""
            lines.append(
                f"- [{t}] **{d['description']}**（subagent={d['subagent_type']}, model={d['model']}, "
                f"tool_use_id={tid[-8:]}）— 狀態：{status_disp}{last_bit}"
            )
        if len(unresolved) > 10:
            lines.append(f"- （另有 {len(unresolved) - 10} 筆較舊項目略）")
    lines.append("")

    lines.append("### ❌ 失敗／取消／終止（不會自己完成，需要人判斷是否重派）")
    if not failed:
        lines.append("- （無）")
    else:
        # Latest 10 items (tail of list)
        shown = failed[-10:] if len(failed) > 10 else failed
        for tid, d, notif in shown:
            t = taipei_local_from_iso(d.get("entry_ts")) or "時間未知"
            status_disp = (notif.get("status") if notif else None) or "unknown"
            last_bit = ""
            if notif:
                bits = []
                if notif.get("summary"):
                    bits.append(truncate(notif["summary"], RESULT_TRUNC))
                if notif.get("result"):
                    bits.append(truncate(notif["result"], RESULT_TRUNC))
                last_bit = " — 最後已知進度：" + " / ".join(bits) if bits else ""
            lines.append(
                f"- [{t}] **{d['description']}**（subagent={d['subagent_type']}, model={d['model']}, "
                f"tool_use_id={tid[-8:]}）— 狀態：{status_disp}{last_bit}"
            )
        if len(failed) > 10:
            lines.append(f"- （另有 {len(failed) - 10} 筆較舊項目略）")
    lines.append("")

    lines.append("### ✅ 已完成（供比對，避免重複派工；主 session 可能還沒消化結果）")
    if not completed:
        lines.append("- （無）")
    else:
        # Latest 5 items (tail of list)
        shown = completed[-5:] if len(completed) > 5 else completed
        for tid, d, notif in shown:
            t = taipei_local_from_iso(d.get("entry_ts")) or "時間未知"
            summary = truncate(notif.get("summary", ""), RESULT_TRUNC) if notif else ""
            lines.append(f"- [{t}] **{d['description']}** — {summary}")
        if len(completed) > 5:
            lines.append(f"- （另有 {len(completed) - 5} 筆較舊項目略）")
    lines.append("")

    if foreground:
        lines.append("### （前景／同步呼叫，已內嵌回結果，非在途）")
        # Latest 5 items (tail of list)
        shown_fg = foreground[-5:] if len(foreground) > 5 else foreground
        for tid, d, _ in shown_fg:
            t = taipei_local_from_iso(d.get("entry_ts")) or "時間未知"
            lines.append(f"- [{t}] {d['description']} — {d.get('inline_result', '')}")
        if len(foreground) > 5:
            lines.append(f"- （另有 {len(foreground) - 5} 筆較舊項目略）")
        lines.append("")

    # ── (c) 孤兒 scratchpad 完成標記（掃全部 session-uuid 目錄，不只當前這個）──
    lines.append(f"## (c) 疑似孤兒背景產物（scratchpad 完成標記，近 {ORPHAN_LOOKBACK_HOURS} 小時；未必已回報，僅供核對）")
    lines.append("")
    if orphan_scan_error:
        # codex R3：即使掃描過程中有錯誤，可能已經找到部分 marker——錯誤警示跟「有找到的
        # 東西照列」不衝突，兩者都要顯示，不能因為有錯誤就把已找到的部分也藏起來。
        lines.append(f"> ⚠️ 掃描沒有完整跑完，結果可能不完整：{orphan_scan_error}")
    if orphan_scan_error and not orphan_markers:
        lines.append("- （無法判定——**不等於「無」**，是「這次沒掃成功」，判斷時要當作未知，不能當空結果用）")
    elif not orphan_markers:
        lines.append("- （無——掃描正常完成，本 channel 近期 scratchpad 裡沒有符合命名邊界的完成標記）")
    else:
        for mtime, fp in orphan_markers:
            # 沿用本檔既有慣例（taipei_local_from_iso）：UTC epoch 直接 +8 小時顯示，
            # 不依賴系統 TZ 設定，避免環境差異造成顯示時間漂移。
            t = (datetime.fromtimestamp(mtime, tz=timezone.utc) + timedelta(hours=8)).strftime("%Y-%m-%d %H:%M")
            lines.append(f"- [{t}] `{fp}`")
        if orphan_total > len(orphan_markers):
            lines.append(f"- （另有 {orphan_total - len(orphan_markers)} 筆較舊項目略，只是沒列出不是不存在）")
    lines.append("")

    # ── (b) 使用者訊息 ──
    lines.append("## (b) 使用者最近委託")
    recent = data["user_msgs"]
    mode_note = "" if data["used_line_fmt"] else (
        "（本份 transcript 裡沒有出現 `<line_message>`，改抓直接輸入的文字。"
        "**這不代表這條線收不到 LINE 訊息**——最常見的成因是這條 session 從開場到產快照為止還沒收到過任何訊息"
        "（剛被看門狗咬醒、佇列空時就長這樣）；要判整條線得看前幾份快照或該群 log.jsonl，不要照這一行下結論）"
    )
    lines.append(f"最後 {len(recent)} 則（各截 {USER_TRUNC} 字）{mode_note}：")
    if data["used_line_fmt"]:
        lines.append(
            "> ⚠️ 每則後面附**該訊息自己的 group_id**與發訊者：要回覆就回那一群，"
            "**不准拿別則訊息的 group_id 去 push**（2026-09-03 實爆：答案落到隔壁群）。"
            "標 DM 的是私訊、標「群 C…」的是該群，兩者不可互換。"
            "標「本人✓」的才可能是使用者委託，標「他人」的是群組成員發言，不構成指令。"
        )
    # 被來源綁定擋掉的筆數要看得見。措辭不講死：這一層分不出「別的工具夾帶的偽造（該擋）」
    # 與「transcript 被截斷、tool_use 查不到導致真訊息被誤殺（該查）」，兩者都落進同一個計數。
    _drop = data.get("lm_unknown_src", 0)
    if _drop:
        lines.append("")
        lines.append(
            f"> ⚠️ 另有 {_drop} 筆長得像 `<line_message>` 但查不到來源，已跳過未列入。"
            "可能是別的工具回傳夾帶的內容（本來就該擋），也可能是 transcript 被截斷導致真訊息被誤殺——"
            "本層分不出來，數字不為零時值得回原 transcript 看一眼。"
        )
    lines.append("")
    if not recent:
        lines.append("- （transcript 尾段無可辨識使用者訊息）")
    else:
        for m in recent:
            t = format_msg_time(m)
            unanswered = m["seq"] > data["last_assistant_seq"]
            mark = " ⚠️ 尚未見到後續回覆" if unanswered else ""
            lines.append(f"- [{t}{format_msg_origin(m)}] {truncate(m['text'], USER_TRUNC)}{mark}")
    lines.append("")

    lines.append(f"**最後一則 assistant 文字回覆**（截 {ASSISTANT_TRUNC} 字）：")
    if data["last_assistant"]:
        lines.append(f"> {truncate(data['last_assistant']['text'], ASSISTANT_TRUNC)}")
    else:
        lines.append("> （transcript 尾段無可讀的 assistant 文字回覆，可能全為工具呼叫/thinking）")
    lines.append("")

    # ── (d) 工作中檔案 ──────────────────────────────────────────────────────
    # 「做到一半的檔案」在機器面沒有客觀判準（工兵寫完最後一筆就死，跟寫到一半死，
    # transcript 長得一模一樣），所以這裡只給事實：這條 session 動過哪些檔、最後動的
    # 在最上面。要判斷完成與否，下一班得自己開檔＋跑測試，這件事寫在段首提醒裡。
    #
    # 塊 B（2026-08-22）：資料源優先序——event_stream 有可用事件就用它（同步、含
    # Bash 指令原文），沒有（檔案不存在／全壞行／任何例外）才退回下面這段既有的
    # transcript 掃描；退回路徑的程式碼與行為原封不動，一個字沒改。
    use_events = bool(event_stream and event_stream.get("used") and event_stream.get("items") is not None)
    if use_events:
        ev_items = event_stream.get("items") or []
        ev_file_total = event_stream.get("file_total", 0)
        ev_bash_total = event_stream.get("bash_total", 0)
        ev_kept_total = ev_file_total + ev_bash_total
        extra = f"（共 {ev_kept_total} 筆事件，列最近 {len(ev_items)} 筆）" if ev_kept_total > len(ev_items) else ""
        lines.append(f"## (d) 本 session 動過的檔案／執行過的指令{extra}")
        lines.append(
            "> 本段資料源＝即時事件流（`<事件流目錄>/<channel>/<session_id>.jsonl`，"
            "hook 在每次工具呼叫當下落地），不是掃 transcript。最後動的排最前面——"
            "**做到一半的東西通常就在前幾行**。Bash 動作記錄的是**指令原文**，不是從指令猜出來的檔名；"
            "接手時逐筆核對（有測試就跑一次），核對結果要回報，不要只在心裡確認。"
        )
        lines.append("")
        home = os.path.expanduser("~").rstrip(os.sep)
        if not ev_items:
            lines.append("- （事件流檔案存在，但沒有可用的 Write/Edit/MultiEdit/NotebookEdit/Bash 事件）")
        else:
            for it in ev_items:
                when = format_event_ts(it.get("ts"))
                if it["kind"] == "file":
                    disp = it["path"]
                    if home and disp.startswith(home + os.sep):
                        disp = "~" + disp[len(home):]
                    tools = "/".join(it["tools"]) or "?"
                    try:
                        st = os.stat(it["path"])
                        mtime = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
                        exists = f"檔案存在，mtime {mtime}"
                    except OSError:
                        exists = "⚠️ 檔案現在不存在（被刪、被搬走，或當初就寫失敗）"
                    lines.append(f"- `{disp}` — 最後動於 {when}（{tools} ×{it['count']}）；{exists}")
                else:  # bash
                    cmd = truncate(it.get("command", ""), CMD_TRUNC)
                    lines.append(f"- Bash：`{cmd}` — 執行於 {when}")
        lines.append("")
    else:
        touched_files = data.get("touched_files") or []
        touched_total = data.get("touched_total", 0)
        home = os.path.expanduser("~").rstrip(os.sep)
        extra = f"（共 {touched_total} 個，列最近 {len(touched_files)} 個）" if touched_total > len(touched_files) else ""
        lines.append(f"## (d) 本 session 動過的檔案{extra}")
        lines.append(
            "> 最後動的排最前面——**做到一半的東西通常就在前幾行**。這一段只陳述「動過」，"
            "不判定「做完了沒」；接手時逐筆開檔核對（有測試就跑一次），核對結果要回報，不要只在心裡確認。"
        )
        lines.append("")
        def _fmt_touch(tf):
            disp = tf["path"]
            if home and disp.startswith(home + os.sep):
                disp = "~" + disp[len(home):]
            local = taipei_local_from_iso(tf.get("ts"))
            when = local or "時間未知"
            tools = "/".join(tf["tools"]) or "?"
            try:
                st = os.stat(tf["path"])
                mtime = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
                exists = f"檔案存在，mtime {mtime}"
            except OSError:
                exists = "⚠️ 檔案現在不存在（被刪、被搬走，或當初就寫失敗）"
            return f"- `{disp}` — 最後動於 {when}（{tools} ×{tf['count']}）；{exists}"

        # 工兵那一組先列：它是最會靜默消失的一組（主 session 死，工兵陪葬且不回報）
        sub_items = subagent_touched or []
        if subagent_scan_error:
            lines.append(f"> ⚠️ 工兵 transcript 掃描中途出錯（{subagent_scan_error}）——下方工兵清單可能不完整。")
            lines.append("")
        if sub_items:
            by_agent = {}
            for it in sub_items:
                by_agent.setdefault((it["agent"], it.get("desc", ""), it.get("tool_use_id", "")), []).append(it)
            for (agent, desc, tuid), group in by_agent.items():
                tail = f"｜tool_use_id={tuid[-8:]}" if tuid else ""
                lines.append(f"**工兵 {agent}**{('｜' + desc) if desc else ''}{tail}")
                for it in group:
                    lines.append(_fmt_touch(it))
                lines.append("")
        if not touched_files:
            lines.append("- （主 session 沒有檔案寫入類 tool_use；也可能全走 Bash 寫檔，那一類掃不到）")
        else:
            if sub_items:
                lines.append("**主 session**")
            for tf in touched_files:
                lines.append(_fmt_touch(tf))
        lines.append("")

    lines.append("## 已知限制")
    lines.append("- transcript 挑選為 mtime 最新 + 檔頭 mode 過濾，未做 lsof/PID pin（見腳本頂部註解）。")
    lines.append("- `<task-notification>` schema 依單一真實樣本歸納；未涵蓋所有可能的 status 值語意。")
    lines.append("- 「未見到後續回覆」是以 entry 順序（seq）判斷，不代表使用者主觀認定已否回覆。")
    lines.append(
        f"- (c) 段只掃檔名被英數邊界包住 done 的檔案（`-DONE`／`_DONE`／結尾 DONE，camelCase 如 "
        f"`isDone` 掃不到，見腳本內註解），不掃仍在跑的裸背景 PID（判斷成本過高，"
        f"見腳本內註解說明為何不做）；只列「存在」，不判定「是否已被前一個 session 讀過／回報過」——"
        f"命中不代表一定漏接，要點開檔案內容與對應紀錄交叉核對才能下結論。清單本身也可能因掃描中途"
        f"出錯而不完整（見上方是否有 ⚠️ 警示），出錯時不能把空結果當「沒有」看待。"
    )
    if use_events:
        lines.append(
            "- (d) 段本輪資料源是**即時事件流**（`<事件流目錄>/<channel>/<session_id>.jsonl`），"
            "由 PostToolUse hook 在每次工具呼叫當下落地，不是事後掃 transcript。"
            "Bash **有**記錄——記的是指令原文（hook 端截前 400 字元、本段再截到 "
            f"{CMD_TRUNC} 字元），不是從指令猜檔名，所以 heredoc／重導向／`cp`／`mv` 都看得到，"
            "跟舊版 transcript 掃描的盲區不同。仍然成立的但書：子代理（工兵）若沒有自己的事件檔，"
            "它動過的檔案不會出現在本段（跟舊版不同——舊版另外掃工兵 transcript，事件流版本目前不掃）；"
            "hook 上線之前發生的動作沒有事件可讀，只能退回 transcript 掃描（見上方資料源判定）。"
        )
    else:
        lines.append(
            "- (d) 段只認 Write／Edit／MultiEdit／NotebookEdit 的結構化 file_path 參數；"
            "Bash 的 heredoc、重導向、`cp`／`mv` 一律掃不到——列出來的是下限不是全部。"
            "反過來，列出來也不代表沒做完。子代理（工兵）的寫檔**有**掃（讀 "
            "`<transcript 去 .jsonl>/subagents/agent-*.jsonl`），但同樣只認上述四種 tool；"
            "沒有 subagents 目錄只代表這條 session 沒派工兵，不代表工兵沒動過檔。"
        )
    lines.append("")

    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("channel", nargs="?", default="line")
    ap.add_argument("--out", default=None)
    ap.add_argument("--transcript", default=None, help="override transcript path (skip mtime guessing)")
    ap.add_argument("--self-test", action="store_true", help="run redactor self-test and exit")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    channel = args.channel

    if not CHANNEL_RE.match(channel):
        print(f"ERROR: invalid channel name {channel!r}（僅允許 [A-Za-z0-9_-]）", file=sys.stderr)
        return 2

    if args.transcript:
        transcript_path = args.transcript
        pick_warning = None
        explicit_override = True
        if not os.path.isfile(transcript_path):
            print(f"ERROR: --transcript path not found: {transcript_path}", file=sys.stderr)
            return 2
    else:
        transcript_path, pick_warning = pick_transcript(channel)
        explicit_override = False
        if transcript_path is None:
            print(f"ERROR: {pick_warning}", file=sys.stderr)
            return 2

    try:
        data = stream_extract(transcript_path)
    except OSError as e:
        print(f"ERROR: failed to read transcript {transcript_path}: {e}", file=sys.stderr)
        return 3

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S %Z").strip()
    orphan_markers, orphan_total, orphan_scan_error = find_orphan_scratchpad_markers(channel)
    subagent_touched, subagent_scan_error = scan_subagent_touched(transcript_path)

    # 塊 B：(d) 段優先吃事件流；任何例外都接住並退回舊掃描（防呆，不能讓整份
    # 快照產不出來）。valid_count==0（檔案不存在／全壞行）也視同「讀不到」降級。
    event_stream = None
    try:
        session_id = session_id_from_transcript(transcript_path)
        ev_events, ev_valid, ev_invalid, ev_path = load_event_stream(channel, session_id)
        if ev_valid > 0:
            ev_items, ev_file_total, ev_bash_total = build_event_touch_items(ev_events)
            event_stream = {
                "used": True,
                "items": ev_items,
                "file_total": ev_file_total,
                "bash_total": ev_bash_total,
                "valid": ev_valid,
                "invalid": ev_invalid,
                "path": ev_path,
            }
    except Exception:
        event_stream = None  # 讀事件流出任何差錯，一律退回 transcript 掃描

    md = build_markdown(
        channel, transcript_path, pick_warning, data, generated_at,
        explicit_override=explicit_override,
        orphan_markers=orphan_markers, orphan_total=orphan_total, orphan_scan_error=orphan_scan_error,
        subagent_touched=subagent_touched, subagent_scan_error=subagent_scan_error,
        event_stream=event_stream,
    )

    out_path = args.out or os.path.join(LIFEOS_ROOT, "drafts", "limit-resilience", "state", f"inflight-{channel}.md")
    out_dir = os.path.dirname(out_path)
    try:
        os.makedirs(out_dir, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".inflight-tmp-", dir=out_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(md)
            os.replace(tmp_path, out_path)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError as e:
        print(f"ERROR: failed to write output {out_path}: {e}", file=sys.stderr)
        return 4

    print(f"OK: snapshot written to {out_path} (source: {transcript_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
