#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""entity-backfill-scan.py — 條目回填「觸發器」（第一段，zero-LLM）

設計原則（不要一個東西做完全部的事，第一步就是先觸發）：
本檔是三段式的**第一段**，職責只有一件——不讓「今天聊到的東西該進條目」這件事無聲消失。

  第一段 觸發（本檔）：笨、機械、不呼叫任何 LLM、不寫 wiki 庫、不判斷值不值得寫。
                       只回答「今天這條逐字稿裡出現了哪些既有條目／哪些書名查無條目」。
  第二段 查證（**主 session 自己兼**：查證由主線自己做
                       （量小、有搜尋），寫檔派小工兵）：
                       逐項判斷是不是誤報（第一段純字串比對，常用詞會誤中）、查證事實、
                       決定條目之間該連哪條線、產出「要寫什麼」的清單。判定為誤報的
                       當輪講一句就算收掉，不必寫檔。
  第三段 小工兵（haiku/sonnet）：照第二段的清單寫檔，不做判斷。

為什麼第一段一定要 zero-LLM：夜間對帳若依賴登入態，憑證池一過期就每晚死在
"Not logged in"。
把觸發掛在任何需要登入態的東西上，等於再造一次同樣的靜默死。本檔只吃檔案系統。

輸出：markdown 區塊到 stdout 或 --out 指定的檔案，供 gen-handoff.sh 以哨兵註解冪等注入。
**本檔有一個副作用**：會讀寫 `<記憶根目錄>/state/entity-backfill-backlog.tsv` 這條積壓佇列，
讓前一班沒收掉的候選滾到下一班，不再被當日重算覆寫掉（紅隊 C-1）。
佇列的讀寫全包在 try 裡，壞掉只會讓第 ④ 段印一行警告，不影響前三段與 handoff 主流程。
任何失敗都不該讓 handoff 主流程受影響——呼叫端負責吞 rc，本檔盡量自己降級不炸。

用法：
  python3 entity-backfill-scan.py --transcript <path.jsonl> [--out <file>] [--date YYYY-MM-DD]
  python3 entity-backfill-scan.py --text <path.txt> --out <file>      # 測試用
