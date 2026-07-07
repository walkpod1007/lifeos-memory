#!/usr/bin/env python3
"""region-streaming-check 第二平台源：YouTube 搜尋（用本機 yt-dlp，免 API key）。
JustWatch 只收授權串流（Netflix/Disney+/MUBI…），查不到的 YouTube 原生內容
（網路怪談/錄影帶都市傳說/紀錄片/個人頻道劇集）就靠這層補。只回報「哪裡看」＝
列出 YouTube 上的官方公開影片連結，不下載、不播放、不碰盜版。

用法:
  yt-search.py "<關鍵字>" [N]          # 搜 YouTube 前 N 筆（預設 5）
例:
  yt-search.py "電視台錄影帶怪談"
  yt-search.py "Vault 錄影帶 怪談" 8
查不到就誠實回報，不編造。"""
import sys, json, subprocess

MAX_N = 15

def search(query, n):
    # --flat-playlist：只取清單 metadata，不解析每支影片（快、免登入、免 key）
    cmd = ["yt-dlp", "--flat-playlist", "--no-warnings", "--ignore-errors",
           "--dump-json", f"ytsearch{n}:{query}"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return None, "yt-dlp 未安裝（brew install yt-dlp）"
    except subprocess.TimeoutExpired:
        return None, "yt-dlp 逾時"
    rows = []
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        vid = d.get("id")
        rows.append({
            "title": d.get("title") or "(無標題)",
            "uploader": d.get("uploader") or d.get("channel") or "?",
            "dur": d.get("duration_string") or _fmt_dur(d.get("duration")),
            "url": f"https://youtu.be/{vid}" if vid else (d.get("url") or ""),
        })
    if not rows and p.returncode != 0:
        return None, (p.stderr.strip().splitlines()[-1] if p.stderr.strip() else f"yt-dlp 失敗(rc={p.returncode})")
    return rows, None

def _fmt_dur(sec):
    if not sec:
        return ""
    sec = int(sec)
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"

def main():
    a = sys.argv[1:]
    if not a or not a[0].strip():
        print("usage: yt-search.py '<關鍵字>' [N]"); sys.exit(2)
    query = a[0]
    try:
        n = min(int(a[1]), MAX_N) if len(a) > 1 else 5
    except ValueError:
        n = 5
    print(f"📺 YouTube 搜尋: {query}")
    rows, err = search(query, n)
    if err:
        print(f"⚠️ {err}"); sys.exit(1)
    if not rows:
        print("（查不到，可換關鍵字或頻道名再試；不代表 YouTube 上絕對沒有）"); return
    for r in rows:
        dur = f"｜{r['dur']}" if r["dur"] else ""
        print(f" • {r['title']}（{r['uploader']}{dur}）")
        if r["url"]:
            print(f"   🔗 {r['url']}")

if __name__ == "__main__":
    main()
