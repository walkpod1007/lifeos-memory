# GOTCHAS.md — Runbook Skill 已知坑

## Log 路徑不存在

**症狀**：`find: ... No such file or directory`
**原因**：`~/.claude/logs/` 不一定存在，取決於 Gateway 版本
**解法**：腳本已做路徑存在檢查（`[ -d ... ]`），不存在就跳過，不報錯

---

## `~` 在腳本內不展開

**症狀**：路徑帶 `~` 卻找不到檔案
**原因**：`find "~/.claude/..."` 在某些 shell context 下不展開
**解法**：腳本統一用 `$HOME` 取代 `~`

---

## grep 無輸出不代表沒錯誤

**症狀**：報告顯示「無相關 Log」，但問題確實發生過
**原因**：
1. Log rotation 把舊 log 壓縮或刪除
2. 錯誤發生在 stdout 而非 log 檔
3. 關鍵字大小寫不符（grep 預設 case-sensitive）
**解法**：腳本用 `-i` flag（case-insensitive），也可手動 `journalctl` 補查

---

## Gateway log 在 launchd stdout

**症狀**：`~/.claude/logs/` 沒有 gateway 相關 log
**原因**：macOS launchd service 的 stdout/stderr 可能導向 `~/Library/Logs/`
**解法**：
```bash
# 手動查 launchd log
cat ~/Library/Logs/claude-gateway.log 2>/dev/null || \
  log show --predicate 'process == "node"' --last 1h | grep -i claude
```

---

## JSON 格式 log 難讀

**症狀**：log 是 `{"level":"error","msg":"..."}` 格式，grep 輸出很醜
**原因**：部分服務用 JSON structured logging
**解法**：腳本偵測到 JSON log 時自動用 `jq` 格式化（需安裝 jq）
```bash
brew install jq  # 未安裝時
```

---

## 關鍵字太廣導致輸出爆炸

**症狀**：輸入 `"error"` 導致幾千行輸出
**原因**：error 是高頻詞
**解法**：腳本限制輸出最多 50 行相關 log；建議用更具體的關鍵字

---

## 權限問題

**症狀**：`Permission denied` 讀取某些 log
**原因**：系統 log（`/var/log/`）需要 sudo
**解法**：腳本只掃使用者可讀的路徑，系統 log 不在範圍內
若需要：`sudo log show --last 30m`

---

## diagnose.sh 沒有執行權限

