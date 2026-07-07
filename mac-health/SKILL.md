# mac-health — 本機健檢

> 觸發：「健檢」「mac 狀態」「機器熱」「CPU 異常」「mac-health」「本機健檢」
> 不觸發：網路問題（走 runbook）、cloudflare tunnel（走 cloudflared-tunnel）

## 檢查項目（依序執行）

### 1. CPU 異常佔用

```bash
ps aux -r | head -15
```

紅線：任何非系統核心 process 持續 > 80% CPU 且 TIME 累積 > 30 分鐘 → 報告異常。
常見踩坑：X-Rite xrdd、Adobe daemon、Spotlight mds_stores 重建。

### 2. 記憶體壓力

```bash
memory_pressure
vm_stat | head -10
```

紅線：`System-wide memory free percentage` < 10% 或 compressor > 5GB → 報告。

### 3. 磁碟空間

```bash
df -h / /System/Volumes/Data
```

紅線：可用空間 < 20GB → 報告。

### 4. 溫度 / 風扇（間接）

```bash
pmset -g therm
```

如果有 thermal warning → 回頭看 §1 找 CPU hog。

### 5. Swap 壓力

```bash
sysctl vm.swapusage
```

紅線：swap used > 4GB → 報告記憶體不足建議。

### 6. 異常 LaunchDaemon

```bash
sudo launchctl list | grep -v "com.apple" | grep -v "^-"
```

找非 Apple 的 daemon 有沒有異常高 PID（不斷 crash-restart）。

### 7. 開機天數

```bash
uptime
```

超過 14 天建議重開機清理。

## 輸出格式

```
## Mac 健檢報告 — {date}

| 項目 | 狀態 | 備註 |
|------|------|------|
| CPU | ✅/⚠️ | ... |
| 記憶體 | ✅/⚠️ | ... |
| 磁碟 | ✅/⚠️ | ... |
| 溫度 | ✅/⚠️ | ... |
| Swap | ✅/⚠️ | ... |
| Daemon | ✅/⚠️ | ... |
| Uptime | ✅/⚠️ | ... |

### 建議行動
- ...
```

## 異常處置原則

- CPU hog → 先報告 process 名稱 + PID + 累積時間，建議 kill
- 記憶體不足 → 列出 top 5 RSS consumer，建議關哪個
- 磁碟不足 → `du -sh` 找大目錄，建議清理方向
- 不主動 kill 任何東西，報告後等使用者確認

## Lineage
<!-- 自動聚合至 skills/CAPABILITY-MATRIX.md by gen-capability-matrix.py；勿刪 -->
origin: ""
status: active
closeout_gist: ""
