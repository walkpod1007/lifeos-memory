#!/usr/bin/env python3
"""判定一則 LINE 訊息在過去的 session 裡「有沒有被真的回覆過」。

為什麼需要這支：LINE queue 是 at-least-once，session 換班時未 ack 的訊息會被重投並帶
`redelivered="true"`。新 session 要判斷「這則回過了沒」，過去是讀 handoff——但 handoff 是
session-end 當下的快照，回覆可能發生在快照之後，於是已經回過的事會被再回一次
（實案：同一則訊息在換班後被再回一次）。

權威來源是前一條 transcript 的 tool_result：該訊息「送達之後」有沒有一次
`is_error=false` 的 push／reply。被 hook 擋下的那幾次不算送出去。

判定三態：
  ANSWERED    找得到送達紀錄，且其後有成功送出 → 印出送出的節錄讓呼叫端自己核對是不是在答這則
  UNANSWERED  找得到送達紀錄，但其後沒有任何成功送出
  NOT_FOUND   整個 transcript 目錄裡找不到這則的送達紀錄（含只被別處提到、沒真正送達過模型）

退出碼：0=ANSWERED 1=UNANSWERED 3=NOT_FOUND 2=用法或環境錯誤。

防線方向（刻意的）：ANSWERED 誤判的代價是使用者永遠等不到回覆，比 UNANSWERED 誤判
（多收一則）嚴重得多。所以凡是拿不準的一律往 UNANSWERED 倒：
- 送出必須嚴格晚於送達紀錄（同一行不算）
- tool_result 必須明確不是錯誤；讀不到 tool_result 的送出一律不採計
- 訊息只在 handoff 引述裡被提到、沒有真的從 get_pending 進來過 → NOT_FOUND 不是 UNANSWERED
"""
import argparse
import json
import os
import re
import subprocess
import sys

SEND_TOOLS = tuple(os.environ.get("LIFEOS_LINE_SEND_TOOLS", "mcp__line__push,mcp__line__reply").split(","))
# 送達紀錄只認這支工具的回傳；別的工具吐出一模一樣的字串也不算（見下方 F1 註）
SOURCE_TOOL = "get_pending"
# 「成功送出」用**正面比對**：回傳必須是 sent。
# 不用「沒有失敗字樣就算成功」那種列舉式反面判斷——新的擋門字樣會讓封閉宣稱靜默變假
# （memory: classification-closure-fallback-not-enumeration）。
# 代價是 MCP 哪天改了回傳字串，這支會全面倒向 UNANSWERED——那正是安全的失敗方向。
SUCCESS_RE = re.compile(r"^\s*sent\s*$", re.I)
# 從 get_pending 的回傳裡把每一則 <line_message …> 的屬性挖出來，用來取「這一則」的 reply_token。
LINE_MESSAGE_TAG_RE = re.compile(r"<line_message\b([^>]*)>")
ATTR_RE = re.compile(r'(\w+)="([^"]*)"')


def list_transcripts(root, days):
    """列出要掃的 jsonl。回傳 (要掃的, 全部數量)。

    整棵 projects 樹是 GB 級、上萬個檔（實測可達 GB 級／上萬個檔），全掃要好幾分鐘。
    重投只可能發生在很近的過去，所以預設只掃近 N 天改動過的檔——但這是一個**明示的取樣邊界**，
    NOT_FOUND 時一定要把邊界印出來，不然「沒找到」會被讀成「不存在」（memory:
    sampling-cannot-detect-omissions／no-silent-caps）。
    """
    import time
    cutoff = None if days is None else time.time() - days * 86400
    picked, total = [], 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            total += 1
            path = os.path.join(dirpath, name)
            if cutoff is None:
                picked.append(path)
                continue
            try:
                if os.path.getmtime(path) >= cutoff:
                    picked.append(path)
            except OSError:
                continue
    return picked, total


