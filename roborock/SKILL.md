---
name: roborock
description: 控制 Roborock 掃地機器人：啟動、暫停、回充、查狀態、設定吸力/水量。使用時機：掃地、吸地板、掃拖模式、掃地機器人、roborock、清地板、回充、掃地機回去。
---

# Roborock Vacuum Control

## 設備資訊

| 機型 | Device ID |
|---|---|
| Roborock Q Revo MaxV | `21AVSkY89ZMEHfSeR6nYML` |
| Roborock S5 Max | `7Q77Gb4hxvGbnc40YeEjIM` |

預設操作機型：**Q Revo MaxV**（主力機）

## CLI 路徑

```bash
~/.local/bin/roborock
```

> `roborock` 不在 PATH，必須用完整路徑。

## 查詢指令

```bash
DEVICE="21AVSkY89ZMEHfSeR6nYML"

# 列裝置
~/.local/bin/roborock list-devices

# 查狀態
~/.local/bin/roborock status --device_id "$DEVICE"

# 查房間
~/.local/bin/roborock rooms --device_id "$DEVICE"

# 查耗材
~/.local/bin/roborock consumables --device_id "$DEVICE"
```

## 控制指令（走 command 子命令）

```bash
DEVICE="21AVSkY89ZMEHfSeR6nYML"

# 開始清掃（全部）
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "app_start"

# 暫停
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "app_pause"

# 停止並回充
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "app_stop"
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "app_charge"

# 設定吸力（啟動前設）
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "set_custom_mode" --params '[102]'
# 101=靜音 / 102=標準 / 103=強力 / 104=最強

# 設定拖地水量（啟動前設）
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "set_water_box_custom_mode" --params '[202]'
# 201=輕柔 / 202=中等 / 203=強力 / 204=超強
```

## 掃拖模式 SOP（最常用）

```bash
DEVICE="21AVSkY89ZMEHfSeR6nYML"

# 1. 設吸力（按需求選）
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "set_custom_mode" --params '[102]'

# 2. 設水量（按需求選）
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "set_water_box_custom_mode" --params '[202]'

# 3. 啟動
~/.local/bin/roborock command --device_id "$DEVICE" --cmd "app_start"

# 4. 確認狀態（看 inCleaning=1 就 OK）
~/.local/bin/roborock status --device_id "$DEVICE"
```

## 常見狀態碼

| state | 意思 |
|---|---|
| 8 | 充電中 |
| 1 / 3 | 待機 |
| 5 / 100 | 充電完成 |
| 23 | 掃拖中 |
| 6 | 錯誤 |

## 踩坑紀錄

- **`roborock` 不在 PATH**：要用 `~/.local/bin/roborock` 全路徑。
- **`--device_id` 必填**：所有指令（status / command / rooms / consumables）都要帶，不帶會失敗。
- **指令順序**：先設吸力/水量，再 `app_start`；中途改設定不一定即時生效。
- **MQTT 狀態**：2026-06-27 實測 `command` 子命令 MQTT 正常，掃拖成功啟動。

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
