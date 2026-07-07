#!/usr/bin/env python3
"""
token-watchdog-patch.py — 為新 Tier 1 LINE slug 補 token-watchdog.sh 的 5 處 case

Usage:
    python3 token-watchdog-patch.py <slug>

幂等：重跑會跳過已補過的 case，不 double insert。
"""
import sys
from pathlib import Path


WD_PATH = Path.home() / "life-os/scripts/token-watchdog.sh"


def patch(slug: str) -> dict:
    if not slug or not slug.replace("-", "").isalnum():
        raise ValueError(f"invalid slug: {slug!r}")

    session = f"claude-line-{slug}"
    content = WD_PATH.read_text()
    results: dict[str, str] = {}

    # 處 2：LOG 路徑（在 claude-line-note 行後插入）
    anchor_log = '  claude-line-note) LOG="$HOME/.claude/claude-line-note.log" ;;'
    new_log = f'  {session}) LOG="$HOME/.claude/{session}.log" ;;'
    if new_log in content:
        results["LOG"] = "skip (已存在)"
    elif anchor_log in content:
        content = content.replace(anchor_log, f"{anchor_log}\n{new_log}", 1)
        results["LOG"] = "added"
    else:
        results["LOG"] = "ERROR: anchor 未找到"

    # 處 3：WS_SUFFIX（在 claude-line-talk 行後插入）—— 這是最關鍵的 case
    anchor_ws = '  claude-line-talk) WS_SUFFIX="ws-line-talk" ;;'
    new_ws = f'  {session}) WS_SUFFIX="ws-line-{slug}" ;;'
    if new_ws in content:
        results["WS_SUFFIX"] = "skip (已存在)"
    elif anchor_ws in content:
        content = content.replace(anchor_ws, f"{anchor_ws}\n{new_ws}", 1)
        results["WS_SUFFIX"] = "added"
    else:
        results["WS_SUFFIX"] = "ERROR: anchor 未找到"

    # 處 4：HEALTH_QUEUE（在 claude-line-talk HEALTH_QUEUE 行後插入）
    anchor_hq = (
        '  claude-line-talk) HEALTH_QUEUE="$HOME/.claude/channels/line/runtime/'
        'line-lobster-queue-line-talk.jsonl" ;;'
    )
    new_hq = (
        f'  {session}) HEALTH_QUEUE="$HOME/.claude/channels/line/runtime/'
        f'line-lobster-queue-line-{slug}.jsonl" ;;'
    )
    if new_hq in content:
        results["HEALTH_QUEUE"] = "skip (已存在)"
    elif anchor_hq in content:
        content = content.replace(anchor_hq, f"{anchor_hq}\n{new_hq}", 1)
        results["HEALTH_QUEUE"] = "added"
    else:
        results["HEALTH_QUEUE"] = "ERROR: anchor 未找到"

    # 處 5a：HEALTH_TRIGGER（擴展 pipe 串）
    # 支援多輪 retrofit：pipe 串可能已擴展過，用「是否含 session 字樣」判斷冪等
    ht_base = "claude-line|claude-line-note|claude-line-talk"
    ht_marker = f"|{session}) HEALTH_TRIGGER="
    if ht_marker in content:
        results["HEALTH_TRIGGER"] = "skip (已存在)"
    else:
        # 找現有 HEALTH_TRIGGER pipe 串行頭，在最後 ) 前插入 |session
        old = f"{ht_base}"
        # 若先前已加過別的 slug，當前 pattern 可能已變：要 match 到「任何結尾 ) HEALTH_TRIGGER=」的那行
        import re
        pattern = re.compile(r"(claude-line(?:\|claude-line-[\w-]+)*)\) HEALTH_TRIGGER=")
        m = pattern.search(content)
        if m:
            existing = m.group(1)
            new_line_prefix = f"{existing}|{session}) HEALTH_TRIGGER="
            old_line_prefix = f"{existing}) HEALTH_TRIGGER="
            content = content.replace(old_line_prefix, new_line_prefix, 1)
            results["HEALTH_TRIGGER"] = "added"
        else:
            results["HEALTH_TRIGGER"] = "ERROR: pattern 未找到"

    # 處 5b：MCP_BINARY（擴展 pipe 串，同 5a 邏輯）
    mb_marker = f"|{session}) MCP_BINARY="
    if mb_marker in content:
        results["MCP_BINARY"] = "skip (已存在)"
    else:
        import re
        pattern = re.compile(r"(claude-line(?:\|claude-line-[\w-]+)*)\) MCP_BINARY=")
        m = pattern.search(content)
        if m:
            existing = m.group(1)
            new_line_prefix = f"{existing}|{session}) MCP_BINARY="
            old_line_prefix = f"{existing}) MCP_BINARY="
            content = content.replace(old_line_prefix, new_line_prefix, 1)
            results["MCP_BINARY"] = "added"
        else:
            results["MCP_BINARY"] = "ERROR: pattern 未找到"

    WD_PATH.write_text(content)
    return results


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 token-watchdog-patch.py <slug>", file=sys.stderr)
        return 1
    slug = sys.argv[1]
    try:
        results = patch(slug)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    print(f"token-watchdog.sh patch for slug={slug!r}:")
    for case_name, status in results.items():
        print(f"  {case_name}: {status}")

    has_error = any("ERROR" in s for s in results.values())
    return 3 if has_error else 0


if __name__ == "__main__":
    sys.exit(main())
