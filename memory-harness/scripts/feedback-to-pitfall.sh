#!/usr/bin/env bash
# feedback-to-pitfall.sh — 把 Claude Code auto memory 裡的 feedback 檔「升格」成坑卡
#
# Claude Code 的 auto memory 會把使用者的糾正存成 `type: feedback` 的小檔。
# 這些檔散在 auto memory 目錄、沒有索引、不可回搜——本腳本把它們收進記憶卡系統：
#   1. 在 $MEMORY_ROOT/cards/pitfall/<name>.md 建坑卡（格式見 memory-cards/SKILL.md）
#   2. 在 $MEMORY_ROOT/MEMORY.md 加一行索引（一卡一行）
#   3. （選配）LIFEOS_SOUL_FILE 有設的話，在該檔最後一條 `- **…**` 列點後追加一行摘要
#   4. 從 auto memory 的 MEMORY.md 移除該 feedback 檔的索引行
#   5. 刪除原始 feedback 檔（轉換成功才刪；坑卡已存在則跳過、不刪、不覆寫）
#
# 用法：
#   bash feedback-to-pitfall.sh              # 轉換並刪除原檔
#   bash feedback-to-pitfall.sh --dry-run    # 只印會做什麼，不動任何檔案
#
# 設定（環境變數，皆有預設）：
#   LIFEOS_MEMORY_ROOT    記憶根目錄，預設 ~/lifeos-memory
#   CLAUDE_HOME           Claude Code 設定目錄，預設 ~/.claude
#   LIFEOS_FEEDBACK_DIR   feedback 檔所在目錄（auto memory 目錄）。
#                         預設：$CLAUDE_HOME/projects/<目前目錄的 cwd key>/memory
#                         （cwd key＝絕對路徑把 / 與 . 換成 -）
#   LIFEOS_SOUL_FILE      （選配）要追加踩坑摘要的規則檔（例如你的常駐 CLAUDE.md）；沒設就略過這步

set -euo pipefail

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) echo "未知參數：$a（可用 --dry-run）" >&2; exit 1 ;;
  esac
done

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_ROOT="${LIFEOS_MEMORY_ROOT:-$HOME/lifeos-memory}"
if [ -z "${LIFEOS_FEEDBACK_DIR:-}" ]; then
  _key=$(printf '%s' "$PWD" | sed 's#[/.]#-#g')
  LIFEOS_FEEDBACK_DIR="$CLAUDE_HOME/projects/${_key}/memory"
fi
FEEDBACK_DIR="$LIFEOS_FEEDBACK_DIR"
FEEDBACK_INDEX="$FEEDBACK_DIR/MEMORY.md"
PITFALL_DIR="$MEMORY_ROOT/cards/pitfall"
CARD_INDEX="$MEMORY_ROOT/MEMORY.md"
SOUL="${LIFEOS_SOUL_FILE:-}"
TODAY=$(date +%Y-%m-%d)

if [ ! -d "$FEEDBACK_DIR" ]; then
  echo "資料源不存在，跳過：$FEEDBACK_DIR（沒有 auto memory 的 feedback 檔可轉；可用 LIFEOS_FEEDBACK_DIR 指定）"
  exit 0
fi
[ "$DRY" -eq 1 ] || mkdir -p "$PITFALL_DIR"

converted=0
for f in "$FEEDBACK_DIR"/feedback_*.md; do
  [ -f "$f" ] || continue
  grep -q "^type: feedback" "$f" || continue

  name=$(awk '/^name:/{$1=""; print substr($0,2); exit}' "$f")
  description=$(awk '/^description:/{$1=""; print substr($0,2); exit}' "$f")
  [ -n "$name" ] || { echo "SKIP: 缺 name 欄位：$f"; continue; }
  # 檔名安全：name 只准留字母數字底線連字號與 CJK；其餘換成 -（防 ../ 與空白）
  slug=$(printf '%s' "$name" | sed 's#[^A-Za-z0-9_一-鿿-]#-#g')

  body=$(awk 'BEGIN{in_fm=0; past_fm=0} /^---$/{if(!in_fm){in_fm=1;next}else{past_fm=1;next}} past_fm{print}' "$f")
  # 第一個非空行當摘要。用 awk NR 不用 head：head -1 提早收工會讓上游 grep 吃 SIGPIPE(141)，
  # pipefail + set -e 會靜靜中止整支；awk 把輸入讀完，取值相同。
  summary=$(printf '%s\n' "$body" | grep -v '^\s*$' | awk 'NR<=1' | sed 's/\*\*//g' || true)
  [ -n "$description" ] || description="$summary"

  pitfall_file="$PITFALL_DIR/${slug}.md"
  if [ -f "$pitfall_file" ]; then
    echo "SKIP: 坑卡已存在：$pitfall_file"
    continue
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "DRY: 會建 $pitfall_file、加索引、刪 $f"
    converted=$((converted + 1))
    continue
  fi

  cat > "$pitfall_file" <<CARD
---
name: ${slug}
description: ${description}
type: pitfall
category: dialogue
created: ${TODAY}
last_hit: ${TODAY}
hit_count: 1
---

**坑**：${summary}

**根因**：（由 feedback 自動升格，請補一兩句機制）

**下次怎麼避**：（請補具體可執行的做法）
CARD
  echo "CREATED: $pitfall_file"

  # 索引：MEMORY.md 只放一行鉤子
  if [ -f "$CARD_INDEX" ] && ! grep -qF "cards/pitfall/${slug}.md" "$CARD_INDEX"; then
    printf -- '- [%s](cards/pitfall/%s.md) — %s\n' "$slug" "$slug" "$description" >> "$CARD_INDEX"
    echo "INDEX: 已加到 $CARD_INDEX"
  fi

  # 選配：規則檔追加一行摘要
  if [ -n "$SOUL" ] && [ -f "$SOUL" ] && ! grep -qF "$name" "$SOUL"; then
    last_bullet=$(grep -n '^- \*\*' "$SOUL" | tail -1 | cut -d: -f1 || true)
    if [ -n "$last_bullet" ]; then
      newline="- **${name}**：${summary}"
      # macOS sed 的 a 指令需要字面換行
      sed -i.bak "${last_bullet}a\\
${newline}
" "$SOUL" && rm -f "$SOUL.bak"
      echo "SOUL: 已在 L${last_bullet} 之後追加一行"
    fi
  fi

  # 從 auto memory 索引移除該 feedback 檔
  basename_f=$(basename "$f")
  if [ -f "$FEEDBACK_INDEX" ] && grep -qF "$basename_f" "$FEEDBACK_INDEX"; then
    grep -vF "$basename_f" "$FEEDBACK_INDEX" > "$FEEDBACK_INDEX.tmp" || true
    mv "$FEEDBACK_INDEX.tmp" "$FEEDBACK_INDEX"
    echo "FEEDBACK-INDEX: 已移除 $basename_f 的索引行"
  fi

  rm "$f"
  echo "DELETED: $f"
  converted=$((converted + 1))
done

echo "Done. Converted ${converted} feedback file(s)."