"""

import argparse
import json
import os
import re
import sys

# wiki 條目根目錄：必須由 LIFEOS_WIKI_DIR 指定（沒有預設值；gen-handoff.sh 沒設就不會呼叫本檔）
WIKI = os.environ.get("LIFEOS_WIKI_DIR", "")
MEMORY_ROOT = os.environ.get("LIFEOS_MEMORY_ROOT", os.path.expanduser("~/lifeos-memory"))
# 掃這幾個子目錄的條目當比對名冊。concepts 刻意納入——今晚的「trail」「偶然力」這類
# 概念卡跟人物卡一樣會在深聊裡被提到卻沒人回填。
WIKI_DIRS = tuple(s for s in os.environ.get("LIFEOS_WIKI_SUBDIRS", "entities,sources,concepts").split(",") if s)

# 名稱雜訊閘：太短或太常見的名字會把整份清單洗成噪音，寧可漏抓也不要每天報 300 筆。
MIN_CJK_LEN = 2
MIN_ASCII_LEN = 5
# 這些條目名同時是日常用語，命中率高但幾乎都是誤判。命中即略過（不分大小寫）。
STOPNAMES = {
    "ai", "api", "cli", "llm", "mcp", "url", "web", "app", "log", "git",
    "claude", "line", "vault", "wiki", "obsidian", "python", "json",
    "系統", "記憶", "工具", "筆記", "條目", "對話", "訊息", "問題", "方法",
    "時間", "日期", "檔案", "資料", "內容", "規則", "流程", "機制", "設計",
    # 使用者自己的日常用語誤中時，往這裡加；加之前先想清楚代價：
    # 那個詞若同時是真的條目名，從此就不會被本掃描器點名，要靠人主動想到。
}

CJK = re.compile(r"[㐀-鿿豈-﫿぀-ヿ]")


def is_cjk(s):
    return bool(CJK.search(s))


# ── 判重正規化鍵（2026-09-11 修）──────────────────────────────
# 實爆：對話寫《銀翼殺手 2049》、條目檔名是 銀翼殺手2049.md，`b in index` 精確比對
# 不中，於是天天報成「查無條目」的建卡候選——假陰性長得跟真候選一模一樣。
# 只在「這個名字有沒有條目」的判重用，**不用於 ① 的子字串比對**（那邊要拿原字串
# 去逐字稿裡找，正規化過的鍵在逐字稿裡不存在）。
_WS_RE = re.compile(r"\s+")


def norm_name(s):
    r"""判重鍵：吃 `\s` 涵蓋到的所有 Unicode 空白＋casefold。

    item4(d)（2026-09-11 med-fix）：`\s` 在 Python `re` 對 `str` 樣式預設就是
    Unicode 模式，涵蓋的遠不只「半形／全形／NBSP 三種」——親自逐字元探測過
    （見 `scratchpad/medfix/ws_probe.py`）確認實際涵蓋：半形 tab／換行／垂直定位
    ／換頁／回車（U+0009-U+000D）、檔案/群組/紀錄/單元分隔符（U+001C-U+001F）、
    半形空白（U+0020）、NEL（U+0085）、NBSP（U+00A0）、Ogham 空格記號（U+1680）、
    U+2000 到 U+200A 這一整排空白、行分隔符／段落分隔符（U+2028／U+2029）、
    窄不斷行空白（U+202F）、數學中等空白（U+205F）、全形空白（U+3000）。
    **不**涵蓋：零寬空白（U+200B，Unicode 定義它不算 whitespace）、
    蒙古文元音分隔符（U+180E，Unicode 6.3 起已不算 whitespace）、
    位元組順序記號 / 零寬不斷行空白（U+FEFF）。

    LOW-14（紅隊實測，近四千篇／六千多個名稱的真實 wiki）：
    這句話要老實講到哪裡為止，不要讓「去空白、casefold」聽起來像「同一部作品的
    各種寫法都比得到了」——不是：
    - **不處理**全形數字（２０４９ vs 2049）、零寬字元（U+200B，見上）、
      間隔號 ・（U+30FB）、連字號 -。《銀翼殺手２０４９》《銀翼殺手・2049》這類
      寫法仍然比不到 `銀翼殺手2049.md`，會繼續被報成建卡候選。
    - `casefold()` 不只是小寫，還做 Unicode 特殊折疊：`Straße`／`Strasse` 會撞成
      同一鍵、`ﬁlm`（U+FB01 連字）／`film` 會撞成同一鍵、希臘字尾 sigma
      （`ΟΔΥΣΣΕΥΣ`／`Οδυσσευς`）也會撞——這是 `casefold()` 本身的行為，
      不是這裡刻意加的規則，但確實是這個判重鍵的一部分射程。
    """
    return _WS_RE.sub("", s).casefold()


_NORM_INDEX_WARNED = False


def norm_index(index):
    """{norm_name: (relpath, tags)}；撞號先到先得，跟 index 同一套規矩。

    LOW-14：正規化把兩個不同 `rel` 的鍵擠成同一個時，記一行 stderr 摘要
    （最多列 3 個例子）——這是 wiki 庫 有重複條目的訊號，本身就值得被看到；
    同一檔的多種寫法（title／stem／alias 都指向同一個 rel）不算撞號，不計。
    每個行程只印一次（`_NORM_INDEX_WARNED`），main() 一趟裡這支會被呼叫不只
    一次（book 比對一次、`_merge_backlog` 內部又一次），不用同一件事印兩遍。

    item4(e)（2026-09-11 med-fix）：撞號計數要算**距離不同的正規化鍵**有幾組，
    不是算撞到的「名稱」有幾個。舊寫法拿 list 逐名累加——`out[k]` 只在第一次
    佔住鍵時設定、之後永遠不更新，於是同一個鍵的第二個以後撞名（即使跟第二個
    撞名指向同一個 rel，是同一份重複條目的另一個別名）會被拿去跟「第一個」
    再比一次、再記一筆，把一組真正的撞號灌水成好幾筆。實爆：`solanin` 這個鍵
    如果被 `solanin`／`SOLANIN`／`Solanin ` 三個名稱撞到、其中兩個指向同一個
    重複條目的 rel，舊寫法數成「2 組」，實際只有 1 組鍵在撞（`solanin` 這個
    正規化鍵底下有兩個不同 rel）。改用 dict（鍵＝撞到的正規化鍵本身）只在
    第一次偵測到該鍵撞號時記一筆，同一個鍵之後再撞幾次都不重複計數。
    """
    global _NORM_INDEX_WARNED
    out = {}
    collisions = {}   # 正規化鍵 → (撞號當下的名稱, 原本佔住的 rel, 撞進來的 rel)；每個鍵只記第一次
    for name, val in index.items():
        k = norm_name(name)
        if k in out:
            if out[k][0] != val[0] and k not in collisions:
                collisions[k] = (name, out[k][0], val[0])
            continue
        out[k] = val
    if collisions and not _NORM_INDEX_WARNED:
        _NORM_INDEX_WARNED = True
        examples = "；".join("%s→%s vs %s" % c for c in list(collisions.values())[:3])
        sys.stderr.write(
            "entity-backfill-scan: norm_index 撞號 %d 組指向不同 rel（例：%s）\n"
            % (len(collisions), examples)
        )
    return out


# ── 判重鍵、欄位淨化（MED-10／MED-11，2026-09-11 紅隊）───────────────────
_TSV_BREAK_RE = re.compile(r"[\t\r\n]")


def _sanitize_field(s):
    """把會撞壞 TSV 欄位數的字元（tab／回車／換行）換成一個空白（MED-11）。

    實爆機制：書名裡帶 tab → `"\\t".join(row)` 寫出 5 欄以上的一行 →
    `_load_backlog`／`_append_overflow` 的 `len(parts) != 4` 把它靜默跳過，
    這則提及永久消失、沒有任何計數會顯示少了一列。
    """
    return _TSV_BREAK_RE.sub(" ", s) if isinstance(s, str) else s


def _dedup_key(kind, key):
    """佇列判重統一鍵（MED-10）：book 型正規化（去空白＋casefold，跟名冊比對
    同一套），entry 型維持原樣——`key` 是相對路徑，路徑不能 casefold（會把
    大小寫不同的真實檔案路徑誤判成同一個）。

    MED-10 實爆：正式佇列曾同時收著 `復仇者聯盟 3：無限之戰` 與
    `復仇者聯盟3：無限之戰` 兩列，② 的 `seen`、`_merge_backlog`／
    `_append_overflow` 的 dedup key 都是原字串，永遠不會互相收掉。
    """
    if kind == "book":
        return (kind, norm_name(key))
    return (kind, key)


def rel_index(index):
    """{relpath: tags}。_resolved 的 entry 型本來每一列都線性掃一遍 index（六千多個名字），
    佇列一長就是 列數 × 6500 次比對。先反查一次做成表，之後每列 O(1)。
    同一個 rel 的 tags 來自同一個檔，所以撞號取哪一份都一樣。"""
    out = {}
    for _name, (rel, tg) in index.items():
        out.setdefault(rel, tg)
    return out


def usable_name(name):
    """名字夠不夠格進比對名冊。"""
    n = name.strip()
    if not n or n.lower() in STOPNAMES:
        return False
    if is_cjk(n):
        return len(n) >= MIN_CJK_LEN
    return len(n) >= MIN_ASCII_LEN


def parse_frontmatter(path, max_lines=40):
    """極簡 frontmatter 讀取——只取 title / aliases / tags 三個欄位。

    刻意不引 yaml：這支要在 gen-handoff 的 60 秒逾時內跑完 2800 份檔案，
    而且不能因為某份卡的 frontmatter 寫壞就整輪失敗。
    """
    title, aliases, tags = None, [], []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            first = f.readline()
            if first.strip() != "---":
                return title, aliases, tags
            # aliases 與 tags 都可能寫成多行 YAML 清單（`tags:` 換行後接 `- 項目`），
            # 兩個欄位各自要一個狀態旗標。2026-08-28 跨家紅隊 D-1 實證：原本只有
            # in_aliases，tags 只認 inline `[...]`，wiki 內約三十分之一的篇數用多行寫法的
            # 條目 tags 恆解析成空清單 → 「今天已回填」永遠判 False → 天天重複誤報。
            in_aliases = False
            in_tags = False
            for _ in range(max_lines):
                line = f.readline()
                if not line or line.strip() == "---":
                    break
                raw = line.rstrip("\n")
                stripped = raw.strip()
                if in_aliases:
                    if stripped.startswith("- "):
                        aliases.append(stripped[2:].strip().strip('"\''))
                        continue
                    in_aliases = False
                if in_tags:
                    if stripped.startswith("- "):
                        tags.append(stripped[2:].strip().strip('"\''))
                        continue
                    in_tags = False
                if stripped.startswith("title:"):
                    title = stripped[6:].strip().strip('"\'')
                elif stripped.startswith("aliases:"):
                    rest = stripped[8:].strip()
                    if rest.startswith("["):
                        aliases.extend(
                            x.strip().strip('"\'')
                            for x in rest.strip("[]").split(",")
                            if x.strip()
                        )
                    else:
                        in_aliases = True
                elif stripped.startswith("tags:"):
                    rest = stripped[5:].strip()
                    if rest.startswith("["):
                        tags.extend(
                            x.strip().strip('"\'')
                            for x in rest.strip("[]").split(",")
                            if x.strip()
                        )
                    elif not rest:
                        # `tags:` 後面沒東西＝多行清單開頭；有東西但非 [ 開頭＝純量，忽略
                        in_tags = True
    except OSError:
        pass
    return title, aliases, tags


def load_wiki_index():
    """回傳 {name: (relpath, tags)}；同名撞號時先到先得（不重要，只是候選清單）。"""
    index = {}
    files = 0
    for sub in WIKI_DIRS:
        d = os.path.join(WIKI, sub)
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(d, fn)
            files += 1
            stem = fn[:-3]
            title, aliases, tags = parse_frontmatter(path)
            rel = os.path.join("wiki", sub, fn)
            for name in [stem, title] + aliases:
                if name and usable_name(name) and name not in index:
                    index[name] = (rel, tags)
    return index, files


# LINE 線的對話**不在** message.content 裡（實測：數百筆 entry 只有個位數個 text
# part）。使用者的話走 get_pending 的 tool_result 進來，我的回覆走
# reply/push 的 tool_use input 出去。只認 message.content 等於對整條 LINE 線失明——
# 這正是「掃了但永遠報空」那種最難發現的壞法，所以下面兩種來源都要收。
CHAT_TOOL = re.compile(os.environ.get("LIFEOS_CHAT_TOOL_RE", r"mcp__line__|mcp__telegram__|telegram"), re.I)

# ── 自我報告哨兵（2026-09-02 修：自我延續假陽性迴圈）───────────────────
# 本檔的輸出會被 gen-handoff.sh 用這組哨兵注入 handoff.md（見檔頭 docstring）；
# handoff.md 又會被 SessionStart hook 注入下一場 session 的 transcript——不論是
# 以 {"type":"attachment"} 形狀原封不動塞進去（實測：無 message 欄位，本檔本來就
# 不掃）、被 Read／Bash／Agent 等工具讀出後夾在 tool_result／text 裡、還是被別的
# 摘要管線整段引用成一坨字串。不管落在 transcript 哪個角落、用哪個 entry 形狀
# 出現，只要含這組哨兵，中間內容就是「機械生成的回填報告」不是「人講的話」。
# 用結構（哨兵界線）排除，不是拿「搞定」「工單」這些條目名稱當黑名單——
# 黑名單會連使用者真的在聊這幾個字的對話都一併殺掉。
SELF_REPORT_BLOCK = re.compile(
    r"<!--\s*entity-backfill-start\s*-->.*?<!--\s*entity-backfill-end\s*-->",
    re.S,
)


def strip_self_report(text):
    """挖掉文字裡所有本檔自己產生過的回填報告區塊（見 SELF_REPORT_BLOCK 上的說明）。

    在 join 完所有 harvest 到的 chunk 之後才做一次，而不是逐 chunk 做：
    哨兵永遠是同一份 handoff.md 裡完整的一對，成對出現在同一個 JSON 字串欄位
    （攻擊面只有「一則 entry 裡有沒有這組哨兵」，不會被 chunk 邊界切斷）。
    """
    if not text:
        return text
    return SELF_REPORT_BLOCK.sub("\n", text)


def _harvest_tool_result(part, chunks):
    c = part.get("content")
    if isinstance(c, str):
        chunks.append(c)
    elif isinstance(c, list):
        for sub in c:
            if isinstance(sub, dict) and isinstance(sub.get("text"), str):
                chunks.append(sub["text"])


# ── Hook 注入標記（SPEC R3：防止 hook 內容被當成 user 對話）────────────
HOOK_PROMPT_TOKENS = (
    "<system-reminder>",
    "hook success",
    "memory_echo",
    "自動接手",
    "IN-FLIGHT",
    "UNTRUSTED-HISTORY",
    "[自動 resume]",
    "Base directory for this skill",
)


def extract_transcript_text(path):
    """把 jsonl 逐字稿裡的對話文字抽成一坨字串。

    收三種來源：①message.content 的字串／text part（純終端機 session 走這條）
    ②通訊工具（LINE MCP 等）的 tool_use input.text＝我送出去的話
    ③tool_result＝使用者送進來的話。

    刻意**不收** thinking：那裡面常出現「考慮過但沒用」的作品，收進來會製造假的回填待辦。
    也不收 Bash／Read 之類的 tool_result（見 CHAT_TOOL 過濾）——條目該記的是人講的話，
    不是我跑了哪些指令。壞行一律跳過（逐字稿被截斷是常態）。

    回傳前會再過 `strip_self_report`：本檔上一輪的輸出常以各種形狀（hook 注入的
    attachment、Read/Bash 的 tool_result、被摘要管線整段引用）回流進 transcript，
    含哨兵的區塊一律先剪掉，避免把自己的報告當成「今天又有人提到」重新計數
    （2026-09-02 修：自我延續假陽性迴圈）。
    """
    chunks = []
    bad = 0
    chat_tool_ids = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    bad += 1
                    continue
                # SessionStart hook 注入的交接卡內容以 {"type":"attachment",
                # "attachment":{"hookEvent":"SessionStart", ...}} 這個形狀存在
                # （2026-09-02 實測樣本），本來就沒有 "message" 欄位，下面那個
                # isinstance 檢查就會跳過——這行只是把「這類 entry 結構上不是
                # 對話」的判斷寫明，不依賴巧合，也防未來格式微調把它塞進
                # message 欄位時悄悄破功。
                if obj.get("type") == "attachment":
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict):
                    continue
                is_user = (
                    msg.get("role") == "user"
                    or obj.get("type") == "user"
                    or obj.get("role") == "user"
                )
                content = msg.get("content")
                if isinstance(content, str):
                    if is_user and any(tok in content for tok in HOOK_PROMPT_TOKENS):
                        continue
                    chunks.append(content)
                elif isinstance(content, list):
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        ptype = part.get("type")
                        if ptype == "text":
                            t = part.get("text")
                            if isinstance(t, str):
                                if is_user and any(tok in t for tok in HOOK_PROMPT_TOKENS):
                                    continue
                                chunks.append(t)
                        elif ptype == "tool_use":
                            name = str(part.get("name") or "")
                            if not CHAT_TOOL.search(name):
                                continue
                            tid = part.get("id")
                            if tid:
                                chat_tool_ids.add(tid)
                            inp = part.get("input")
                            if isinstance(inp, dict) and isinstance(inp.get("text"), str):
                                chunks.append(inp["text"])
                        elif ptype == "tool_result":
                            # tool_result 只有 tool_use_id 認得出是不是通訊工具的回傳；
                            # 對不上 id 的一律不收，免得把 Bash 輸出、檔案內容整坨吸進來。
                            if part.get("tool_use_id") in chat_tool_ids:
                                _harvest_tool_result(part, chunks)
    except OSError as e:
        return "", 0, f"讀不到逐字稿：{e}"
    return strip_self_report("\n".join(chunks)), bad, None


# ── 機械處理排除───────────────────────────────────
# 夜掃補 frontmatter 欄位時，session 自己敘述處理進度的
# 文字（例如「現在處理 某條目.md」）會被當成「使用者聊到這個條目」誤記進候選清單
# ——實測一份 handoff 的 27 筆候選裡 25 筆跟當天夜掃佇列要處理
# 的檔名完全重疊，重複出現次數也對得上。
#
# 排除訊號用**結構事實**不用關鍵字：這份逐字稿裡真的對該檔案下過 Edit/Write/
# MultiEdit，代表這是機械處理不是對話內容。使用者真的聊到但沒有被同一份逐字稿
# 動手改過的條目不受影響（陰性對照）。
EDIT_TOOL_NAMES = frozenset({"Edit", "Write", "MultiEdit"})


def extract_edited_wiki_paths(path):
    """回傳這份逐字稿裡被 Edit／Write／MultiEdit 動過的 wiki/ 相對路徑集合（如
    `wiki/entities/某條目.md`）。讀不到／格式不符一律降級回空集合，不炸主流程。
    """
    paths = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for part in content:
                    if not isinstance(part, dict) or part.get("type") != "tool_use":
                        continue
                    if str(part.get("name") or "") not in EDIT_TOOL_NAMES:
                        continue
                    inp = part.get("input")
                    if not isinstance(inp, dict):
                        continue
                    fp = inp.get("file_path")
                    if not isinstance(fp, str):
                        continue
                    idx = fp.find("/wiki/")
                    if idx == -1:
                        continue
                    paths.add(fp[idx + 1:])
    except OSError:
        pass
    return paths


# ── 機械處理排除之二：夜掃佇列（2026-09-09 立）──────────────────────────
# gq5q 那道排除只看「本份逐字稿裡下過 Edit/Write」，抓不到**工兵**改的檔——子代理有
# 自己的逐字稿，父檔裡連 isSidechain 條目都沒有。結果是夜掃派
# 工兵補圖的那一晚，25 個被處理的條目名整批變成「今天聊到」的候選，把真正的訊號淹掉
# （實測：①段 30 筆裡 25 筆就是當晚夜掃佇列的內容）。
#
# 補的訊號一樣是結構事實不是關鍵字：這個條目今天被排進 wiki-enrich-queue-<日期>.tsv，
# 就代表它是被機械處理的對象，不是有人聊到它。跟 gq5q 一樣只影響「今天的報告版面」，
# 這些筆照樣回傳在 excluded、照樣進積壓佇列，所以使用者真的聊到時不會永久消失。
# 選配：夜掃佇列檔的路徑樣板（%s＝YYYYMMDD），沒設就當今天沒跑夜掃
ENRICH_QUEUE_TMPL = os.environ.get("LIFEOS_ENRICH_QUEUE_TMPL", "")


def extract_enrich_queue_wiki_paths(today):
    """回傳今天夜掃佇列裡排到的 wiki/ 相對路徑集合。

    `today` 是 YYYY-MM-DD；佇列檔名用 YYYYMMDD。第一欄是 wiki 庫 絕對路徑。
    檔案不在／讀不到一律回空集合（今天沒跑夜掃是常態，不該炸主流程）。
    """
    paths = set()
    if not ENRICH_QUEUE_TMPL:
        return paths
    qpath = ENRICH_QUEUE_TMPL % today.replace("-", "")
    try:
        with open(qpath, encoding="utf-8", errors="replace") as f:
            for line in f:
                fp = line.split("\t", 1)[0].strip()
                if not fp:
                    continue
                idx = fp.find("/wiki/")
                if idx == -1:
                    continue
                paths.add(fp[idx + 1:])
    except OSError:
        pass
    return paths


BOOK = re.compile(r"《([^《》\n]{1,40})》")

# ── 積壓佇列（第 4 段輸出）─────────────────────────────────────────────
# 為什麼要有：本檔每次跑都用當日逐字稿重算，**輸出是覆寫的**。前一班沒收掉的候選
# 到了下一班就整批消失，長得像「今天沒東西」。2026-08-28 紅隊 C-1 點出，
# 決定採「補待辦佇列——沒處理的候選滾到下一班」。
#
# 分寸：這條佇列**只記「提過但沒人收」**，不記「該不該寫」——判斷仍在第二段。
# 它會過期（BACKLOG_DAYS）也會封頂（BACKLOG_MAX），寧可掉最舊的也不要長成第二份噪音源。
# 佇列檔位置可用環境變數改道，預設是正式檔。
# 這條存在的理由是實測踩到的：拿 --text 餵合成逐字稿試跑會**真的寫進正式佇列**，
# 探針用的假書名留在裡面，下一班就會看到一列不存在的建卡候選（2026-09-11 自己中兩次）。
# 測試時 export LIFEOS_ENTITY_BACKFILL_DIR=<暫存目錄> 就不會碰到正式檔。
_STATE_DIR = os.environ.get("LIFEOS_ENTITY_BACKFILL_DIR") or os.path.join(MEMORY_ROOT, "state")
BACKLOG_PATH = os.path.join(_STATE_DIR, "entity-backfill-backlog.tsv")
BACKLOG_DAYS = 30
BACKLOG_MAX = 200


def _report_path(path):
    """報告版面上要印的路徑。

    MED-4（2026-09-11 紅隊）：這兩行原本寫死 `<記憶根目錄>/state/entity-backfill-*.tsv`，
    但佇列路徑可以被 LIFEOS_ENTITY_BACKFILL_DIR 改道——改道時卡片會指著一個
    它根本沒讀過的檔，下一班照著去看只會看到不相干的內容。有改道就照實印。
    """
    root = MEMORY_ROOT
    try:
        if os.path.commonpath([os.path.abspath(path), root]) == root:
            return os.path.relpath(os.path.abspath(path), root)
    except ValueError:
        pass
    return path


def _load_backlog(path=None):
    """回 [(first_seen, kind, key, label)]。讀不到／壞行一律降級成空，不炸主流程。

    MED-3（2026-09-11 紅隊）：預設值在呼叫當下才解析（`path or BACKLOG_PATH`），
    不在 def 當下綁死——`_append_overflow`／`_overflow_count` 早就這樣寫，
    這支跟 `_write_backlog` 原本各半，量具改 `m.BACKLOG_PATH` 對這支沒用，
    現在四支對齊同一套規矩。
    """
    path = path or BACKLOG_PATH
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                ln = ln.rstrip("\n")
                if not ln or ln.startswith("#"):
                    continue
                parts = ln.split("\t")
                if len(parts) != 4:
                    continue
                rows.append(tuple(parts))
    except Exception:
        return []
    return rows


def _write_backlog(rows, path=None):
    """原子寫。失敗只回 False，不讓 handoff 主流程掛掉。

    MED-3：預設值在呼叫當下才解析，見 `_load_backlog` 上的說明。
    """
    path = path or BACKLOG_PATH
    import tempfile
    try:
        d = os.path.dirname(path) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".entity-backlog-", dir=d)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("# first_seen\tkind\tkey\tlabel — entity-backfill-scan.py 的積壓佇列\n")
            for r in rows:
                # MED-11：防禦性淨化——正常呼叫路徑（main()）已經在建列當下淨化過，
                # 這裡是最後一道防線，防別的呼叫端（量具、未來的呼叫者）漏做。
                f.write("\t".join(_sanitize_field(x) for x in r) + "\n")
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        return False


OVERFLOW_PATH = os.path.join(_STATE_DIR, "entity-backfill-overflow.tsv")


def _overflow_count(path=None, exclude=None):
    """溢出檔現有幾列（不含標頭）。讀不到一律回 0，不炸主流程。

    存在的理由：溢出檔本身沒有讀者——只有撞封頂那一趟會在 ④ 段被提一句，
    沒撞的日子它就完全隱形，等於換個地方無聲堆積。所以每一趟都報。

    MED-9：`exclude` 傳「已經回到 backlog 的判重鍵集合」（`_dedup_key(kind, key)`）。
    同一列可以同時躺在 backlog 與 overflow——某列溢出過，之後使用者又提到同一
    件事，會以新的 first_seen 重新進 backlog，但 overflow 裡那份舊的並不會被
    `_resolved` 剔除（它還沒被動過或建卡）。不排除的話卡片會把同一件事算兩次。
    這裡**不刪**那份舊的（見 `_append_overflow` 的 prune 說明——它保著更早的
    first_seen，backlog 30 天過期後還有機會被看到），只是不重複計數。
    """
    n = 0
    try:
        with open(path or OVERFLOW_PATH, encoding="utf-8", errors="replace") as f:
            for ln in f:
                raw = ln.strip()
                if not raw or raw.startswith("#"):
                    continue
                if exclude:
                    parts = raw.split("\t")
                    if len(parts) == 4 and _dedup_key(parts[1], parts[2]) in exclude:
                        continue
                n += 1
    except Exception:
        # 2026-09-11 紅隊 HIGH-15：原本只接 OSError，而 UnicodeDecodeError 繼承的是
        # ValueError——溢出檔有一個非 UTF-8 位元組就會一路穿出去，把整段「今日條目
        # 回填待辦」從交接卡上炸掉（實測 rc=1、零輸出）。docstring 寫的「不炸主流程」
        # 要由 except 兌現，不是由 docstring 兌現。
        return 0
    return n


# ── 名冊健全性閘（2026-09-11 紅隊 CRIT-1）────────────────────────────────
# `_resolved` 的 entry 分支寫著「key 不在名冊裡＝收掉了」。這句話只有在名冊本身可信
# 的時候才成立：名冊空掉或殘缺時，每一條 entry 列都「不在名冊裡」，於是**一趟就把
# 佇列裡所有 entry 列連同 overflow 永久帳本一起清光，而且交接卡印成「收掉了 N 筆」**
# ——把「我看不到 wiki 庫」講成「事情做完了」。
# 實爆一次：一支審這支腳本的工兵把 WIKI 指到只有 1 篇的測試目錄，
# 179 列 entry 當場消失（有備份才救回來）。真實世界的同型觸發：wiki 目錄沒掛上、
# 路徑被換掉、指到退役的雙胞胎目錄、parse_frontmatter 撞權限被 except 吞掉。
# 處置一律 fail-closed：**寧可這一趟不收，也不要把看不見當成做完了。**
INDEX_FLOOR = int(os.environ.get("LIFEOS_WIKI_INDEX_FLOOR", "10"))  # 名冊低於這個名稱數就不可信；大庫請調高（例如常態的一成）

def _index_health(index):
    """回 None＝名冊可信；回一句話＝不可信的理由（呼叫端據此跳過所有「判收掉」）。"""
    missing = [sub for sub in WIKI_DIRS if not os.path.isdir(os.path.join(WIKI, sub))]
    if missing:
        return "wiki 子目錄讀不到：" + "／".join(missing)
    if not index:
        return "名冊是空的"
    if len(index) < INDEX_FLOOR:
        return "名冊只有 %d 個名稱，低於下限 %d" % (len(index), INDEX_FLOOR)
    return None


def _alert_index_degraded(reason, kept):
    """名冊不可信時落一列告警（五欄 TSV，各線每輪會讀）。失敗不炸主流程。"""
    try:
        inbox = os.environ.get("ALERT_INBOX")  # 選配：沒設就不落告警（交接卡本身照印）
        if not inbox:
            return
        import datetime as _dt
        with open(inbox, "a", encoding="utf-8") as f:
            f.write("\t".join([
                _dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
                "entity-backfill-scan", "warn", "new",
                "wiki 名冊不可信（%s），這一趟**沒有**收掉任何列、也沒動 overflow，"
                "%d 列原封不動留在佇列。先確認 wiki 目錄掛得上、路徑沒被換掉，再看交接卡的數字。"
                % (reason, kept),
            ]) + "\n")
    except Exception:
        pass


def _alert_overflow_write_failed(n):
    """溢出檔寫不進去時落一列告警。那 n 列已併回佇列，但佇列會超過封頂，要有人知道。"""
    try:
        inbox = os.environ.get("ALERT_INBOX")  # 選配：沒設就不落告警（交接卡本身照印）
        if not inbox:
            return
        import datetime as _dt
        with open(inbox, "a", encoding="utf-8") as f:
            f.write("\t".join([
                _dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
                "entity-backfill-scan", "warn", "new",
                "溢出檔寫入失敗，%d 列已併回佇列（佇列因此超過封頂）。"
                "先看記憶根目錄的 state/ 能不能寫、entity-backfill-overflow.tsv 是不是被做成目錄。" % n,
            ]) + "\n")
    except Exception:
        pass


def _append_overflow(rows, index, nindex, today, path=None, relmap=None, prune=True):
    """封頂溢出的列滾進永久檔（不是丟掉）。回實際寫入的新列數；**寫失敗回 None**。

    MED-8（2026-09-11 紅隊）：這是**永久帳本、沒有天數過期**——條目被動過或建卡
    完成（`_resolved` 判 True）才會被剔除，不因為躺了多久就自動消失（那樣會重演
    backlog「30 天沒人理就丟」的問題，而 overflow 存在的理由正是「不要再丟東西」）。
    但 prune 動作以前只掛在撞封頂那一天（`rows` 非空）才會跑，沒撞封頂的日子完全
    不動，`_overflow_count()` 卻照樣把已經收掉的舊列一起算進去，數字是虛胖的。
    現在呼叫端每一趟都會呼叫這支一次、`rows` 可以是空的——空 rows 一樣要跑 prune
    維護，只是不加新列；`prune=False`（名冊不可信）時完全不做事、不碰檔案，維持
    「看不見就不動手」的既定分寸，也不會被空 rows 這件事影響。

    每次寫入順手把已經收掉的列剔除，免得這個檔長成第二份永不縮小的噪音源；
    如果這一趟既沒加新列也沒剔掉任何東西，直接跳過寫檔（MED-8：維護呼叫現在
    每趟都會跑，不該讓它把檔案 mtime 無謂地弄髒）。任何一步失敗都只回 0（早退）
    或 None（寫入失敗），絕不炸主流程——它是附帶帳本，不是交付物。

    MED-10：判重鍵改用 `_dedup_key`（book 型正規化去空白＋casefold、entry 型維持
    原樣），同一部作品的兩種書名寫法不再在這裡各佔一列。
    MED-11：寫出前淨化每個欄位裡的 tab／換行，避免產生欄位數對不上、下次讀回來
    被靜默跳過的壞列。

    已知限制（照 R10 第 7 列記進來，不加閘）：八條線各自產交接卡，理論上兩條同時
    寫這個檔會後寫的蓋掉先寫的那幾列。os.replace 是原子的所以檔案不會壞，壞的是
    「其中一趟溢出的列沒留下、而且回報的 wrote= 數字沒發現」——MED-12
    （2026-09-11）在呼叫端（`_update_queue`）加了 flock 與寫後重讀驗證，這支本身
    維持無鎖，給單元測試直接呼叫時行為不變。
    """
    import tempfile
    if not rows and not prune:
        # 名冊不可信：沒有新列要溢出，也不做 prune 維護——不碰檔案，維持
        # 「看不見就不動手」的既定分寸（跟 _merge_backlog 對 backlog 本身一致）。
        return 0
    # 預設值在呼叫當下才解析，不在 def 當下綁死——綁死的話測試改不動它。
    path = path or OVERFLOW_PATH
    try:
        existing = []
        # item4(b)（2026-09-11 med-fix）：非空、非註解、但欄位數不是 4 的壞列——
        # 過去讀進來就被 `len(parts) == 4` 那道濾網靜默丟掉，重寫一次整段內容
        # 就無聲消失了。這種壞列多半是人工編輯或舊版格式留下的殘跡，原樣留著，
        # 不試著解讀、不參與判重／prune／排序，下次重寫照樣把它寫回去。
        malformed = []
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for ln in f:
                    raw = ln.rstrip("\n")
                    if not raw or raw.startswith("#"):
                        continue
                    parts = raw.split("\t")
                    if len(parts) == 4:
                        existing.append(tuple(parts))
                    else:
                        malformed.append(raw)
        except OSError:
            pass
        original_sorted = sorted(existing, key=lambda r: (r[0], r[1], r[2]))
        seen = {_dedup_key(r[1], r[2]) for r in existing}
        added = 0
        for r in rows:
            k = _dedup_key(r[1], r[2])
            if k in seen:
                continue
            seen.add(k)
            existing.append(tuple(_sanitize_field(x) for x in r))
            added += 1
        # prune=False（名冊不可信時）：只加不剔，永久帳本不因為看不見 wiki 庫 而縮水。
        alive = existing if not prune else [
            r for r in existing if not _resolved(r, index, today, nindex, relmap)]
        alive.sort(key=lambda r: (r[0], r[1], r[2]))
        # item4（LOW，2026-09-11 med-fix3）：原本這裡多加了 `and not malformed`，
        # 意思是「只要檔案裡躺著一行壞格式的列，就永遠不算『沒有變化』」——但
        # malformed 那些列從讀進來到寫出去全程原樣不動（見下面 for raw in
        # malformed），它們存在不存在跟「這一趟有沒有變化」無關。壞列存在時這個
        # 條件恆假，於是每一趟健康的維護呼叫（`rows=[]`、什麼都沒剔掉）都會把
        # 檔案整份重寫一次，session-end 掛的 entity-backfill-scan.py 在八條線
        # 每一輪都跑，等於白白多出 I/O 且 mtime 被無謂弄髒——正是這支函式自己
        # 說好要避免的事（見上面 docstring「不該讓它把檔案 mtime 無謂地弄髒」）。
        # 拿掉 `not malformed`：只要 alive 跟 original_sorted 一致（正常列没變）
        # 且沒有新增，就真的什麼都沒變，不必寫檔——壞列會被原樣寫回去這件事本來
        # 就不影響檔案的最終內容。
        if added == 0 and alive == original_sorted:
            return 0     # 這一趟真的沒有任何變化，不必寫檔
        d = os.path.dirname(path) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".entity-overflow-", dir=d)
        # item4(a)（2026-09-11 med-fix）：mkstemp 之後、os.replace 之前的每一步都可能
        # 失敗——過去只有 os.replace 那一段失敗會清 tmp，寫檔本身（f.write）炸掉
        # （例如磁碟滿）時 tmp 會留下一個點開頭的隱藏殘檔，沒人清。改成整段
        # mkstemp→write→replace 共用一個 try/except，任何一步失敗都清 tmp 再往外拋，
        # 讓外層的 `except Exception: return None` 接住、呼叫端知道要把列併回佇列。
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("# first_seen\tkind\tkey\tlabel — 封頂溢出（backlog 裝不下、但沒人收的列，"
                         "永久帳本、無天數過期）\n")
                for r in alive:
                    f.write("\t".join(_sanitize_field(x) for x in r) + "\n")
                for raw in malformed:
                    f.write(raw + "\n")
            os.replace(tmp, path)
        except Exception:
            # MED-7（2026-09-11 紅隊）：隔壁 _write_backlog 失敗會清 tmp，這裡漏了。
            # 每失敗一次留一個點開頭的隱藏殘檔，八條線每天各跑數次會慢慢塞爆 state/。
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return added
    except Exception:
        # HIGH-6（2026-09-11 紅隊）：回 0 會跟「沒有新列要寫」撞成同一個值，
        # 呼叫端把寫失敗讀成寫成功，那幾列已經從佇列砍掉＝**真的丟了**，
        # 卡片還照印「滾進 overflow（不是丟掉）」。失敗一律回 None，讓呼叫端救得回來。
        return None


def _resolved(row, index, today, nindex=None, relmap=None):
    """這一列收掉了沒。

    entry 型：條目的 tags 出現**任何一個不早於 first_seen 的日期**＝有人動過它了。
              條目整個不見了也算收掉（刪了就別再嘮叨）。
    book  型：這個書名現在查得到條目了。
    刻意不看「內容有沒有變」——本檔是 zero-LLM 的觸發器，判內容是第二段的事。
    """
    first_seen, kind, key, _label = row
    if kind == "book":
        if key in index:
            return True
        return norm_name(key) in (nindex if nindex is not None else norm_index(index))
    # entry：key 是 relpath，index 的值才有 tags，反查一次
    if relmap is None:
        relmap = rel_index(index)
    if key not in relmap:
        return True                      # 條目已不在名冊裡
    tags = relmap[key]
    for t in (tags or []):
        if isinstance(t, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", t) and t >= first_seen:
            return True
    return False


def _merge_backlog(old, today_rows, index, today):
    """收掉已完成的、加入今天新的、過期與封頂。

    回 (still_open, dropped_resolved, dropped_expired, dropped_cap, dropped_dupes)。
      dropped_expired ＝超出 BACKLOG_DAYS 的列數（按 first_seen 早於 cutoff 算）。
      dropped_cap     ＝過期後仍超過 BACKLOG_MAX 而被丟的最舊列數。
      dropped_dupes   ＝判重鍵撞號而被「合併」掉的列數（item4(c)，2026-09-11
                        med-fix；item3(c)，2026-09-11 med-fix3 收窄定義）：
                        MED-10 讓 `_dedup_key` 把同一部作品的兩種拼法收斂成一列，
                        但收斂掉幾列從來沒被算過或印出來——佇列列數比預期少，
                        卡片上卻看不到原因，容易被誤讀成「東西不見了」。
                        **只算「儲存中的列」互相撞號被收斂的那幾列**：old 段
                        本身互撞、或 today_rows 彼此互撞（不涉及 old）。
                        today_rows 撞到「已經在 old 裡的鍵」**不算**——那只是
                        今天又提到一本已經在佇列裡的書（不管拼法跟舊列相不相同），
                        是尋常的重複提及，在 MED-10 引入 `_dedup_key` 之前這種
                        情況本來就會被舊的逐字判重悄悄丟掉、從沒被當一回事，
                        不該因為判重鍵換了算法就突然開始計數（med-fix3 item3(c)
                        紅隊指出的落差：老是把「東西不見了」的疑慮引到不相干的
                        地方）。
    兩種丟法原本共用 `expired` 計數器，運維分不出是「歷史堆積」還是「當下堵車」——
    分別回報，封頂時再加 stderr 一行，給 gen-handoff 的 GEN_HANDOFF_LOG 接走，
    不另開檔、不寫 state/。

    MED-10：判重鍵改用 `_dedup_key`——同一部作品的兩種書名寫法（`復仇者聯盟 3：
    無限之戰` vs `復仇者聯盟3：無限之戰`）現在會收斂成同一列，先出現的那筆
    （舊佇列列在 today_rows 之前跑）勝出。
    MED-8：不管有沒有撞封頂，健康時每一趟都順手呼叫一次 `_append_overflow([], …)`
    做 overflow 的 prune 維護（不健康時完全不做，交給 `_append_overflow` 自己的
    `prune=False` 早退）。
    """
    import datetime
    import sys as _sys
    kept, resolved = [], 0
    nindex = norm_index(index)
    relmap = rel_index(index)
    unhealthy = _index_health(index)      # 不是 None 就代表名冊不可信
    seen = set()
    old_keys = set()   # item3(c)：記錄哪些鍵是從 old 段收進來的，today_rows 撞到
                        # 這些鍵時只是尋常重複提及，不算合併（見上面 docstring）。
    # item4(c)（2026-09-11 med-fix）：`_dedup_key` 讓同一部作品的兩種拼法收斂成
    # 一列（MED-10），但收斂掉的那幾列從來沒被算過——佇列列數變少了，卡片卻
    # 沒講為什麼，容易被誤讀成「東西不見了」。這裡數一次真正被合併掉的列數，
    # 分兩段各自累加：old 段本身互撞算、today_rows 彼此互撞（不涉及 old）算，
    # today_rows 撞到 old 已有的鍵不算（item3(c)，2026-09-11 med-fix3）。
    # 回傳給呼叫端印進 ④ 段「合併同名 N 筆」。
    dropped_dupes = 0
    for r in old:
        k = _dedup_key(r[1], r[2])
        if k in seen:
            dropped_dupes += 1
            continue
        seen.add(k)
        old_keys.add(k)
        if not unhealthy and _resolved(r, index, today, nindex, relmap):
            resolved += 1
            continue
        kept.append(r)
    for r in today_rows:
        k = _dedup_key(r[1], r[2])
        if k in seen:
            if k not in old_keys:
                dropped_dupes += 1
            continue
        seen.add(k)
        kept.append(r)
    try:
        cutoff = (datetime.date.fromisoformat(today) -
                  datetime.timedelta(days=BACKLOG_DAYS)).isoformat()
    except ValueError:
        cutoff = "0000-00-00"
    fresh = [r for r in kept if r[0] >= cutoff]
    dropped_expired = len(kept) - len(fresh)
    fresh.sort(key=lambda r: (r[0], r[1], r[2]))
    dropped_cap = 0
    if len(fresh) > BACKLOG_MAX:
        dropped_cap = len(fresh) - BACKLOG_MAX
        spilled, fresh = fresh[:dropped_cap], fresh[-BACKLOG_MAX:]
        # 2026-09-11 前這裡是直接丟掉：量到 110 次封頂、累計 644 列永久消失，
        # 而且只寫 stderr，板上與交接卡都看不到。改成滾進溢出檔——佇列不變胖
        # （報告版面照舊只讀 backlog），但沒人收的列不再是「刪掉」而是「搬走」。
        spilled_keys = {_dedup_key(r[1], r[2]) for r in spilled}
        n_over = _append_overflow(spilled, index, nindex, today, relmap=relmap,
                                  prune=not unhealthy)
        if n_over is None:
            # 寫不進永久檔：把溢出的列併回佇列。寧可這一天超過封頂，
            # 也不要讓它們既不在佇列、也不在溢出檔——那就是真的丟掉了。
            fresh = spilled + fresh
            dropped_cap = 0
            _sys.stderr.write(
                f"entity-backfill-scan: overflow write FAILED ({OVERFLOW_PATH}); "
                f"{len(spilled)} rows kept in backlog instead (now {len(fresh)}, "
                f"over BACKLOG_MAX={BACKLOG_MAX})\n"
            )
            _alert_overflow_write_failed(len(spilled))
        else:
            # MED-12（2026-09-11 紅隊）：`n_over`（= `added`）只代表這趟「打算」寫
            # 幾列，不是「真的留下」幾列——並行寫入時另一趟後寫的可能整批蓋掉這趟。
            # 寫完後重讀一次檔案，數這批 spilled 的判重鍵有幾個真的還在，那才是
            # 誠實的 `wrote=`；帳目不准再謊報成功。
            verified = 0
            try:
                with open(OVERFLOW_PATH, encoding="utf-8", errors="replace") as f:
                    file_keys = set()
                    for ln in f:
                        ln = ln.rstrip("\n")
                        if not ln or ln.startswith("#"):
                            continue
                        parts = ln.split("\t")
                        if len(parts) == 4:
                            file_keys.add(_dedup_key(parts[1], parts[2]))
                verified = len(spilled_keys & file_keys)
            except OSError:
                verified = 0
            _sys.stderr.write(
                f"entity-backfill-scan: BACKLOG_MAX={BACKLOG_MAX} hit; "
                f"spilled {dropped_cap} oldest rows to {OVERFLOW_PATH} "
                f"(wrote={verified}, kept {len(fresh)})\n"
            )
            if verified < len(spilled_keys):
                _sys.stderr.write(
                    f"entity-backfill-scan: overflow write verify MISMATCH — "
                    f"attempted {len(spilled_keys)}, only {verified} present after "
                    f"re-read (concurrent writer may have raced)\n"
                )
    elif not unhealthy:
        # MED-8：沒撞封頂的日子，overflow 完全不動就代表它只會無限長大、
        # `_overflow_count()` 每天報的數字裡混著早就收掉的舊列。健康時每一趟
        # 都順手做一次 prune 維護（rows=[]，不加新列）；`_append_overflow` 內部
        # 「沒有任何變化就不寫檔」，不會把這件事變成每天無謂的一次 I/O。
        _append_overflow([], index, nindex, today, relmap=relmap, prune=True)
    if unhealthy:
        # 名冊不可信這一趟：一列都沒收、overflow 沒剔，落一列告警給各線每輪的收件匣讀者。
        # 不寫 stderr 就算了——stderr 這條路只到 GEN_HANDOFF_LOG，沒有人每輪讀。
        _sys.stderr.write(f"entity-backfill-scan: index unhealthy ({unhealthy}); "
                          f"skipped all resolution, kept {len(fresh)} rows\n")
        _alert_index_degraded(unhealthy, len(fresh))
    return fresh, resolved, dropped_expired, dropped_cap, dropped_dupes


def split_candidates(best, edited, today):
    """把 `best`（rel → (次數, 名稱, tags)）拆成 (hit_todo, hit_done, excluded) 三份未排序清單。

    rel 若在 `edited`（本份逐字稿裡被 Edit/Write/MultiEdit 動過的 wiki/ 路徑集合）
    且今天還沒掛 tag，判為機械處理，今天的報告裡不列（見 gq5q：夜掃處理 frontmatter 時
    自己敘述進度的文字會被誤記成「使用者聊到這個條目」），但仍回傳在 `excluded`——
    呼叫端要把它併進 today_rows 一起餵積壓佇列，不能整筆丟掉。理由：如果使用者當天真的
    聊到這個條目、剛好同一份逐字稿又被機械改過但沒補上今天的 tag，這筆是真候選，只是
    今天的報告版面不該顯示；不進積壓等於這則提及永久消失、下次不會再有人看到。
    獨立成函式是為了讓量具能直接呼叫、而不是複製一份邏輯各測各的
    （tests/entity-backfill/test_edited_exclusion.py 的突變測試靠這個抓退化版本）。
    """
    hit_todo, hit_done, excluded = [], [], []
    for rel, (n, name, tags) in best.items():
        if today in tags:
            hit_done.append((n, name, rel))
        elif rel not in edited:
            hit_todo.append((n, name, rel))
        else:
            excluded.append((n, name, rel))
    return hit_todo, hit_done, excluded


# ── 佇列鎖（MED-12，2026-09-11 紅隊）───────────────────────────────────────
# 八條線各自產交接卡，理論上兩條同時跑會互相蓋掉對方新寫的那幾列——`_append_overflow`
# 的 docstring 早就記過這個已知限制，取捨是「只記不修，兩年沒出過實害」。但紅隊指出
# 一件不是取捨問題的事：並行寫失去的那一趟，`_append_overflow` 仍然回傳 `added=N`，
# stderr 照樣印 `wrote=N`——帳目謊報成功，事後連「有沒有掉」都查不出來。
# 同機八條線不是跨機，`fcntl.flock` 夠用，成本比想像低：把「讀 backlog → merge
# （可能溢出到 overflow）→ 寫回 backlog」包成一支、外面罩一層鎖，就同時解掉兩件事。
_QUEUE_LOCK_TIMEOUT = 10.0   # 搶鎖最多等這麼久（秒）；呼叫端 gen-handoff.sh 給整支腳本的預算是 60 秒


def _update_queue(today_rows, index, today):
    """把「讀 backlog → merge（含可能的 overflow 溢出）→ 寫回 backlog」包成一支，
    外面罩一層 `fcntl.flock`，讓 backlog 與 overflow 的 read-modify-write 算同一個
    臨界區——不要 backlog 用鎖、overflow 沒用鎖各鎖各的。

    鎖檔 `<BACKLOG_PATH 所在目錄>/.entity-backfill.lock`，路徑在呼叫當下才解析
    （跟 MED-3 同一套規矩，改 `BACKLOG_PATH` 才改得動，量具才隔離得了）。
    `LOCK_EX|LOCK_NB` 輪詢，最多等 `_QUEUE_LOCK_TIMEOUT` 秒。搶不到鎖不代表就不
    做事——退回無鎖跑一次（維持這支腳本一貫的「寧可有風險地做，也不要交白卷」），
    只是印一行 stderr、把警告字句傳出去讓呼叫端印在卡片上，不能只留在 stderr
    （沒有人每輪讀 GEN_HANDOFF_LOG）。

    回 (merged, n_resolved, n_expired, n_cap, wrote, lock_warning, n_dupes)；
    `lock_warning` 不是 None 時，呼叫端要在 ④ 段補一句警告。`n_dupes` 附加在
    最後一位（item4(c)，2026-09-11 med-fix）——舊呼叫端／量具用索引取
    `lock_warning`（如 `r1[5]`）不受影響，只有靠 tuple 解構取 6 個值的地方
    要多接一個。
    """
    import fcntl
    import time as _time

    lock_path = os.path.join(os.path.dirname(BACKLOG_PATH) or ".", ".entity-backfill.lock")
    lock_warning = None
    lf = None
    got_lock = False
    try:
        os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
        lf = open(lock_path, "a+")
        deadline = _time.monotonic() + _QUEUE_LOCK_TIMEOUT
        while True:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                got_lock = True
                break
            except OSError:
                if _time.monotonic() >= deadline:
                    break
                _time.sleep(0.1)
        if not got_lock:
            sys.stderr.write(
                "entity-backfill-scan: queue lock NOT acquired within "
                "%.0fs (%s); proceeding unlocked — numbers may be overwritten "
                "by a concurrent run\n" % (_QUEUE_LOCK_TIMEOUT, lock_path)
            )
            lock_warning = ("沒搶到佇列鎖（%.0f 秒逾時），這一趟數字可能被同時跑的另一條線覆寫"
                             % _QUEUE_LOCK_TIMEOUT)
    except OSError as e:
        sys.stderr.write(
            "entity-backfill-scan: queue lock file unavailable (%s); proceeding unlocked\n" % e)
        lock_warning = "佇列鎖檔開不了，這一趟數字可能被同時跑的另一條線覆寫"

    try:
        merged, n_resolved, n_expired, n_cap, n_dupes = _merge_backlog(
            _load_backlog(), today_rows, index, today)
        wrote = _write_backlog(merged)
    finally:
        if lf is not None:
            if got_lock:
                try:
                    fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
            try:
                lf.close()
            except OSError:
                pass
    return merged, n_resolved, n_expired, n_cap, wrote, lock_warning, n_dupes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript")
    ap.add_argument("--text", help="改讀純文字檔（測試用）")
    ap.add_argument("--out")
    ap.add_argument("--date", default=None, help="今日日期 YYYY-MM-DD，預設取系統日")
    args = ap.parse_args()

    import datetime
    today = args.date or datetime.date.today().isoformat()

    err = None
    if args.text:
        try:
            text = strip_self_report(
                open(args.text, encoding="utf-8", errors="replace").read()
            )
        except OSError as e:
            text, err = "", f"讀不到文字檔：{e}"
        bad = 0
        src = args.text
    elif args.transcript:
        text, bad, err = extract_transcript_text(args.transcript)
        src = args.transcript
    else:
        ap.error("需要 --transcript 或 --text")

    edited = extract_edited_wiki_paths(args.transcript) if args.transcript else set()
    edited |= extract_enrich_queue_wiki_paths(today)

    lines = []
    lines.append("## 今日條目回填待辦（機械生成 zero-LLM；只判斷「提到了」，不判斷「值不值得寫」）")
    lines.append("")
    lines.append("> 這一段是三段式的**第一段（觸發）**，故意做得很笨：不查證、不寫 wiki 庫、不呼叫任何模型。")
    lines.append("> 它唯一的職責是不讓「今天聊到的東西該進條目」無聲消失。")
    lines.append("> **第二段（查證）由接手的主 session 自己做**，不外派——量小、主線本來就有搜尋。")
    lines.append("> **第三段（寫檔）派 haiku/sonnet 小工兵**，照清單寫、不做判斷。")
    lines.append("> **清單有東西不等於該寫**——第一段是純字串比對，常用詞（復活／工單／檢查表這類）會誤中；")
    lines.append("> 判定為誤報的當輪講一句就算收掉，不必寫檔。真要寫的，寫完該條目 tags 要掛上今日日期。")
    lines.append("")

    if err:
        lines.append(f"> ⚠️ 掃描未完成：{err}——**空清單不等於今天沒東西可回填**，請自行核對。")
        emit(lines, args.out)
        return 0

    index, files = load_wiki_index()
    lines.append(f"**掃描**：來源 `{os.path.basename(src)}`（{len(text)} 字元"
                 + (f"，跳過 {bad} 筆壞行" if bad else "") + f"）；比對 wiki 條目 {files} 篇／名稱 {len(index)} 個")
    lines.append("")

    # 同一份條目會因為 別名／title／檔名 三種寫法各命中一次，去重時保留出現次數最高的那個名字，
    # 否則清單上會看到同一個 rel 連著出現兩三行（實測 vannevar-bush 就重複了）。
    best = {}
    for name, (rel, tags) in index.items():
        if name not in text:
            continue
        n = text.count(name)
        prev = best.get(rel)
        if prev is None or n > prev[0]:
            best[rel] = (n, name, tags)
    # 對話裡出現書名號但比對不到任何條目 → 建卡候選
    # ⚠️ 這一段必須排在 split_candidates 之前（2026-09-11 紅隊 HIGH-5）：比得到條目的書名
    # 要能補進 ① 的 best，補完才輪到切分。排在後面補等於沒補。
    nindex = norm_index(index)
    seen_spellings = set()
    book_first_seen = {}   # norm_key → 第一次看到的原始拼法（MED-10：先到先得，決定顯示用哪個）
    book_total = {}        # norm_key → 累計次數（跨同一部作品的不同拼法加總）
    for m in BOOK.finditer(text):
        orig_b = m.group(1).strip()
        if orig_b in seen_spellings or not orig_b:
            continue
        seen_spellings.add(orig_b)
        # MED-11（2026-09-11 紅隊）：書名裡帶 tab／換行會產生欄位數對不上、下次讀回來
        # 被靜默跳過的壞列——建列當下就淨化，讓判重／佇列裡的鍵不含這些字元。
        # ⚠️ `text.count(...)` 一律用 `orig_b`（未淨化）去算——逐字稿裡實際出現的是
        # 原始拼法，用淨化過的 `b` 去數會找不到（tab 被換成空白後，字串不再是
        # 逐字稿裡真的那一段），次數會被錯算成 0（2026-09-11 med-batch 端到端
        # 驗收時實測抓到，`b` 只用在顯示／判重／寫檔，不用在 `text.count`）。
        b = _sanitize_field(orig_b)
        if not b:
            continue
        # 精確比對 + 正規化比對（去空白 casefold）：《銀翼殺手 2049》要比得到 銀翼殺手2049.md
        hit = index.get(b) or nindex.get(norm_name(b))
        if hit:
            # HIGH-5（2026-09-11 紅隊）：原本這裡只是 continue，於是
            # ②「查無條目」不報它（對的，它有條目），而 ① 走的是原字串子字串比對——
            # 條目名 `銀翼殺手2049` 不是《銀翼殺手 2049》的子字串，所以 ① 也看不到它。
            # 結果是這則提及兩段都不出現、佇列也空的＝**整則蒸發**，方向跟本檔
            # 「寧可多報，不可漏報」的分寸相反。改成把命中的條目補進 ①。
            rel, tags = hit
            n_b = text.count(f"《{orig_b}》")
            prev = best.get(rel)
            if prev is None or n_b > prev[0]:
                best[rel] = (n_b, b, tags)
            continue
        # 書名可能以別名形式存在（例：《歌之版圖》vs 條目名 The Songlines），這裡抓不到就當候選，
        # 由第二段判重——第一段寧可多報，不可漏報。
        # MED-10：同一部作品的不同拼法（全形/半形空白、有無冒號全形）要收斂成一筆——
        # 正式佇列曾同時收著「復仇者聯盟 3：無限之戰」與「復仇者聯盟3：無限之戰」兩列，
        # `seen_spellings` 只擋逐字重複，這裡再用 norm_name 鍵把不同拼法併起來。
        nk = norm_name(b)
        n_b = text.count(f"《{orig_b}》")
        if nk not in book_first_seen:
            book_first_seen[nk] = b
        book_total[nk] = book_total.get(nk, 0) + n_b
    mentioned_books = [(book_total[nk], b) for nk, b in book_first_seen.items()]
    mentioned_books.sort(reverse=True)

    hit_todo, hit_done, excluded_today = split_candidates(best, edited, today)
    hit_todo.sort(reverse=True)
    hit_done.sort(reverse=True)

    lines.append(f"### ① 有條目、但今天沒掛 `{today}` tag（回填候選 {len(hit_todo)} 筆）")
    lines.append("")
    if hit_todo:
        for n, name, rel in hit_todo[:25]:
            lines.append(f"- `{rel}` — 對話中出現 {n} 次（名稱：{name}）")
        if len(hit_todo) > 25:
            lines.append(f"- …另有 {len(hit_todo) - 25} 筆未列（依出現次數排序，只列前 25）")
    else:
        lines.append("- （無）")
    lines.append("")

    lines.append(f"### ② 對話出現《書名》但查無條目（建卡候選 {len(mentioned_books)} 筆）")
    lines.append("")
    if mentioned_books:
        for n, b in mentioned_books[:15]:
            lines.append(f"- 《{b}》— 出現 {n} 次")
        if len(mentioned_books) > 15:
            lines.append(f"- …另有 {len(mentioned_books) - 15} 筆未列")
    else:
        lines.append("- （無）")
    lines.append("")

    lines.append(f"### ③ 已掛今日 tag（本日已回填 {len(hit_done)} 筆，供比對免重做）")
    lines.append("")
    if hit_done:
        lines.append("- " + "、".join(f"`{rel}`" for _, _, rel in hit_done[:20]))
    else:
        lines.append("- （無）")
    lines.append("")
    # ④ 積壓：前幾班提過、到現在都沒人收掉的（裁示 c-backfill-backlog）
    # excluded_today 併進來：今天報告版面不顯示（機械處理排除），但若真是使用者提及，
    # 積壓佇列要記住這則，不然這次提及就永久消失（見 split_candidates docstring）。
    # MED-11：label（entry 的顯示名）在這裡淨化；book 的 b 在收集迴圈裡已經淨化過，
    # 記憶體裡的鍵跟寫進佇列的鍵才會是同一個字串。
    today_rows = [(today, "entry", rel, _sanitize_field(name)) for _n, name, rel in hit_todo + excluded_today]
    today_rows += [(today, "book", b, b) for _n, b in mentioned_books]
    lock_warning = None
    try:
        merged, n_resolved, n_expired, n_cap, wrote, lock_warning, n_dupes = _update_queue(today_rows, index, today)
    except Exception as e:                     # 佇列壞掉不可以拖垮整份 handoff
        merged, n_resolved, n_expired, n_cap, wrote, n_dupes = [], 0, 0, 0, False, 0
        lines.append(f"### ④ 積壓（佇列讀寫失敗：{e}）")
        lines.append("")
        lines.append(f"- ⚠️ 這一段這次沒算——**不代表沒有積壓**，請自行看 `{_report_path(BACKLOG_PATH)}`。")
        lines.append("")
    else:
        carried = [r for r in merged if r[0] < today]
        lines.append(f"### ④ 積壓：前幾班提過、到現在沒人收（{len(carried)} 筆）")
        lines.append("")
        if carried:
            for first_seen, kind, key, label in carried[-20:]:
                what = "條目" if kind == "entry" else "建卡"
                lines.append(f"- [{first_seen} 起] {what} — `{key}`"
                             + (f"（名稱：{label}）" if kind == "entry" and label != key else ""))
            if len(carried) > 20:
                lines.append(f"- …另有 {len(carried) - 20} 筆未列（只列最舊的 20）")
        else:
            lines.append("- （無）")
        lines.append("")
        note = f"佇列 {len(merged)} 筆；本次收掉 {n_resolved} 筆（條目已被動過或建卡完成）"
        extras = []
        if n_dupes:
            # item4(c)（2026-09-11 med-fix）：MED-10 讓同一部作品的兩種拼法收斂成
            # 一列，這裡把收斂掉的列數講清楚，不然佇列列數比預期少會被誤讀成
            # 「東西不見了」。
            extras.append(f"合併同名 {n_dupes} 筆（同一部作品的不同拼法收斂成一列）")
        if n_expired:
            extras.append(f"逾 {BACKLOG_DAYS} 天而丟掉 {n_expired} 筆")
        if n_cap:
            # MED-3：路徑改印實際值（可能被 LIFEOS_ENTITY_BACKFILL_DIR 改道），不再寫死。
            # MED-8：口徑改成「永久帳本、無天數過期」，不再只講「不是丟掉」。
            extras.append(f"超過 {BACKLOG_MAX} 筆封頂而把最舊的 {n_cap} 筆"
                          f"滾進 `{_report_path(OVERFLOW_PATH)}`（不是丟掉，是永久帳本、無天數過期）")
        if extras:
            note += "，" + "；".join(extras)
        # 這行在 else: 區塊裡，上面那個 except Exception 的保護傘罩不到它。
        # MED-9：exclude 已經回到 backlog 的判重鍵，同一件事不在 backlog 與 overflow 各算一次。
        try:
            merged_keys = {_dedup_key(r[1], r[2]) for r in merged}
            n_overflow = _overflow_count(exclude=merged_keys)
        except Exception:
            n_overflow = 0
        if n_overflow:
            note += (f"。另有 {n_overflow} 筆更早的躺在 "
                     f"`{_report_path(OVERFLOW_PATH)}`（撞過 {BACKLOG_MAX} 筆封頂被擠出來的，"
                     "沒有天數過期，條目被動過或建卡完成才會被剔除）")
        if not wrote:
            note += "。⚠️ **佇列寫回失敗**，下一班會看到跟這次一樣的清單"
        if lock_warning:
            # MED-12：沒搶到佇列鎖時要在卡片上提一句，不能只留在 stderr。
            note += f"。⚠️ {lock_warning}"
        lines.append(f"> {note}。真相源＝`{_report_path(BACKLOG_PATH)}`。")
        lines.append("")

    lines.append("**已知限制**：純字串比對，不懂上下文——條目名剛好是常用詞時會誤報（已擋掉一批 stopname），"
                 "沒建過條目又沒用書名號的人物一律抓不到。②的判重只比條目名與別名，也套用在②內部——"
                 "同一部作品的兩種拼法（例：全形／半形空白、有沒有冒號）現在會收斂成一筆。"
                 "**判重正規化的射程（LOW-14，紅隊照真實 wiki 實測）**："
                 "`\\s` 在這裡是 Unicode 模式，涵蓋的不只全形空白／NBSP 三種——半形 tab／換行／回車、"
                 "NBSP（U+00A0）、U+2000 到 U+200A 一整排空白、窄不斷行空白（U+202F）、"
                 "數學中等空白（U+205F）、全形空白（U+3000）等都在射程內＋casefold，"
                 "所以《銀翼殺手 2049》比得到 銀翼殺手2049.md；"
                 "但**不**處理全形數字（２０４９）、零寬字元（U+200B，Unicode 定義它不算空白）、"
                 "間隔號 ・、連字號 -，這幾種寫法仍會被報成建卡候選；"
                 "casefold 本身還會把 Straße/Strasse、ﬁlm/film 這類連字判成同一鍵，是 Python casefold 的既有行為。"
                 "第二段仍需自行確認是否已有同義條目。"
                 "**②會把「剛被判定為捏造、已經刪掉」的假作品名報成建卡候選**（實爆過）：前一班在 wiki 條目裡抓到虛構的作品名並改掉，回報那句話寫成「《某作品甲》《某作品乙》是捏造的」——書名號照樣成立，於是這兩個不存在的作品隔天出現在建卡候選裡，看起來跟真候選一模一樣。**糾正動作本身會把錯誤餵回來**，而且愈是認真寫清楚哪裡錯，餵回來的愈完整。第二段查證時，候選若查不到可信的單一對應，先回頭搜同一份逐字稿裡這個名字出現的那句話在講什麼（關鍵詞：捏造、幻覺、查無、誤植、已改、刪掉），是糾正紀錄就直接丟棄不建卡。"
                 "①已排除兩類機械處理：本份逐字稿裡被 Edit/Write 動過的 wiki/ 檔案，"
                 "以及今天排進夜掃佇列的條目（擋工兵改的檔——子代理有自己的"
                 "逐字稿，父檔裡看不到它下的 Edit）。仍擋不到的：別條 session 自己發起的機械處理、"
                 "以及不經佇列的批次改檔，那類重複仍可能出現。"
                 "overflow 檔沒有天數過期，是永久帳本，條目被動過或建卡完成才會被剔除。"
                 "這份清單是**下限不是全部**，空清單不可推測為「今天沒東西可寫」。")

    emit(lines, args.out)
    return 0


def emit(lines, out):
    body = "\n".join(lines) + "\n"
    if out:
        import tempfile
        d = os.path.dirname(os.path.abspath(out)) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".entity-backfill-", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(body)
            os.replace(tmp, out)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    else:
        sys.stdout.write(body)


if __name__ == "__main__":
    sys.exit(main())
