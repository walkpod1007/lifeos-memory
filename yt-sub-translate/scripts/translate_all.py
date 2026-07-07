#!/usr/bin/env python3
"""Translate a .srt file into multiple languages. Outputs <lang>.srt files beside the source.

Uses claude CLI for auth (no ANTHROPIC_API_KEY needed in env).
"""
import re, json, sys, os, subprocess

LANG_NAMES = {
    "ko": "韓文（Korean）",
    "ja": "日文（Japanese）",
    "en": "英文（English）",
    "th": "泰文（Thai）",
    "zh-TW": "繁體中文（Traditional Chinese）",
}

CLAUDE_BIN = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

def parse_srt(path):
    content = open(path, encoding="utf-8-sig").read()
    blocks = re.split(r'\n\n+', content.strip())
    result = []
    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:
            continue
        result.append((lines[0].strip(), lines[1].strip(), '\n'.join(lines[2:])))
    return result

def write_srt(segments, path):
    with open(path, 'w', encoding="utf-8") as f:
        for idx, tc, txt in segments:
            f.write(f"{idx}\n{tc}\n{txt}\n\n")

def translate_batch(texts, target_lang):
    lang_name = LANG_NAMES.get(target_lang, target_lang)
    prompt = (
        f"以下是字幕文字清單（JSON 陣列）。\n"
        f"請將每一條翻譯為{lang_name}，保持簡潔（字幕限制），"
        f"回傳相同長度的 JSON 陣列。只回傳 JSON，不加說明、不加 markdown。\n\n"
        f"{json.dumps(texts, ensure_ascii=False)}"
    )
    result = subprocess.run(
        [CLAUDE_BIN, "-p", prompt, "--print", "--model", "claude-haiku-4-5-20251001"],
        capture_output=True, text=True, timeout=120
    )
    raw = result.stdout.strip()
    if raw.startswith("```"):
        raw = re.sub(r'^```[a-z]*\n?', '', raw)
        raw = re.sub(r'\n?```$', '', raw)
    return json.loads(raw)

def translate_srt(segments, target_lang):
    texts = [txt for _, _, txt in segments]
    translated = []
    for i in range(0, len(texts), 60):
        batch = texts[i:i+60]
        print(f"  批次 {i//60+1} ({len(batch)} 條)...", flush=True)
        translated.extend(translate_batch(batch, target_lang))
    return [(idx, tc, tr) for (idx, tc, _), tr in zip(segments, translated)]

def main():
    if len(sys.argv) < 3:
        print("用法: translate_all.py <source.srt> <lang1> [lang2] ...")
        print("例：translate_all.py source.srt ko ja en th")
        sys.exit(1)

    srt_path = sys.argv[1]
    langs = sys.argv[2:]
    out_dir = os.path.dirname(os.path.abspath(srt_path))

    print(f"解析字幕：{srt_path}")
    segments = parse_srt(srt_path)
    print(f"共 {len(segments)} 條字幕\n")

    for lang in langs:
        print(f"翻譯語言：{lang}")
        translated = translate_srt(segments, lang)
        out_path = os.path.join(out_dir, f"{lang}.srt")
        write_srt(translated, out_path)
        print(f"✅ 輸出：{out_path}\n")

    print(f"全部完成。輸出目錄：{out_dir}")

if __name__ == "__main__":
    main()
