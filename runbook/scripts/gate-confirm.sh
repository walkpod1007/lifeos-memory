#!/bin/bash
# gate-confirm.sh — WO-033 C3 實作
# 用法：gate-confirm.sh <red|yellow> <操作說明> <風險說明（紅線用）>

LEVEL="${1:-green}"
OPERATION="${2:-未知操作}"
RISK="${3:-}"
TIMEOUT=60

case "$LEVEL" in
  red)
    echo "⚠️ 風險：$RISK"
    echo ""
    echo "這是🔴紅線操作：$OPERATION"
    echo "執行後可能無法復原。"
    echo ""
    echo "請在 LINE 回覆「做」或「執行」繼續，或「取消」放棄。"
    echo "（$TIMEOUT 秒無回應視為取消）"
    # 寫入等待旗標
    echo "{\"level\":\"red\",\"operation\":\"$OPERATION\",\"timestamp\":$(date +%s),\"timeout\":$TIMEOUT}" \
      > /tmp/gate-pending.json
    exit 2  # exit 2 = 等待確認
    ;;

  yellow)
    echo "即將執行：$OPERATION"
    echo "（$TIMEOUT 秒無回應視為取消）"
    # 寫入等待旗標
    echo "{\"level\":\"yellow\",\"operation\":\"$OPERATION\",\"timestamp\":$(date +%s),\"timeout\":$TIMEOUT}" \
      > /tmp/gate-pending.json
    exit 2  # exit 2 = 等待確認
    ;;

  green)
    exit 0  # 直接執行
    ;;

  *)
    echo "未知操作等級：$LEVEL"
    exit 1
    ;;
esac