def find_candidate_files(paths, message_id):
    """在指定檔案清單裡粗篩含該 id 的檔案。

    grep 一律帶 -a：遇到無效位元組時 grep 會拒答，長得跟「沒找到」一模一樣
    （memory: grep-binary-refusal-looks-like-no-match）。
    """
    if not paths:
        return []
    hits = []
    CHUNK = 400  # 避免 argv 過長
    for i in range(0, len(paths), CHUNK):
        batch = paths[i:i + CHUNK]
        try:
            p = subprocess.run(["grep", "-la", message_id] + batch,
                               capture_output=True, text=True)
            if p.returncode not in (0, 1):
                raise RuntimeError(p.stderr.strip() or "grep rc=%d" % p.returncode)
            hits.extend(f for f in p.stdout.splitlines() if f)
        except (FileNotFoundError, RuntimeError):
            needle = message_id.encode()
            for path in batch:
                try:
                    with open(path, "rb") as fh:
                        if needle in fh.read():
                            hits.append(path)
                except OSError:
                    continue
    return hits


def iter_entries(path):
    """逐行解析；壞行只跳自己不整份放棄（memory: 壞行只掉自己）。"""
    with open(path, "rb") as fh:
        for i, raw in enumerate(fh, 1):
            try:
                yield i, json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue


def content_blocks(entry):
    msg = entry.get("message")
    if not isinstance(msg, dict):
        return []
    content = msg.get("content")
    return content if isinstance(content, list) else []


def result_text(block):
    body = block.get("content")
    if isinstance(body, list):
        return " ".join(x.get("text", "") for x in body if isinstance(x, dict))
    return "" if body is None else str(body)


def delivered_reply_token(text, message_id):
    """從一段 get_pending 回傳裡，取出**指定那一則**的 reply_token。

    回傳空字串代表這則沒有可用的 token（reply_expired 的訊息就是空字串），
    回傳 None 代表這段文字裡根本找不到這則——兩者要分開，因為前者只是綁不了，
    後者是不該拿來當送達的證據。
    """
    for attrs in LINE_MESSAGE_TAG_RE.findall(text):
        kv = dict(ATTR_RE.findall(attrs))
        if kv.get("message_id") == message_id:
            return kv.get("reply_token", "")
    return None


def is_successful_send(block):
    """這個 tool_result 算不算「真的送出去了」。

    抽成函式是為了讓「成功送出」只有一份定義——`scan_file` 與 `last_successful_send`
    共用它，改判準時不會只改到其中一邊（memory: test-copies-implementation-measures-the-copy
    的同一個道理，兩份實作就是兩個真相）。
    """
    return (block.get("is_error") is not True
            and bool(SUCCESS_RE.match(result_text(block).strip())))


def last_successful_send(path):
    """回傳這條 transcript **最後一次**成功送出的紀錄，供 handoff 產生器落一行紀錄用。

    回傳 dict（沒有任何成功送出就回 None）：
      line／tool／time／text／answers — answers 是這次送出綁得回的 message_id，
      綁不回就是 None（`push` 一定綁不回，`reply` 靠 reply_token 綁）。

    ⚠️ 這一行是**線索不是判準**：handoff 仍然是 session-end 當下的快照，晚於它的送出
    一樣記不到——盲點跟原本一模一樣。判「回過了沒」照舊要跑 scan_file 去翻 transcript。
    """
    token_to_mid = {}     # reply_token -> message_id（從 get_pending 的回傳建起來）
    source_call_ids = set()
    pending_sends = {}    # tool_use_id -> (行號, 工具名, 文字, reply_token, 時刻)
    last = None

    for lineno, entry in iter_entries(path):
        ts = entry.get("timestamp") or ""
        for block in content_blocks(entry):
            if not isinstance(block, dict):
                continue
            btype = block.get("type")

            if btype == "tool_use":
                name = block.get("name") or ""
                if SOURCE_TOOL in name:
                    source_call_ids.add(block.get("id"))
                if name in SEND_TOOLS:
                    inp = block.get("input") or {}
                    pending_sends[block.get("id")] = (
                        lineno, name, inp.get("text", ""), inp.get("reply_token", ""), ts)

            if btype == "tool_result":
                tuid = block.get("tool_use_id")
                if tuid in source_call_ids:
                    for attrs in LINE_MESSAGE_TAG_RE.findall(result_text(block)):
                        kv = dict(ATTR_RE.findall(attrs))
                        tok, mid = kv.get("reply_token"), kv.get("message_id")
                        if tok and mid:
                            token_to_mid[tok] = mid
                if tuid in pending_sends:
                    lineno_use, tool, text, rtok, use_ts = pending_sends.pop(tuid)
                    if is_successful_send(block):
                        last = {"line": lineno_use, "tool": tool, "time": use_ts,
                                "text": text, "answers": token_to_mid.get(rtok)}
    return last


