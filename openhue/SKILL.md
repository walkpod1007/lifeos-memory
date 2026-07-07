---
name: openhue
description: 控制 Philips Hue 燈光和情境，使用 openhue CLI 透過 Hue Bridge 操作。使用時機：開燈、關燈、hue、燈光情境、調亮度、調燈光顏色、openhue、hue 燈、換個情境。
---

# Philips Hue Control

## Overview

用 `openhue` CLI 控制 Hue 燈光。需要 Hue Bridge 在同一局域網。

## 安裝（第一次）

```bash
brew install openhue/cli/openhue-cli
openhue discover    # 找 Bridge
openhue setup       # 引導設定（需按 Bridge 實體按鈕）
```

## 讀取

```bash
openhue get light --json    # 列所有燈（含 ID）
openhue get room --json     # 列所有房間
openhue get scene --json    # 列所有情境
```

## 控制

```bash
# 開/關
openhue set light <name> --on
openhue set light <name> --off

# 亮度（0-100）
openhue set light <name> --on --brightness 60

# 顏色（hex）
openhue set light <name> --on --rgb "#3399FF"

# 套用情境
openhue set scene <scene-id>
```

名稱有歧義時加 `--room "房間名"` 指定。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
