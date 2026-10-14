#!/bin/bash
# line-redelivered-check.sh — 帶 redelivered="true" 的 LINE 訊息 開口前先問這支：這則回過了沒
#
# 用法：
#   line-redelivered-check.sh <messageId> [--config-dir <channel 的 claude-config>] [--json]
#
# 退出碼：0=ANSWERED 1=UNANSWERED 3=NOT_FOUND(fail-loud) 2=用法或環境錯誤
#
# 判定邏輯與刻意的 fail 方向寫在 line_redelivered_check.py 的檔頭 docstring，
# 這支只是薄殼（邏輯放 python 是為了避開 bash 解析 here-doc 的既有坑）。
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${DIR}/line_redelivered_check.py" "$@"