def scan_file(path, message_id):
    """回傳 (送達行號 or None, [成功送出的紀錄])。

    **送達的認定（F1 修法）**：該 id 要以 `message_id="…"` 的形狀出現，**而且**那個 tool_result
    必須對得上一個 get_pending 的 tool_use。只比對字串是不夠的——`grep -a` 一條 transcript、
    `cat` 一份內嵌 line_message 的 handoff、`Read` 任何含該形狀的檔案，吐出來的東西都長得
    一模一樣，會被當成「這則真的送達過」。誤判送達會進一步變成誤判 ANSWERED，
    而 ANSWERED 誤判的代價是使用者永遠等不到回覆——這是最不能錯的方向。
    （2026-07-31 紅隊 F1；當下本 session 的 transcript 裡 6 次命中確實全來自 get_pending，
    亦即這條路徑當時尚未真的發生，但成立條件隨手可得。）

    **成功送出的認定**：tool_result 的 is_error 不得為真，**且**回傳要正面比對到 sent。

    **這一次送出是不是在答這一則（F2 修法）**：`reply` 帶著 `reply_token`，而送達紀錄裡
    每則 line_message 也帶著自己的 reply_token——這是資料裡唯一一條能把「送出」精確綁回
    「哪一則」的線。所以 reply 的 token 對得上＝強證據；**對不上就代表那則 reply 答的是
    別則訊息，一律不採計**（原本的寫法只看時序，同輪先答 B 再被查 A 就會誤判 ANSWERED）。
    `push` 沒有這條線可綁，只能標成弱證據——這種時候呼叫端一定要看印出來的節錄自己核。
    """
    delivery_line = None
    delivery_rt = None     # 這一則自己的 reply_token（空字串＝有這則但沒 token）
    sends = []            # (行號, 工具名, 文字, 回傳, 證據強度)
    pending_sends = {}    # tool_use_id -> (行號, 工具名, 文字, reply_token)
    source_call_ids = set()   # get_pending 的 tool_use id

    delivery_needle = 'message_id="%s"' % message_id

    for lineno, entry in iter_entries(path):
        for block in content_blocks(entry):
            if not isinstance(block, dict):
                continue
            btype = block.get("type")

            if btype == "tool_use":
                name = block.get("name") or ""
                if SOURCE_TOOL in name:
                    source_call_ids.add(block.get("id"))
                if name in SEND_TOOLS:
                    inp = block.get("input") or {}
                    pending_sends[block.get("id")] = (
                        lineno, name, inp.get("text", ""), inp.get("reply_token", ""))

            if btype == "tool_result":
                tuid = block.get("tool_use_id")

                if delivery_line is None and tuid in source_call_ids:
                    body = result_text(block)
                    if delivery_needle in body:
                        delivery_line = lineno
                        delivery_rt = delivered_reply_token(body, message_id)

                if tuid in pending_sends:
                    lineno_use, tool, text, rtok = pending_sends.pop(tuid)
                    if is_successful_send(block):
                        sends.append((lineno_use, tool, text,
                                      result_text(block).strip()[:60], rtok))

    # 只採計嚴格晚於送達的送出；沒有送達紀錄就一律不採計
    if delivery_line is None:
        return None, []

    kept = []
    for lineno_use, tool, text, res, rtok in sends:
        if lineno_use <= delivery_line:
            continue
        evidence = "weak"
        if rtok and delivery_rt:
            if rtok != delivery_rt:
                continue      # 這則 reply 答的是別則訊息，不能拿來當這則回過的證據
            evidence = "strong"
        kept.append((lineno_use, tool, text, res, evidence))
    return delivery_line, kept