**症狀**：`bash: permission denied` 或 `zsh: permission denied`
**原因**：新建立的腳本預設無 `+x`
**解法**：`chmod +x ~/life-os/skills/runbook/scripts/diagnose.sh`
- [0.5] # Bash tool cwd state 腐化：ws/ 子目錄誤報消失（根因未明） (2026-04-26, 1 hit)
- [0.5] Computer Use 在 macOS 不可信環境下無法取得瀏覽器自動化權限，比價網爬蟲是可行的降級方案 (2026-04-26, 1 hit)
- [0.5] Gen-handoff 整合進 health-check 時未測 edge case（MCP 不存在、socket stale 等），致 supervisor 掛起；新邏輯應 retry-once + log 而非靜默自癒 (2026-04-26, 1 hit)
- [0.5] health-check 缺乏 EACCES vs ENOENT 區分，無法從權限問題與真實缺失區別；MCP 每個 channel 各 spawn 一份 server.ts 但無 port 循環邏輯 (2026-04-29, 1 hit)
- [0.5] rm 操作在 iCloud 路徑上被 sandbox 全數擋截，包含 GLM 與 Agent 子代理皆無法執行，僅終端機直跑可行。補充既有「iCloud 權限限制」卡片的實證：多個 Claude 進程都被同樣攔截。 (2026-04-27, 1 hit)
- [0.5] re-stat skip 後落 else 會誤重置 MCP_KILL_COUNT=0，導致 ambiguous 狀態判定失效——需 elif guard + race condition 完整測。 (2026-04-29, 1 hit)
- [0.5] 不應該先說「加進去了」再後發現 Bash 失效——該先檢驗工具可用性，確認能實際執行後再回覆成功。 (2026-04-28, 1 hit)
- [0.5] 依賴 process 存活判斷會遮蔽對話層故障；需實測 API 響應確認 session 真實可用性 (2026-04-27, 1 hit)
- [0.5] homebrew bash 5.3 在中文 locale 下，雙引號字串裡 `$VAR` 後緊跟全形字元（如「）」）時，會把全形字元的位元組吞進變數名，`set -u` 直接炸「VAR�: 未綁定的變數」；macOS 內建 /bin/bash 3.2 反而正常。同一支腳本 cron（/bin/bash）跑得好好的、手動（PATH 先吃到 homebrew bash）就炸，症狀像鬧鬼。診斷法：兩個 bash 各跑一次 `set -u; X=1; echo "（$X）"` 立刻分曉。修法：`${VAR}` 加大括號、或字串內避免 `$VAR` 緊貼全形字元。同族卡：[[ps-lstart-locale-mismatch]]（也是 locale 造成的雙面行為）。實例：scripts/daily-retention.sh:59 手跑必炸、cron 正常（2026-07-02）。 **反向二犯（2026-07-03）**：canary-daily.sh 用「$() 內嵌 heredoc」——homebrew 5.3 手測全過、cron 的 /bin/bash 3.2 直接 parse error，金絲雀首班陣亡。家族教訓固化：**驗收 cron 腳本必須用 `/bin/bash -n` 與 `/bin/bash` 實跑**（cron 用哪支 bash 就用哪支驗），手上 shell 的 bash 過了不算數。 **三犯（2026-07-03 下午）**：office-bootstrap.sh 六處 $VAR 緊貼全形符號，v3 修復輪工兵沙盒實跑才發現（bash 5.3+set -u 秒崩，Phase 3.5 都到不了）。三犯定律成立：**任何要出貨的 .sh，發貨前跑一次 `grep -nE '\$[A-Z_]+[（）「」：、）]'` 當 lint**——這坑靠人記不住，要靠機器掃。 (2026-07-02, 1 hit)
- [0.5] Checkpoints 機制全系統無此目錄（幽靈機制，記入 backlog） (2026-07-02, 1 hit)
- [0.5] codex 檢核流程在提交後出現 exit=1 失敗，需要同步檢查錯誤信息與日誌來追蹤根因。 (2026-07-02, 1 hit)
- [0.5] crontab 行寫 `hb-wrap.sh <job> bash -lc '真正指令'` 時，cron 的 sh 先剝掉單引號 → hb-wrap 收到裸詞序列 → 內部 `eval "$*"` 重組後 `-lc` 只吃到第一個詞（"bash"）→ 執行空殼 bash 秒退 exit 0。結果：**心跳表記成功、0 秒完成、實際什麼都沒跑**——比失敗更毒的假成功。2026-07-03 凌晨四班夜車（夢/字典/側樓/對帳首跑）全部因此空跑。 修法：包 hb-wrap 的 cron 行一律**直呼格式** `hb-wrap.sh <job> bash ~/path/script.sh`，禁用 `bash -lc '...'`（eval 會自己做展開，不需要 -lc）。 **驗證教訓（更重要）**：裝完新 crontab 我實測過「一條」job——恰好抽到直呼格式（活的），沒抽到 -lc 格式（死的）。抽樣驗證要**按格式分層各抽一條**，不是隨機抽一條。偵測訊號：heartbeat 的 elapsed=0 且該 job 理應耗時 → 假成功嫌疑（canary 應加此規則）。同族卡：[[hook-keyword-false-positive-dispatch]]（同樣是「字串過殼層被改寫」家族）。 (2026-07-03, 1 hit)
- [0.5] daily-poster 401 錯誤訊息被當片名搜尋（邏輯混淆），git 39 commits 未 push 應設 pre-commit 警告 (2026-07-02, 1 hit)
- [0.5] insight_extract 替換打歪縮排，需依上下文修正。 (2026-07-03, 1 hit)
- [0.5] lsof 診斷在 claude 無檔案 handle 情況下天生失效；Layer 2 gate 啟動時機誤導警告解釋。 (2026-07-02, 1 hit)
- [0.5] `echo ""` 看似清空檔案但實際遺留 1 byte 換行符，導致 `wc -l` 誤判檔案非空（LINE 佇列狀況）；正確做法是用 `truncate -s 0` 徹底清空為 0 byte。 (2026-07-01, 1 hit)
- [0.5] SSH 非互動 shell 環境預設缺少 homebrew PATH，導致套件命令不可達，需手動補上 PATH 至 shell profile 即可恢復。 (2026-07-03, 1 hit)
- [0.5] 使用者在實體鍵盤對 tmux 內的 Claude Code 輸入框打中文後沒送出，殘留的 IME 組字（composition）狀態會讓**遠端 `tmux send-keys Enter` 完全無效**（畫面看得到文字、Enter 石沉大海，重試 N 次都一樣）。診斷特徵：paste-buffer 貼進去的文字＋Enter 正常送出，唯獨「人手打的殘留輸入」卡死。解法三步：`send-keys Escape`（取消組字）→ `send-keys C-u`（清行）→ load-buffer/paste-buffer 代貼同文字 → Enter。實例：2026-07-04 公司機 office-main「D5 清理」指令卡整夜，三步法秒解（前一晚 03:05 git commit 指令同症狀，當時繞道親手代辦）。 (2026-07-04, 1 hit)
- [0.5] 往同一 iCloud 帳號的另一台機大量寫檔（實例：413 檔 scp 進公司機 Office Vault，2026-07-04 00:5x）會讓**家機的 fileproviderd 同步風暴打結**——之後任何 `opendir()` 碰到受影響 Vault 目錄的行程**無限阻塞**（不是 EDEADLK 秒錯，是永久等待）：03:00 run-nightly 吊 6hr、04:40 gen-dicts 吊 4hr，而沒碰堵塞目錄的 job（做夢/側樓）正常——「同晨選擇性缺班」是此病的指紋。診斷法：`ps` 找活著的老進程 → `sample <pid>` 看是否卡 `__open_nocancel`。解法：kill 吊死樹 → `killall fileproviderd` → 補跑。預防：①跨機大宗 iCloud 傳輸避開 00:00-05:00 夜車窗 ②所有讀 Vault 的排程腳本外層包 `timeout`（吊死變報錯，金絲雀才抓得到）③大量灌檔改走 scp 到**非 iCloud 路徑**再由對機本地搬。心跳缺班≠沒跑：hb-wrap 收工才寫心跳，先查活進程再下結論。 (2026-07-04, 1 hit)
- [0.5] memory git 初始順序誤導，已改正 (2026-07-02, 1 hit)
