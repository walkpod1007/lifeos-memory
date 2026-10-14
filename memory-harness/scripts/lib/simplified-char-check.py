#!/usr/bin/env python3
"""偵測簡體字。刻意只收「正體中文不會用到」的字，避開兩邊都合法的：
后（皇后）游（游泳）着（著手的異體）干（干戈）发→髮/發 系→係/繫 历 里（公里）。
寧可漏報也不要誤報——誤報會讓這道閘被當成雜訊拔掉。"""
import sys
SIMP = set("帐录进认识权证项启动时间应频轨选条个实验无误号扫对单继续维护断点据库计划当图径击关够这两产户执变显马戏疯丛蛮约风级页题该处务样论证读书随觉视听语讲话说词语议论认识识别间题际专业务处认")
def scan(text):
    hits = {}
    for ch in text:
        if ch in SIMP:
            hits[ch] = hits.get(ch, 0) + 1
    return hits
if __name__ == "__main__":
    data = open(sys.argv[1], encoding="utf-8", errors="replace").read() if len(sys.argv) > 1 else sys.stdin.read()
    h = scan(data)
    if h:
        top = " ".join(f"{k}×{v}" for k, v in sorted(h.items(), key=lambda x: -x[1])[:12])
        print(f"SIMPLIFIED_FOUND count={sum(h.values())} kinds={len(h)} top={top}")
        sys.exit(1)
    print("SIMPLIFIED_NONE")