def to_taipei(iso):
    """transcript 的 timestamp 是 UTC；handoff 是給人讀的 一律換成台北時間。

    換不動就原樣印出來並標明——寧可讓人看到一個怪字串，也不要靜靜印一個錯的時刻
    （時刻錯了會直接害人把「幾點回的」算錯，正是這張票在收的那種誤導）。
    """
    import datetime
    if not iso:
        return "時刻不明"
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return "%s（原樣，解析不出時刻）" % iso
    if dt.tzinfo is None:
        return "%s（原樣，沒有時區資訊）" % iso
    tpe = dt.astimezone(datetime.timezone(datetime.timedelta(hours=8)))
    return tpe.strftime("%Y-%m-%d %H:%M")


def emit_last_send(path, as_json):
    """`--last-send` 模式：印出一行給 handoff 用的紀錄。

    讀不到檔一律 fail-loud（rc=2），不印一行看起來像「這條 session 什麼都沒送」的空話——
    「查不到」跟「真的沒有」長得一樣正是這整張票要收掉的形狀。

    刻意**不**先加一道 `os.path.isfile` 前置檢查：開不了檔本來就會走下面的 OSError，
    多那一道只是把同一個結局寫兩遍，突變表把它拿掉時沒有任何格子會紅——
    換不到防護的防線就是純冗餘（memory: guard-must-earn-its-false-kills）。
    """
    try:
        rec = last_successful_send(path)
    except OSError as e:
        print("ERROR 讀不到 transcript：%s" % e, file=sys.stderr)
        return 2

    if as_json:
        print(json.dumps({"last_send": rec}, ensure_ascii=False))
        return 0 if rec else 1

    if rec is None:
        print("最後一次成功送出：（這條 session 沒有任何成功送出的紀錄）")
        return 1
    when = to_taipei(rec["time"])
    bind = ("答的是 message_id %s" % rec["answers"]) if rec["answers"] else "綁不回特定訊息"
    first = rec["text"].strip().splitlines()[0] if rec["text"].strip() else ""
    print("最後一次成功送出：%s｜%s（第 %d 行｜%s）：%s"
          % (when, rec["tool"].split("__")[-1], rec["line"], bind, first[:40]))
    return 0


def _realpath(p):
    """realpath，失敗就原樣——店面目錄不存在／壞 symlink 不該炸死整支掃描。"""
    try:
        return os.path.realpath(p)
    except OSError:
        return p


