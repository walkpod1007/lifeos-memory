---
name: samsung-smartthings
description: 控制所有 Samsung SmartThings 設備：電視（開關、切輸入源、音量）、空氣清淨機、冷氣、洗衣機等。使用時機：開電視、關電視、電視轉台、切 HDMI、空氣清淨機、samsung 設備、SmartThings。Frame TV 換畫改用 samsung-frame-art。
---

# Samsung SmartThings

## Overview

透過 SmartThings CLI 控制所有接入設備。憑據存在 `~/.claude/.env`。

## 第一步：查設備清單

```bash
source ~/.claude/.env
smartthings devices                          # 列出所有設備和 ID
smartthings devices:capabilities $DEVICE_ID  # 查設備支援哪些能力
smartthings devices:status $DEVICE_ID        # 查當前狀態
```

## 電視

```bash
smartthings devices:commands $TV_ID switch on
smartthings devices:commands $TV_ID switch off
smartthings devices:commands $TV_ID mediaInputSource setInputSource HDMI1
smartthings devices:commands $TV_ID audioVolume setVolume 20
smartthings devices:commands $TV_ID audioMute setMute muted
```

## 空氣清淨機

```bash
smartthings devices:commands $PURIFIER_ID switch on
smartthings devices:commands $PURIFIER_ID switch off
# 查空氣品質
smartthings devices:status $PURIFIER_ID | jq '.components.main'
```

## 冷氣

```bash
smartthings devices:commands $AC_ID switch on
smartthings devices:commands $AC_ID switch off
# 設溫度（需 thermostatCoolingSetpoint capability）
smartthings devices:commands $AC_ID thermostatCoolingSetpoint setCoolingSetpoint 26
```

## 不知道設備支援什麼時

先查能力再下指令：

```bash
smartthings devices:capabilities $DEVICE_ID
```

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
