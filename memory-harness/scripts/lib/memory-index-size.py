#!/usr/bin/env python3
"""量一份 MEMORY.md 有沒有超過 Claude Code 的注入上限。

輸出一行：`<lines> <units> <line_trunc> <char_trunc>`（空白分隔，後兩欄 0/1）。

**上限的真正形狀**（由 Claude Code CLI 二進位反查 + 實測探針雙向確認）：
CLI 內部函式 `Mzr()` 先把內容 trim，再算兩個量——
  lineCount = 換行數 + 1        上限 Une = 200
  byteCount = 字串的 .length     上限 Lme = 25000
關鍵在第二個：那是 **JavaScript 字串長度（UTF-16 code unit）**，不是 UTF-8 位元組。
一個中文字在 UTF-8 是 3 bytes，在這裡只算 **1**；BMP 外的字（多數 emoji）算 2。
所以中文索引用 `wc -c` 去量會**虛報約三倍**——這正是一次誤判
「某份中文索引 32,395 bytes 超標 127%、33 張卡會蒸發」的成因，實際是 19,193 units，
離上限還有兩成空間。

另一個被同時更正的說法：超限**不是完全靜默**。`Mzr()` 截斷後會在內容尾端補一行
`> WARNING: MEMORY.md is …. Only part of it was loaded.`，注入進 session 看得到。
看不到的是「哪幾張卡被切掉」——警告只講有截斷，不講截掉什麼。

實測憑據（探針：250 行 × 187 字/行的合成索引，走 claude -p 問它看到幾行）：
回報 first=001 last=132 count=132；25000 ÷ 188 = 132.9 → 132 行，與預測完全吻合。
"""
import sys

LINE_LIMIT = 200
UNIT_LIMIT = 25000


def measure(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read().strip()
    if not text:
        return 0, 0
    lines = text.count("\n") + 1
    units = sum(2 if ord(c) > 0xFFFF else 1 for c in text)
    return lines, units


def main():
    if len(sys.argv) != 2:
        print("usage: memory-index-size.py <MEMORY.md>", file=sys.stderr)
        return 2
    lines, units = measure(sys.argv[1])
    print(f"{lines} {units} {int(lines > LINE_LIMIT)} {int(units > UNIT_LIMIT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