def enumerate_store_targets(home_config_dir, stores_root):
    """列出要掃的店面 projects 子目錄。

    回傳 [(label, projects_root, realpath_key), …]：
      - home_config_dir（--config-dir 本身）整棵掃
      - <stores_root>/*/claude-config/projects（其他店面只掃與 home 同名的 project 子目錄）
      - $HOME/.claude/projects（若存在；同樣只掃同名 project）
      - 同一 realpath 只算一次（symlink 指到同一處要去重）

    讀不到的店面目錄跳過並在 stderr 記一行（紅隊點：不得默默少掃不說、不得整支 rc=2）。
    """
    home_projects = os.path.join(home_config_dir, "projects")
    out = []

    # 1. 本店（--config-dir）—— 整棵掃
    if os.path.isdir(home_projects):
        out.append(("home", home_projects, _realpath(home_projects)))
    else:
        # 本店 projects 不在＝環境錯，沿用原本 rc=2 的語意由 caller 處理
        raise FileNotFoundError("home projects 目錄不存在：%s" % home_projects)

    seen_realpaths = {out[0][2]}

    # 2. 其他店面：<stores-root>/*/claude-config
    other_configs = []
    if stores_root and os.path.isdir(stores_root):
        for name in sorted(os.listdir(stores_root)):
            cfg = os.path.join(stores_root, name, "claude-config")
            if cfg == home_config_dir:
                continue
            proj = os.path.join(cfg, "projects")
            if not os.path.isdir(proj):
                continue
            rp = _realpath(proj)
            if rp in seen_realpaths:
                continue
            other_configs.append((name, cfg, proj, rp))

    # 3. $HOME/.claude（若它有 projects 子目錄）
    home_store_proj = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    if os.path.isdir(home_store_proj):
        rp = _realpath(home_store_proj)
        if rp != _realpath(home_projects) and rp not in seen_realpaths:
            other_configs.append(("home-store", os.path.dirname(home_store_proj),
                                  home_store_proj, rp))

    # 其他店面：只掃與 home projects 底下**同名**的 project 子目錄（範圍收斂）
    home_proj_names = set(os.listdir(home_projects)) if os.path.isdir(home_projects) else set()

    for name, cfg, proj, rp in other_configs:
        seen_realpaths.add(rp)
        if not os.path.isdir(proj):
            continue
        try:
            sub_names = set(os.listdir(proj))
        except OSError as e:
            print("WARN 店面 %s 跳過（讀不到 %s）：%s" % (name, proj, e), file=sys.stderr)
            continue
        overlap = sorted(home_proj_names & sub_names)
        if not overlap:
            # 沒有同名 project 子目錄＝這個店面本輪沒貢獻，但要在報告中露臉（NOT_FOUND 文案）
            # 把整個 projects 路徑留下但不展開掃描
            out.append(("%s(none-overlap)" % name, None, proj))
            continue
        for sub in overlap:
            sub_path = os.path.join(proj, sub)
            if not os.path.isdir(sub_path):
                continue
            out.append(("%s/%s" % (name, sub), sub_path,
                        _realpath(sub_path)))

    return out


