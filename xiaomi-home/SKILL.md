---
name: xiaomi-home
description: 透過局域網直連控制小米家居設備（智能插座、加濕器、電鍋等），使用 miiocli，不需雲端 API，速度快。使用時機：小米、米家、開熱水器、關熱水器、加濕器、電鍋、智能插座、xiaomi、miiocli。
---

# Xiaomi Home Control

## Overview

用 `miiocli` 在局域網直接控制小米設備，不走雲端。需要設備 IP 和 Token。

## 安裝（第一次）

```bash
pipx install python-miio
# 取得所有設備的 IP 和 Token
<!-- TODO: script missing at ~/life-os/skills/xiaomi-home/scripts/ — use ~/life-os/scripts/miio-control.py as alternative -->
python3 ~/life-os/skills/xiaomi-home/scripts/token_extractor.py
# 把設備資訊存到 references/xiaomi-devices.md
```

## 基本語法

```bash
miiocli miotdevice --ip <IP> --token <TOKEN> <command>
```

## 常用設備操作

```bash
# 開熱水器（智能插座）
miiocli miotdevice --ip <IP> --token <TOKEN> \
  raw_command set_properties '[{"siid":2,"piid":1,"value":true}]'

# 關熱水器
miiocli miotdevice --ip <IP> --token <TOKEN> \
  raw_command set_properties '[{"siid":2,"piid":1,"value":false}]'

# 加濕器最大檔
miiocli miotdevice --ip <IP> --token <TOKEN> set_property_by 2 5 3

# 電鍋狀態
miiocli cooker --ip <IP> --token <TOKEN> status

# 查設備當前狀態
miiocli miotdevice --ip <IP> --token <TOKEN> \
  raw_command get_properties '[{"siid":2,"piid":1}]'
```

## 設備資料

存放位置：`$HOME/life-os/references/xiaomi-devices.md`

必須在同一局域網才能直連。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
