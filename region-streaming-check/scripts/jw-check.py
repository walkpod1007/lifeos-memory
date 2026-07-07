#!/usr/bin/env python3
"""region-streaming-check 查詢引擎：用 JustWatch 未文件化但可用的 GraphQL endpoint（免 key）
查一部片在多國的串流上架狀況。JustWatch 結果本身就含 Apple TV Store / MUBI / Netflix 等所有平台。

用法:
  jw-check.py "<片名>" [國家碼,逗號]        # 每國最佳命中 + 平台 + URL（片名不歧義時用）
  jw-check.py --list "<片名>" [國家碼]       # 列前 6 筆候選（片名/年份/類型/URL），消歧用
例:
  jw-check.py "Inception" TW,JP,US
  jw-check.py --list "怪談" JP
查不到就誠實回報，不編造。一次最多查 ~10 國，避免高頻打 endpoint。"""
import sys, re, json, urllib.request, urllib.error

ENDPOINT = "https://apis.justwatch.com/graphql"
MAX_COUNTRIES = 10
OFFER_FIELDS = "monetizationType standardWebURL package { clearName }"
def _q(first):
    return ("query S($country: Country!, $q: String!, $language: Language!) {"
            f"  popularTitles(country: $country, filter: {{searchQuery: $q}}, first: {first}) {{"
            "    edges { node { ... on MovieOrShow { objectType"
            "      content(country: $country, language: $language) { title originalReleaseYear fullPath }"
            f"      offers(country: $country, platform: WEB) {{ {OFFER_FIELDS} }} }} }} }} }} }}")
MON = {"FLATRATE":"放題","FLATRATE_AND_BUY":"放題/購","RENT":"租","BUY":"購買",
       "ADS":"含廣告免費","FREE":"免費","CINEMA":"院線","UNKNOWN":"未知"}
TYPE = {"MOVIE":"電影","SHOW":"影集","GENERIC":""}
LANG = {"TW":"zh","HK":"zh","CN":"zh","JP":"ja","KR":"ko"}

def _call(query, country, q, language):
    body = json.dumps({"query":query,"variables":{"country":country,"q":q,"language":language}}).encode()
    req = urllib.request.Request(ENDPOINT, data=body,
        headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return None, f"網路錯誤({getattr(e,'reason','')})"
    except Exception as e:
        return None, type(e).__name__
    if d.get("errors"):
        return None, "API 回錯（國碼或 schema 問題，非『查無此片』）"
    return (d.get("data") or {}).get("popularTitles",{}).get("edges") or [], None

def _node_info(node):
    c = node.get("content") or {}
    offers = {}
    for o in (node.get("offers") or []):
        pkg = (o or {}).get("package") or {}
        name = pkg.get("clearName")
        if name:
            offers.setdefault((name, (o or {}).get("monetizationType") or "UNKNOWN"), (o or {}).get("standardWebURL"))
    fp = c.get("fullPath") or ""
    return {"title":c.get("title"),"year":c.get("originalReleaseYear"),
            "type":node.get("objectType"),"page":("https://www.justwatch.com"+fp) if fp else None,
            "offers":offers}

def cmd_list(title, country, language):
    edges, err = _call(_q(6), country, title, language)
    print(f"🔎 候選（{country}）: {title}")
    if err: print(f"⚠️ {err}"); return
    if not edges: print("（無命中）"); return
    for e in edges:
        n = _node_info((e or {}).get("node") or {})
        t = TYPE.get(n["type"], n["type"] or "")
        plats = "、".join(f"{p}（{MON.get(m,m)}）" for (p,m) in list(n["offers"])[:5]) or "無上架"
        print(f" • 〔{n['title']} {n['year']} {t}〕 {plats}")
        if n["page"]: print(f"   🔗 {n['page']}")

def cmd_check(title, countries):
    print(f"🎬 {title}")
    any_found, rate = False, False
    for ctry in countries:
        if not re.match(r"^[A-Z]{2}$", ctry):
            print(f"⚠️ {ctry}: 無效國家碼（要 ISO 2 碼，如 TW/JP/US）"); continue
        edges, err = _call(_q(1), ctry, title, LANG.get(ctry,"en"))
        if err:
            print(f"⚠️ {ctry}: 查詢失敗（{err}）"); rate = rate or err.startswith("HTTP 4"); continue
        if not edges:
            print(f"❌ {ctry}: 查不到此片"); continue
        n = _node_info((edges[0] or {}).get("node") or {})
        if not n["offers"]:
            line = f"❌ {ctry}: 查到片但無串流上架〔{n['title']} {n['year']}〕"
        else:
            any_found = True
            plats = "、".join(f"{p}（{MON.get(m,m)}）" for (p,m) in list(n["offers"])[:8])
            line = f"✅ {ctry}: {plats}  〔{n['title']} {n['year']}〕"
        if n["page"]: line += f"\n   🔗 {n['page']}"
        print(line)
    if rate:
        print("（JustWatch 回 4xx，可能被限流；停一下或改 WebSearch site:justwatch.com）")
    elif not any_found:
        print("（查不到不代表絕對沒有；可 --list 列候選，或 WebSearch `site:justwatch.com <片名> <國>` 確認）")

def main():
    a = sys.argv[1:]
    if a and a[0] == "--list":
        if len(a) < 2 or not a[1].strip(): print("usage: jw-check.py --list '<title>' [country]"); sys.exit(2)
        ctry = (a[2].strip().upper() if len(a) > 2 and a[2].strip() else "US")
        cmd_list(a[1], ctry, LANG.get(ctry,"en")); return
    if not a or not a[0].strip(): print("usage: jw-check.py '<title>' [TW,JP,US]"); sys.exit(2)
    countries = a[1].split(",") if len(a) > 1 else ["TW","JP","US"]
    countries = [c.strip().upper() for c in countries if c.strip()][:MAX_COUNTRIES]
    cmd_check(a[0], countries)

if __name__ == "__main__":
    main()