def main():
    ap = argparse.ArgumentParser(description="查一則 LINE 訊息在過去 session 裡回過了沒")
    ap.add_argument("message_id", nargs="?",
                    help="要查的 messageId；用 --last-send 時不需要")
    ap.add_argument("--last-send", metavar="TRANSCRIPT",
                    help="改成印出這條 transcript 最後一次成功送出（給 handoff 產生器用）")
    ap.add_argument("--config-dir", default=os.environ.get("CLAUDE_CONFIG_DIR"),
                    help="channel 的 claude-config 目錄；預設吃 $CLAUDE_CONFIG_DIR")
    ap.add_argument("--json", action="store_true", help="輸出機讀 JSON")
    ap.add_argument("--days", type=int, default=3,
                    help="只掃近 N 天改動過的 transcript（預設 3；重投只發生在很近的過去）")
    ap.add_argument("--all", action="store_true",
                    help="不設時間窗掃整棵樹（很慢：GB 級別）")
    ap.add_argument("--stores-root",
                    default=os.environ.get("LIFEOS_STORES_ROOT"),
                    help="其他 config store 的根目錄（預設吃 $LIFEOS_STORES_ROOT；沒設就只掃本店）；"
                         "會掃底下每個 */claude-config/projects 的同名 project 子目錄")
    args = ap.parse_args()

    if args.last_send:
        return emit_last_send(args.last_send, args.json)

    if not args.message_id:
        print("ERROR 要給 messageId，或改用 --last-send <transcript>", file=sys.stderr)
        return 2
    if not args.message_id.isdigit():
        print("ERROR messageId 必須是純數字，拿到：%r" % args.message_id, file=sys.stderr)
        return 2
    if not args.config_dir:
        print("ERROR 沒有 --config-dir 也沒有 $CLAUDE_CONFIG_DIR，無從得知要掃哪個 channel",
              file=sys.stderr)
        return 2

    try:
        targets = enumerate_store_targets(args.config_dir, args.stores_root)
    except FileNotFoundError as e:
        print("ERROR %s" % e, file=sys.stderr)
        return 2

    days = None if args.all else args.days

    per_target = []   # [(label, path_or_None, total, scanned_paths)]
    for label, projects_root, _rp in targets:
        if projects_root is None:
            # 沒有同名 project 子目錄：記 0／0 但仍要露臉
            per_target.append({"label": label, "path": None,
                               "total": 0, "scanned": 0, "paths": []})
            continue
        try:
            picked, total = list_transcripts(projects_root, days)
        except OSError as e:
            print("WARN 店面 %s 跳過（list_transcripts 失敗：%s）" % (label, e),
                  file=sys.stderr)
            per_target.append({"label": label, "path": projects_root,
                               "total": 0, "scanned": 0, "paths": []})
            continue
        per_target.append({"label": label, "path": projects_root,
                           "total": total, "scanned": len(picked), "paths": picked})

    findings = []
    for tgt in per_target:
        for path in find_candidate_files(tgt["paths"], args.message_id):
            delivery, sends = scan_file(path, args.message_id)
            if delivery is None:
                continue
            findings.append({"file": path, "delivery_line": delivery,
                             "sends": [{"line": l, "tool": t, "text": x, "result": r,
                                        "evidence": e}
                                       for l, t, x, r, e in sends]})

    answered = any(f["sends"] for f in findings)
    verdict = "ANSWERED" if answered else ("UNANSWERED" if findings else "NOT_FOUND")

    home_projects_root = os.path.join(args.config_dir, "projects")
    scope = {"scanned": sum(t["scanned"] for t in per_target),
             "total": sum(t["total"] for t in per_target),
             "days": days, "root": home_projects_root,
             "roots": [{"label": t["label"],
                        "path": t["path"] if t["path"] else None,
                        "scanned": t["scanned"], "total": t["total"]}
                       for t in per_target]}

    if args.json:
        print(json.dumps({"message_id": args.message_id, "verdict": verdict,
                          "scope": scope, "findings": findings},
                         ensure_ascii=False, indent=1))
    else:
        print("VERDICT: %s  (messageId %s)" % (verdict, args.message_id))
        if verdict == "NOT_FOUND":
            print("  掃過 %d 個 jsonl（聯集共 %d 個%s），找不到這則的送達紀錄。"
                  % (scope["scanned"], scope["total"],
                     "" if days is None else "；時間窗＝近 %d 天" % days))
            for t in per_target:
                line = "  目錄：%s（%s）— %d 個 jsonl" % (
                    t["path"] if t["path"] else "(沒有同名 project 子目錄)",
                    t["label"], t["total"])
                print(line)
            print("  注意一：只被 handoff 引述、沒真的從 get_pending 進來過，也算 NOT_FOUND。")
            print("  注意二：上面那個時間窗是明示的取樣邊界——「這次沒掃到」不等於「不存在」。")
            print("          訊息更早的話加 --days N 或 --all 再查一次。")
            print("  這是 fail-loud——不要當成 UNANSWERED 悶著過，先確認 channel 與 id 有沒有給錯。")
        for f in findings:
            print("  送達於 %s 第 %d 行" % (os.path.basename(f["file"]), f["delivery_line"]))
            for s in f["sends"]:
                first = s["text"].strip().splitlines()[0] if s["text"].strip() else ""
                mark = "reply_token 對得上" if s["evidence"] == "strong" else "綁不回這一則"
                print("    ↳ 第 %d 行 %s 成功送出（%s｜%s）：%s"
                      % (s["line"], s["tool"].split("__")[-1], s["result"], mark, first[:50]))
        if verdict == "ANSWERED":
            strong = any(s["evidence"] == "strong"
                         for f in findings for s in f["sends"])
            if strong:
                print("  ✅ 其中至少一則的 reply_token 對得上這一則，是直接證據。")
            else:
                print("  ⚠️ 這些全是 push（或沒帶 token 的 reply），綁不回是哪一則。")
            print("  ⚠️ ANSWERED 只代表「送達之後有成功送出過」，不代表那則就是在答這一則。")
            print("     同輪可能在講別的事——請自己看上面的節錄再決定要不要重回。")

    return {"ANSWERED": 0, "UNANSWERED": 1, "NOT_FOUND": 3}[verdict]


if __name__ == "__main__":
    sys.exit(main())
