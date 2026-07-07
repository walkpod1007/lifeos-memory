#!/bin/bash
# honto-ocr-batch.sh — Batch OCR screenshots to text using tesseract jpn_vert
# Usage: bash honto-ocr-batch.sh <slug>

set -euo pipefail

SLUG="${1:?Usage: bash honto-ocr-batch.sh <slug>}"
RAW_DIR="/tmp/kindle-translate/${SLUG}/raw"
TEXT_DIR="/tmp/kindle-translate/${SLUG}/ocr"

if [ ! -d "$RAW_DIR" ]; then
  echo "ERROR: $RAW_DIR not found"
  exit 1
fi

mkdir -p "$TEXT_DIR"

PAGE_COUNT=$(ls "$RAW_DIR"/page-*.png 2>/dev/null | wc -l | tr -d ' ')
echo "=== OCR Batch Start ==="
echo "  Pages: $PAGE_COUNT"
echo "  Input: $RAW_DIR"
echo "  Output: $TEXT_DIR"
echo ""

START_TS=$(date +%s)
DONE=0
FAILED=0

cd "$RAW_DIR"

for PNG in page-*.png; do
  BASENAME=$(basename "$PNG" .png)
  OUT_BASE="$TEXT_DIR/$BASENAME"

  if tesseract "$PNG" "$OUT_BASE" -l jpn_vert --psm 5 2>/dev/null; then
    CHARS=$(wc -m < "${OUT_BASE}.txt" | tr -d ' ')
    DONE=$((DONE + 1))
    printf "\r  [%d/%d] %s: %s chars" "$DONE" "$PAGE_COUNT" "$BASENAME" "$CHARS"
  else
    FAILED=$((FAILED + 1))
    printf "\r  [%d/%d] %s: FAILED" "$((DONE + FAILED))" "$PAGE_COUNT" "$BASENAME"
    echo "[OCR failed]" > "${OUT_BASE}.txt"
  fi
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo ""
echo ""
echo "=== OCR Batch Complete ==="
echo "  Done: $DONE / $PAGE_COUNT"
echo "  Failed: $FAILED"
echo "  Time: ${ELAPSED}s"
echo "  Output: $TEXT_DIR"

TOTAL_CHARS=$(cat "$TEXT_DIR"/*.txt 2>/dev/null | wc -m | tr -d ' ')
echo "  Total chars: $TOTAL_CHARS"
