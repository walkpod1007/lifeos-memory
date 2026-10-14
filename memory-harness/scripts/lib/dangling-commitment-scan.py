#!/usr/bin/env python3
"""dangling-commitment-scan.py — 跨全 transcript 掃「答應過但無完成證據」的對外交付候選

背景：session 斷氣時，「答應過的對外交付」若在快照凍結前就滾出對話視窗會蒸發
（貓照實案，見 worktickets/2026-07-18-resume-tail-scan-gap.md 第三案）。這支模組
獨立於 gen-handoff.sh 的快照流程，純機械掃描 Claude Code transcript jsonl，找出
「承諾句型（承諾框架＋對外交付動詞）比對到、但往後掃描找不到完成證據」的候選。

設計哲學（見 worktickets/2026-07-19-dangling-commitment-detection.md 背景節）：
寧可多列不可漏列——輸出定位是「候選清單，需人核對」，不是判決。

用法：
    python3 dangling-commitment-scan.py --transcript <jsonl路徑> [--cutoff <ISO時刻或unix秒/毫秒>] [--max N]

輸出：stdout 純文字，一筆一行
    [HH:MM｜候選] 截句（≤80字）——備註
零候選印「（無）」（壞行比例過高時改印「掃描不完整」警告，見下）。
任何內部錯誤 exit 非 0 且 stderr 說明（呼叫端應 fail-open：本段缺席不代表無懸空，
不得因此中斷 handoff 產生流程）。

2026-07-19 codex 紅隊修復輪（見 drafts/2026-07-19-dangling-scan-fix-report.md）：
完成判定改為「完成語素須綁定交付動詞」（不再是任意 substring 全句排除）、
否定/失敗詞排除完成證據、框架詞移出關鍵詞重疊計算、工具呼叫證據要求配對
非錯誤 tool_result、cutoff 區分 10 位秒/13 位毫秒、cutoff 啟用時無時戳 entry
不得充當完成證據、壞 jsonl 非 dict 頂層防炸、單次遍歷建索引＋檔案大小上限。
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# ── 承諾框架詞＋對外交付動詞表（檔頭常數，便於迭代）──────────────────────
PROMISE_FRAMEWORK = [
    "我來", "我去", "我會", "馬上", "收到後", "收到即", "等等", "待會",
    "晚點", "回頭", "接著", "弄好", "做好", "幫你",
    # 2026-07-19 補結果導向句型（做好後/跑完/整理完就/弄完就……通用「V完就」形）
    "完就", "做好後", "跑完", "整理完",
]
DELIVERY_VERBS = [
    "發布", "發文", "上傳", "推播", "下訂", "下單", "訂位", "預約", "送出",
    "交付", "發", "傳", "寄", "貼", "買",
    # 2026-07-19 補交付動詞（給你/提供/分享/回報/提交/部署類真實承諾常缺框架詞或用這些動詞）
    "給", "提供", "分享", "回報", "提交", "部署",
]
# 完成語素——只當「緊接在交付動詞前後、構成已完成述詞」時才算數（見 verb_has_completion_predicate），
# 不再是任意 substring 全句排除（紅隊 HIGH：「我會上傳已整理的貓照片」曾因句中含「已」被整句消音）。
RESULT_COMPLEMENTS = ["了", "好了", "完成", "成功", "搞定", "送出", "發布"]
# 否定／失敗／取消類詞——出現在候選完成證據句時，該句一律不得判完成
# （紅隊 HIGH：「上傳失敗了」「還沒有上傳成功」都曾因含「了/成功」被誤判完成）。
NEGATION_FAILURE_WORDS = ["失敗", "還沒", "沒有", "未", "取消", "卡住", "錯誤"]

PROMISE_RE = re.compile("|".join(re.escape(w) for w in PROMISE_FRAMEWORK))
VERB_RE = re.compile("|".join(re.escape(w) for w in DELIVERY_VERBS))
NEGATION_FAILURE_RE = re.compile("|".join(re.escape(w) for w in NEGATION_FAILURE_WORDS))

# 對外工具呼叫樣式（Bash 對外交付類指令；LINE MCP push/reply/flex 另在
# is_delivery_tool_call() 用名稱關鍵字判斷，不走這張表）
# 紅隊實測坑：`meta-post` 裸字串會誤中檔名如 docs/2026-07-16-meta-posting-api.md
# （Edit/Read 該文件檔就被誤判成「對外發文」），故收窄成「呼叫 meta-post-*.sh 腳本」的形狀。
DELIVERY_TOOL_PATTERNS = [
    re.compile(r"meta-post-\w+\.sh", re.I),
    re.compile(r"gog\s+send", re.I),
    re.compile(r"\bscp\b", re.I),
    re.compile(r"curl\s+(-X|--request)\s*['\"]?POST", re.I),
]

# 常見「過程狀態」通用詞 bigram——與具體交付物無關，排除以降低誤判完成
# （紅隊實測：貓照案 promise 與後續狀態回報訊息會因「授權/那邊/正在/回報」等
#  通用詞產生假重疊，導致誤判懸空承諾已完成；本清單治此）
# 2026-07-19 補：框架詞本身（我會/我來/我去）也要移出重疊計算，否則單靠框架詞
# bigram 重疊就能消掉承諾（紅隊 HIGH：需求要求至少一個「具體交付物」token 重疊）。
STOPWORD_BIGRAMS = {
    "那邊", "正在", "回報", "幫你", "你的", "我的", "弄好", "做好", "通道",
    "授權", "收尾", "已經", "還在", "一下", "一個", "這個", "那個", "可以",
    "我們", "就是", "大概", "應該", "現在", "剛剛", "直接", "自己", "還沒",
    "還是", "馬上", "處理", "開始", "完成", "好了", "搞定", "接著", "晚點",
    "回頭", "待會", "收到", "然後", "所以", "因為", "但是", "如果", "這樣",
    "那樣", "什麼", "怎麼", "為什", "沒有", "有沒",
    "我會", "我來", "我去", "給你", "提供", "分享", "提交", "部署",
}

# 壞行比例警戒線：超過此比例時，零候選不印「（無）」，改印「掃描不完整」（避免壞行
# 大量吞噬承諾/證據時，被誤讀為「真的沒有懸空」）。
BAD_LINE_RATIO_WARN = 0.1
# transcript 檔案大小上限（bytes）——超過就略過掃描並 fail-open（20s timeout 是外圈保險，
# 這裡再加一層，避免超大檔在 timeout 前就把記憶體吃爆）。
MAX_TRANSCRIPT_BYTES = 50 * 1024 * 1024


def load_entries(path):
    """讀 transcript jsonl；壞行（含合法 JSON 但頂層非 dict 的行）跳過計數不炸。
    回傳 (entries, total_lines, bad_lines)。"""
    entries = []
    total = 0
    bad = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            total += 1
            try:
                d = json.loads(line)
            except Exception:
                bad += 1
                continue
            # 2026-07-19 修：合法 JSON 但頂層是 null/[]/字串等非 dict，會讓後續 e.get(...)
            # 直接炸掉整次掃描（紅隊 MED：valid_json_non_object）。當壞行處理，不納入 entries。
            if not isinstance(d, dict):
                bad += 1
                continue
            entries.append(d)
    return entries, total, bad


def get_ts_epoch(entry):
    ts = entry.get("timestamp")
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def parse_cutoff(s):
    """接受 ISO 時刻（無時區預設視為 Asia/Taipei +08:00）或純數字 unix 時戳。
    純數字僅接受 10 位（unix 秒）或 13 位（unix 毫秒）——2026-07-19 修：舊版把任何
    ≥10 位數字都當毫秒解析，會讓 10 位的 unix 秒（如目前紀元常見長度）被錯除以 1000
    靜默解析成 1970 年附近（紅隊 MED）。位數不明確一律拒絕，讓呼叫端知道格式錯誤。"""
    if s is None:
        return None
    s = s.strip()
    if not s:
        return None
    if re.fullmatch(r"\d+", s):
        if len(s) == 13:
            return int(s) / 1000.0
        if len(s) == 10:
            return float(int(s))
        raise ValueError(
            f"--cutoff 純數字僅接受 10 位（unix 秒）或 13 位（unix 毫秒），"
            f"收到 {len(s)} 位數字，位數不明確拒絕解析：{s}"
        )
    ss = s
    if " " in ss and "T" not in ss:
        ss = ss.replace(" ", "T", 1)
    if ss.endswith("Z"):
        dt = datetime.fromisoformat(ss.replace("Z", "+00:00"))
    else:
        dt = datetime.fromisoformat(ss)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone(timedelta(hours=8)))  # 預設 TW
    return dt.timestamp()


_CLAUSE_BOUNDARY_RE = re.compile(r"[。！？\n：—→]|——")


def split_sentences(text):
    """句子/子句級擷取：以 。！？換行以及：—→（含全形冒號/破折號/箭頭）斷句
    （逗號/括號不斷，保留承諾子句內部完整性）。
    加冒號/破折號/箭頭是紅隊實測坑的治本：多主題訊息常用「A：xxx → yyy → zzz。」把不相干
    子句黏在同一個句號終結的句子裡，若只切句號會讓 A 話題的完成語素被錯記到 zzz 話題頭上
    （real case：「已給一步一動作的指引：... → 回報後我產權杖建腳本。」——「已」屬於前半句
    A 話題，不代表「產權杖建腳本」這件事完成）。"""
    parts = _CLAUSE_BOUNDARY_RE.split(text)
    return [p.strip() for p in parts if p and p.strip()]


def extract_keywords(text):
    """CJK bigram（排除通用 stopword＋框架詞）＋英數 token（長度>=3）當關鍵詞集合。
    bigram 只在連續 CJK 字元段內取，不跨標點／空白／emoji，避免拼出不相干的假 bigram。
    框架詞（我會/幫你等）與通用過程詞已併入 STOPWORD_BIGRAMS 排除，確保承諾/證據要靠
    「具體交付物」token 重疊，不能只靠框架詞本身重疊消掉候選（紅隊 HIGH）。"""
    text = re.sub(r"https?://\S+", "", text)
    kws = set()
    for run in re.findall(r"[一-鿿]+", text):
        for i in range(len(run) - 1):
            bg = run[i:i + 2]
            if bg not in STOPWORD_BIGRAMS:
                kws.add(bg)
    for tok in re.findall(r"[A-Za-z][A-Za-z0-9_]{2,}", text):
        kws.add(tok.lower())
    return kws


def verb_has_completion_predicate(sent, verb_re):
    """判斷 sent 是否含「交付動詞＋完成狀態同述詞」的完整完成判定：
    (a) 動詞前 2 字內出現「已」（如「已經上傳」「已上傳」），或
    (b) 動詞後 4 字內出現完成語素（如「上傳好了」「上傳成功了」「上傳完成」）。
    句中若含否定／失敗／取消詞（NEGATION_FAILURE_RE）→ 一律不算完成，直接回傳 False
    （紅隊 HIGH：「上傳失敗了」「還沒有上傳成功」不得被判完成）。
    這取代舊版「MORPHEME_RE.search(整句)」的任意 substring 判定——舊版會把「我會上傳
    已整理的貓照片」這種「已」修飾受詞而非動詞的句子誤判為已完成（紅隊 HIGH：self_suppressed）。
    """
    if NEGATION_FAILURE_RE.search(sent):
        return False
    for m in verb_re.finditer(sent):
        vs, ve = m.span()
        before = sent[max(0, vs - 2):vs]
        after = sent[ve:ve + 4]
        if "已" in before:
            return True
        if any(c in after for c in RESULT_COMPLEMENTS):
            return True
    return False


def assistant_texts(entry):
    """回傳該 assistant entry 裡所有「文字訊息」：純文字 block ＋
    LINE MCP reply/push/flex 的 outbound text（那才是真正送到使用者手上的承諾/回報）。"""
    msg = entry.get("message", {})
    content = msg.get("content", "")
    texts = []
    if isinstance(content, str):
        if content.strip():
            texts.append(content)
        return texts
    if not isinstance(content, list):
        return texts
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            t = b.get("text", "")
            if t and t.strip():
                texts.append(t)
        elif b.get("type") == "tool_use":
            name = (b.get("name") or "").lower()
            if "line" in name and any(k in name for k in ("reply", "push", "flex")):
                t = (b.get("input") or {}).get("text", "")
                if t and t.strip():
                    texts.append(t)
    return texts


def assistant_tool_calls(entry):
    """回傳該 assistant entry 裡所有 tool_use：(name, input 序列化字串, tool_use_id)。
    tool_use_id 供 build_tool_result_index() 配對後續 tool_result 是否成功（見規則 (b)）。"""
    msg = entry.get("message", {})
    content = msg.get("content", "")
    calls = []
    if not isinstance(content, list):
        return calls
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            name = b.get("name", "") or ""
            inp = b.get("input", {}) or {}
            tid = b.get("id")
            try:
                inp_str = json.dumps(inp, ensure_ascii=False)
            except Exception:
                inp_str = str(inp)
            calls.append((name, inp_str, tid))
    return calls


def build_tool_result_index(entries):
    """單次遍歷 entries，建立 tool_use_id -> is_error 對照表（來自 user 訊息裡的
    tool_result 區塊）。供規則 (b) 判斷對外工具呼叫是否真的成功，而非只憑呼叫本身
    （紅隊 HIGH：curl/scp/gog send 等 tool_use 一出現就被當完成，完全沒查後續
    tool_result 是否失敗/逾時/未知）。"""
    idx = {}
    for e in entries:
        if not isinstance(e, dict) or e.get("type") != "user":
            continue
        msg = e.get("message", {})
        content = msg.get("content", "")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                tid = b.get("tool_use_id")
                if tid:
                    idx[tid] = bool(b.get("is_error", False))
    return idx


def is_delivery_tool_call(name, inp_str):
    """規則 (b) 專用：只認「呼叫本身就是對外送出動作」的工具（meta-post-*.sh／gog send／
    scp／curl -X POST）。LINE MCP reply/push/flex 刻意不算在這裡——那只是「傳了一則
    訊息」，訊息內容究竟是「還要做」還是「已經做完」要靠文字本身判斷，已經在 assistant_texts()
    交給規則 (a) 處理（含完成語素才算數）。若在這裡把 reply/push 存在本身當證據，會把「我等等
    做完回報」這種還在進行式的訊息也誤判成完成證據（紅隊實測坑：fe05bf17 seq=796 promise 因此
    被 seq=808 的「然後去產 Threads 權杖、建發文腳本。弄好回報」reply 錯誤消掉）。"""
    for pat in DELIVERY_TOOL_PATTERNS:
        if pat.search(f"{name} {inp_str}"):
            return True
    return False


def _mask_spans(text, *regexes):
    """回傳把 regexes 在 text 裡所有匹配段落換成空白後的字串。
    用途：算「扣掉承諾框架詞／交付動詞本身之後，這句還剩下什麼具體內容」——
    像「弄好回報」整句拆開就只是框架詞＋動詞，沒有任何具體交付物（實測回歸坑：
    加入「回報」當交付動詞後，這種純口語應答式的短句會被當成獨立候選列出，
    但它連指的是哪件事都核對不出來，列出來只是雜訊，不是「寧可多列」該多列的東西）。
    遮罩後若整句變空，代表這句本身不含可辨識的交付物，不列為候選。"""
    chars = list(text)
    for rx in regexes:
        for m in rx.finditer(text):
            for idx in range(*m.span()):
                chars[idx] = " "
    return "".join(chars)


def build_indexes(items, tool_result_idx):
    """單次遍歷 items 建立三份索引，取代舊版「每筆承諾都重新掃一次全部後續 entry、
    重新切句/抽詞/序列化」的 O(P×N) 作法（紅隊 HIGH：超大 transcript 會逾時/OOM）。
    回傳 (promise_candidates, sentence_evidence, tool_evidence)：
    - promise_candidates: [(key, ts, sentence, kw)] 承諾句型比對到、句內未自帶完成述詞、
      扣掉框架詞/動詞後仍有具體內容
    - sentence_evidence:  [(key, ts, kw)] 含「交付動詞＋完成述詞」且無否定/失敗詞的證據句
    - tool_evidence:      [(key, ts, kw)] 對外工具呼叫且配對到非錯誤 tool_result 的證據
    key = (i, corder)：i 是 transcript 原始 entry 順序，corder 是同一則訊息內部的子句/
    工具呼叫順序（同一則訊息常見「A 已完成：... → B 還在做」這種話題在句號/箭頭邊界
    切開的寫法，若只比較 i 會讓同一則訊息裡「稍後子句」的完成證據永遠比不到「稍前子句」
    的承諾——2026-07-19 回歸測試踩到：懸空掃描器自身的說明文字「收到即發
    →真發了」被切成兩個子句，完成語素「了」落在下一個子句，若不比 corder 就會被
    誤判成懸空候選）。三者皆依 (i, corder) 遞增排列，供 Pass2 直接線性掃描比對。
    """
    promise_candidates = []
    sentence_evidence = []
    tool_evidence = []
    for i, ts, e in items:
        if not isinstance(e, dict) or e.get("type") != "assistant":
            continue
        corder = 0
        for t in assistant_texts(e):
            for sent in split_sentences(t):
                key = (i, corder)
                corder += 1
                has_completion = verb_has_completion_predicate(sent, VERB_RE)
                if has_completion:
                    sentence_evidence.append((key, ts, extract_keywords(sent)))
                    continue  # 同句已判完成，不重複當承諾候選
                if PROMISE_RE.search(sent) and VERB_RE.search(sent):
                    masked_kw = extract_keywords(_mask_spans(sent, PROMISE_RE, VERB_RE))
                    if not masked_kw:
                        continue  # 扣掉框架詞/動詞後無具體交付物內容，過雜訊不列
                    promise_candidates.append((key, ts, sent, masked_kw))
        for name, inp_str, tid in assistant_tool_calls(e):
            key = (i, corder)
            corder += 1
            if not is_delivery_tool_call(name, inp_str):
                continue
            # 規則 (b) 修：tool_use 本身不算數，須配對到後續 tool_result 且非 is_error
            # （紅隊 HIGH：找不到對應 result 或 result 帶 error 時不得清除候選）。
            verified = tid is not None and tid in tool_result_idx and not tool_result_idx[tid]
            if verified:
                tool_evidence.append((key, ts, extract_keywords(inp_str)))
    return promise_candidates, sentence_evidence, tool_evidence


def _evidence_found_after(pkey, kw, evidence_list, cutoff_active):
    for key, ts, ekw in evidence_list:
        if key <= pkey:
            continue
        # 2026-07-19 修：cutoff 啟用時，無時戳／壞時戳 entry 不得充當完成證據——它可能
        # 實際發生在 cutoff 之後，卻因缺時戳而混進「往前看」的證據池，錯誤消掉本該保留
        # 的候選（紅隊 MED：unknown_ts_after_cutoff）。未啟用 cutoff 時不受此限。
        if cutoff_active and ts is None:
            continue
        if kw and ekw and (kw & ekw):
            return True
    return False


def scan(path, cutoff_epoch, max_n):
    entries, total, bad = load_entries(path)

    items = []  # (seq, ts_epoch, entry)
    for i, e in enumerate(entries):
        # 防禦性檢查：即使呼叫端繞過 load_entries 直接餵非 dict entries（如測試 harness
        # monkeypatch），也不得炸掉（紅隊 MED：valid_json_non_object）。
        if not isinstance(e, dict):
            bad += 1
            continue
        ts = get_ts_epoch(e)
        # cutoff 邊界改為排他（timestamp >= cutoff 即排除），對齊 docstring「此時刻前」
        # 的字面意思（紅隊 LOW）。
        if cutoff_epoch is not None and ts is not None and ts >= cutoff_epoch:
            continue
        items.append((i, ts, e))

    tool_result_idx = build_tool_result_index(entries)
    promise_candidates, sentence_evidence, tool_evidence = build_indexes(items, tool_result_idx)

    cutoff_active = cutoff_epoch is not None
    candidates = []
    for (pkey, pts, sent, kw) in promise_candidates:
        # pkey = (i, corder)；tuple 比較/排序天然依 (entry 順序, 同訊息內子句順序) 遞增。
        found = _evidence_found_after(pkey, kw, sentence_evidence, cutoff_active) or \
            _evidence_found_after(pkey, kw, tool_evidence, cutoff_active)
        if not found:
            candidates.append((pkey, pts, sent))

    # 上限截取取「最靠近 cutoff（最新）」的 N 筆——越接近快照時刻的懸空承諾越可能還活著、
    # 越該被下一班接住；久遠的候選被截掉時，多半早已被後續對話用非機械可辨的方式處理掉。
    candidates.sort(key=lambda c: c[0], reverse=True)
    candidates = candidates[:max_n]
    candidates.sort(key=lambda c: c[0])
    return candidates, total, bad


def fmt_tw(epoch):
    if epoch is None:
        return "--:--"
    dt = datetime.fromtimestamp(epoch, tz=timezone(timedelta(hours=8)))
    return dt.strftime("%H:%M")


def truncate80(s):
    s = s.strip()
    if len(s) <= 80:
        return s
    return s[:79] + "…"


def main():
    ap = argparse.ArgumentParser(description="掃 transcript 找懸空對外交付承諾候選")
    ap.add_argument("--transcript", required=True, help="Claude Code transcript jsonl 路徑")
    ap.add_argument("--cutoff", default=None, help="ISO 時刻或 unix 秒(10位)/毫秒(13位)；只列此時刻前的承諾")
    ap.add_argument("--max", type=int, default=5, help="候選上限（預設 5）")
    args = ap.parse_args()

    try:
        cutoff_epoch = parse_cutoff(args.cutoff)
    except Exception as e:
        print(f"[dangling-scan] --cutoff 解析失敗：{type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)

    # 檔案大小上限：超大 transcript 在切句/建索引前就先擋下，避免記憶體爆掉
    # （紅隊 HIGH 效能 finding 的另一半解法；主解法是下面 build_indexes 的單次遍歷）。
    try:
        size = os.path.getsize(args.transcript)
    except FileNotFoundError as e:
        print(f"[dangling-scan] transcript 找不到：{e}", file=sys.stderr)
        sys.exit(3)
    except OSError as e:
        print(f"[dangling-scan] transcript 存取失敗：{type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(3)

    if size > MAX_TRANSCRIPT_BYTES:
        print(
            f"[dangling-scan] transcript 過大（{size / 1024 / 1024:.1f}MB > "
            f"{MAX_TRANSCRIPT_BYTES / 1024 / 1024:.0f}MB 上限），略過懸空掃描",
            file=sys.stderr,
        )
        print("⚠️ 掃描略過（transcript 過大），本段缺席不代表無懸空")
        sys.exit(5)

    try:
        candidates, total, bad = scan(args.transcript, cutoff_epoch, args.max)
    except FileNotFoundError as e:
        print(f"[dangling-scan] transcript 找不到：{e}", file=sys.stderr)
        sys.exit(3)
    except Exception as e:
        print(f"[dangling-scan] 掃描失敗：{type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)

    incomplete = False
    if bad > 0:
        print(f"[dangling-scan] 跳過 {bad}/{total} 壞行（不影響其餘掃描）", file=sys.stderr)
        if total > 0 and (bad / total) > BAD_LINE_RATIO_WARN:
            incomplete = True
            print(f"[dangling-scan] 壞行比例過高（{bad}/{total}），候選清單可能不完整", file=sys.stderr)

    if not candidates:
        if incomplete:
            # 2026-07-19 修：壞行比例過高時零候選不能只印「（無）」——那會被誤讀成
            # 「機械掃描過、確定沒有懸空」，實際上是「掃描本身不完整」（紅隊 MED）。
            print("⚠️ 掃描不完整（壞行比例過高，候選清單可能有缺漏，不代表無懸空）")
        else:
            print("（無）")
        return

    if incomplete:
        print("⚠️ 掃描不完整（壞行比例過高，以下候選清單可能有缺漏）")
    for (seq, ts, sent) in candidates:
        print(f"[{fmt_tw(ts)}｜候選] {truncate80(sent)} ——承諾句型比對到（承諾框架＋對外交付動詞），"
              f"往後掃描 transcript 未見完成語素或對外工具呼叫佐證")


if __name__ == "__main__":
    main()
