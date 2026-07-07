#!/bin/bash
# yt-relay-translate 主管線。規格：../SKILL.md
# bash 3.2 相容（macOS 系統 /bin/bash）：不用 associative array / ${var,,} / mapfile 等 bash4+ 語法，
# 不把 heredoc 塞進 $()，python3 一律用 -c 搭配 sys.argv 傳值（不直接把 shell 變數插進 python 原始碼字串）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="/tmp/yt-relay"
ENV_FILE="$HOME/.claude/.env"

usage() {
  cat <<'USAGEEOF'
用法:
  relay.sh <YT_URL> [--privacy unlisted|private] [--channel yourchannel|yourchannel2] [--burn|--soft-only] [--dry-run]
  relay.sh --resume <video_id> [--approve-upload] [--force-reupload] [--dry-run]
  relay.sh <YT_URL> --resume <video_id> --restart   # state.json 損毀時重建

參數:
  --privacy        unlisted(預設)|private  上傳隱私層級（初次 relay 拒絕 public，
                    要轉公開請在上傳完成後跑 yt_relay_upload.py --update-privacy）
  --burn           只產出燒錄版（硬燒 zh.srt），上傳燒錄版
  --soft-only      只產出軟字幕版（原檔＋caption），不燒錄
  (預設)           兩者都產，上傳軟字幕版（原檔＋caption track）
  --approve-upload 翻譯與合成都完成後，明確核可才進 Step5 實際上傳（沒有此旗標會停在 Step4 完成）
  --dry-run        跑到 Step5 為止全部真做，Step5 只印出將送出的 payload，不呼叫 YouTube API
                    （同效環境變數 YT_RELAY_NO_UPLOAD=1）
  --force-reupload 明知 upload-started.marker 已存在仍要重新嘗試上傳時使用（正常情況不需要）
  --restart        state.json 損毀/缺鍵時，搭配原始 <YT_URL> 與 --resume <video_id> 重建 state.json
                    （既有產出檔案如 source.mp4/source.srt/zh.srt 會被後續步驟偵測並沿用，不必重跑）

工作目錄: /tmp/yt-relay/<video_id>/，狀態檔 state.json 可用 --resume 續跑。
翻譯段（Step3）會產出 JSON 格式的 NEED_TRANSLATE.flag 後 exit 0，等主 session 派 sonnet
子代理把翻好的 zh.srt 放回工作目錄、且寫入 TRANSLATE_DONE.json（{source_sha256, zh_segments}）
驗證通過後，再用 --resume 續跑。Step5 上傳另需 --approve-upload（或 --dry-run 純測試）。
USAGEEOF
}

# ---------------------------------------------------------------------------
# state.json 存取（一律用 jq，不手刻 JSON 解析）
# ---------------------------------------------------------------------------
state_get() {
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
}

state_set() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_set_step() {
  local n="$1" tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson v "$n" '.step = $v' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

note() {
  local msg="$1" ts tmp
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $msg"
  if [ -n "${STATE_FILE:-}" ] && [ -s "$STATE_FILE" ]; then
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --arg n "$msg" --arg t "$ts" \
      '.notes += [{"time":$t,"note":$n}] | .updated_at = $t' \
      "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
}

# F4（HIGH）：state.json 一律用 jq -n --arg 生成，不再用 heredoc 直接把 URL/路徑等字串
# 插進 JSON 文字——heredoc 版本一遇到引號/反斜線/換行就產出壞掉的 JSON。jq --arg 會
# 正確跳脫，任何字元進來都還是合法 JSON。
init_state() {
  local vid="$1" url="$2" workdir="$3" now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  jq -n \
    --arg vid "$vid" --arg url "$url" --arg workdir "$workdir" \
    --arg privacy "$PRIVACY" --arg format_mode "$FORMAT_MODE" --arg now "$now" \
    '{
      video_id: $vid,
      url: $url,
      workdir: $workdir,
      privacy: $privacy,
      format_mode: $format_mode,
      step: 1,
      status: "in_progress",
      created_at: $now,
      updated_at: $now,
      title: "",
      channel: "",
      upload_date: "",
      path_video_mp4: "",
      path_meta_json: "",
      path_source_srt: "",
      path_source_lang: "",
      subtitle_source: "",
      path_zh_srt: "",
      path_zh_title_txt: "",
      path_burned_mp4: "",
      path_flag_file: "",
      uploaded_video_url: "",
      uploaded_id: "",
      notes: [],
      error: null
    }' > "$STATE_FILE"
  if ! jq empty "$STATE_FILE" 2>/dev/null; then
    echo "❌ init_state 產出的 state.json 不是合法 JSON: $STATE_FILE" >&2
    exit 1
  fi
}

# F5（HIGH）：--resume 前驗 schema，必要鍵齊全才放行；缺鍵/非法 JSON 一律報損毀，
# 指示改用 --restart 重建，不讓後續 state_get/數字比較在半殘 state 上悄悄跑歪。
STATE_SCHEMA_KEYS="video_id url workdir privacy format_mode step status created_at updated_at title channel upload_date path_video_mp4 path_meta_json path_source_srt path_source_lang subtitle_source path_zh_srt path_zh_title_txt path_burned_mp4 path_flag_file uploaded_video_url uploaded_id notes error"

validate_state_schema() {
  local f="$1" missing=0 k step_val vid_val privacy_val fmt_val
  if ! jq empty "$f" 2>/dev/null; then
    echo "❌ state.json 不是合法 JSON: $f" >&2
    return 1
  fi
  for k in $STATE_SCHEMA_KEYS; do
    if ! jq -e --arg k "$k" 'has($k)' "$f" >/dev/null 2>&1; then
      echo "❌ state.json 缺少必要鍵: $k" >&2
      missing=1
    fi
  done

  # #2（F5 型別驗證）：光有鍵不夠——之前 step="abc" 這類壞值也會通過 schema 檢查，
  # 後續 `[ "$CUR_STEP" -le 4 ]` 數字比較在 bash 下對非數字字串會直接噴
  # "integer expression expected" 或悄悄比較錯誤。這裡把「有無」升級成「型別/值域」：
  # step 必須是非負整數、video_id 不可為空、privacy 必須是 unlisted|private
  # （relay.sh 從不接受 public 寫進 state，state 裡出現 public 本身就是被竄改的訊號）。
  step_val=$(jq -r '.step' "$f" 2>/dev/null)
  if ! printf '%s' "$step_val" | grep -qE '^[0-9]+$'; then
    echo "❌ state.json 型別錯誤: step 必須是非負整數，實際: $step_val" >&2
    missing=1
  fi

  vid_val=$(jq -r '.video_id' "$f" 2>/dev/null)
  if [ -z "$vid_val" ]; then
    echo "❌ state.json 型別錯誤: video_id 不可為空" >&2
    missing=1
  fi

  # #2 補遺（Round 3 阻塞點）：format_mode 也要白名單驗證
  fmt_val=$(jq -r '.format_mode' "$f" 2>/dev/null)
  case "$fmt_val" in
    both|burn|soft) : ;;
    *)
      echo "❌ state.json 型別錯誤: format_mode 必須是 both|burn|soft，實際: $fmt_val" >&2
      return 1
      ;;
  esac

  privacy_val=$(jq -r '.privacy' "$f" 2>/dev/null)
  case "$privacy_val" in
    unlisted|private) ;;
    *)
      echo "❌ state.json 型別錯誤: privacy 必須是 unlisted|private，實際: $privacy_val" >&2
      missing=1
      ;;
  esac

  [ "$missing" -eq 0 ]
}

# #5（resume 覆寫 bug）：--resume（或用原 URL 撞到既有 state.json）時，若 CLI 沒有
# 明確帶 --privacy/--burn/--soft-only，一律從 state.json 讀回已記錄的設定，不能讓
# main() 裡的 CLI 預設值（unlisted/both）把先前存的 private/burn 等設定悄悄蓋掉。
# 只有 CLI 明確帶旗標時才反過來把新值寫回 state。PRIVACY/FORMAT_MODE/PRIVACY_SET/
# FORMAT_MODE_SET 是 main() 的 local 變數，bash 動態作用域下這裡直接讀寫得到。
sync_privacy_format_with_state() {
  if [ "$PRIVACY_SET" -eq 1 ]; then
    state_set privacy "$PRIVACY"
  else
    PRIVACY=$(state_get privacy)
  fi
  if [ "$FORMAT_MODE_SET" -eq 1 ]; then
    state_set format_mode "$FORMAT_MODE"
  else
    FORMAT_MODE=$(state_get format_mode)
  fi
}

# #1（F2 鎖時序修正）：鎖必須在任何 state.json 讀寫之前就取得，不能等到 resume/
# restart/init_state 等分支都跑完才上鎖——舊版鎖上得太晚，state 初始化與 resume
# 覆寫那段其實在鎖外執行，兩個並發的 relay.sh 呼叫可能同時讀寫同一個 workdir 的
# state.json/meta.json 產生競態。呼叫時機：main() 一旦知道 WORKDIR（不論是
# --resume 或新 URL 算出 video_id 之後），立刻呼叫，之後才做任何 state 存取。
# 注意：LOCK_DIR 刻意不宣告 local——EXIT trap 在 main() return 之後才於頂層執行，
# 若是 local 變數，那時已經離開作用域，在 set -u 下會變成 unbound variable
# （已實測踩到這個坑：trap 觸發時噴 "LOCK_DIR: 未綁定的變數"）。
acquire_lock() {
  mkdir -p "$WORKDIR"
  LOCK_DIR="$WORKDIR/.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "❌ 偵測到另一個 relay.sh 進程正在處理 video_id=$VIDEO_ID （鎖 $LOCK_DIR 已存在）。確認沒有殘留進程後可手動 rmdir 解鎖。" >&2
    exit 1
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 從 meta.json 挑字幕語言：優先原始語音語言，其次 en，其次第一個可用
pick_lang() {
  python3 -c '
import json, sys
meta_path, field = sys.argv[1], sys.argv[2]
with open(meta_path, encoding="utf-8") as f:
    d = json.load(f)
avail = d.get(field) or {}
keys = list(avail.keys())
lang = d.get("language")
if lang and lang in keys:
    print(lang)
elif "en" in keys:
    print("en")
elif keys:
    print(keys[0])
' "$1" "$2"
}

# 依序找可用的 whisper.cpp ggml 模型檔；規格指定 medium，找不到就退而求其次並在 state 標記 degraded
find_whisper_model() {
  local search_dirs pref d hit
  search_dirs="$HOME/.cache/whisper $HOME/.cache/whisper.cpp $HOME/.cache/whisper-cpp /opt/homebrew/share/whisper-cpp /opt/homebrew/share/whisper $HOME/.claude-video-vision/models"
  for pref in medium large-v3-turbo large-v3 large small base tiny; do
    for d in $search_dirs; do
      [ -d "$d" ] || continue
      hit=$(find "$d" -maxdepth 2 -iname "ggml-${pref}*.bin" 2>/dev/null | head -1 || true)
      if [ -n "$hit" ]; then
        printf '%s' "$hit"
        return 0
      fi
    done
  done
  for d in $search_dirs; do
    [ -d "$d" ] || continue
    hit=$(find "$d" -maxdepth 2 -iname "ggml-*.bin" 2>/dev/null | head -1 || true)
    if [ -n "$hit" ]; then
      printf '%s' "$hit"
      return 0
    fi
  done
  return 1
}

# ffmpeg subtitles= filter 對反斜線/單引號敏感；路徑包在單引號裡再跳脫內部單引號
escape_ffmpeg_subtitles_path() {
  local p="$1"
  p=$(printf '%s' "$p" | sed 's/\\/\\\\/g')
  p=$(printf '%s' "$p" | sed "s/'/'\\\\''/g")
  printf '%s' "$p"
}

# 2026-07-03 起：靜態 build 含 libass 的 ffmpeg-full 已裝在 ~/life-os/bin/ffmpeg-full，
# 燒錄優先用它（實測 subtitles filter 可用）；不存在或該 binary 沒編 subtitles filter
# 時 fallback 系統 ffmpeg（沒 libass 就照 step4_burn 原本的 degraded 邏輯降軟字幕）。
pick_burn_ffmpeg() {
  local candidate="$HOME/life-os/bin/ffmpeg-full" filters_out
  if [ -x "$candidate" ]; then
    # 注意：不要直接 `"$candidate" -filters | grep -q ...`——在 set -o pipefail 下，
    # grep -q 找到符合就提早關 pipe，上游 ffmpeg 收到 SIGPIPE 以非零狀態(141)結束，
    # pipefail 會把整條 pipeline 判定失敗，即使 grep 其實有命中（已實測踩到這個坑：
    # 獨立跑正常，套進 set -euo pipefail 腳本卻永遠 fallback）。改成先用命令替換把
    # 完整輸出讀進變數（一次寫完不會卡 pipe buffer），再對記憶體字串跑 grep，
    # 完全避開會被提早關閉的子行程 pipe。
    filters_out=$("$candidate" -filters 2>/dev/null || true)
    if printf '%s' "$filters_out" | grep -qE '\bsubtitles\b'; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  printf 'ffmpeg'
}

read_env_var() {
  # 從 ~/.claude/.env 讀單一變數（沿用 line-stt 的作法）
  local name="$1"
  if [ -f "$ENV_FILE" ]; then
    grep -m1 "^${name}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
  fi
}

# F1/F13 用：srt 段數（用時間軸箭頭 " --> " 計數，比數行內數字索引更抗格式差異）
srt_segment_count() {
  local f="$1" n
  if [ ! -s "$f" ]; then
    printf '0'
    return
  fi
  n=$(grep -c ' --> ' "$f" 2>/dev/null || true)
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# F12：whisper 聽寫前先確認來源影片有音軌，沒有就明確報「無音軌」，不要讓它一路
# 掉進 ffmpeg 抽音軌失敗才含糊報錯。
has_audio_track() {
  local f="$1" streams
  streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null || true)
  [ -n "$streams" ]
}

# ---------------------------------------------------------------------------
# Step 1：下載影片本體（meta.json 由 main() 在解析 video_id 時已抓好）
# ---------------------------------------------------------------------------
step1_download() {
  note "Step1: 下載影片本體"
  local meta_json="$WORKDIR/meta.json"
  if [ ! -s "$meta_json" ]; then
    state_set status "failed"
    state_set error "meta.json 遺失，無法進行 Step1"
    echo "❌ meta.json 不存在: $meta_json" >&2
    exit 1
  fi

  local title channel upload_date
  title=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title",""))' "$meta_json")
  channel=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("channel") or d.get("uploader") or "")' "$meta_json")
  upload_date=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("upload_date",""))' "$meta_json")
  state_set title "$title"
  state_set channel "$channel"
  state_set upload_date "$upload_date"
  state_set path_meta_json "$meta_json"

  if [ ! -s "$WORKDIR/source.mp4" ]; then
    local attempt ok
    ok=0
    for attempt in 1 2; do
      if yt-dlp --no-warnings -f "bv*[height<=1080]+ba/best[height<=1080]" \
          --merge-output-format mp4 -o "$WORKDIR/source.mp4" "$URL" \
          > "$WORKDIR/ytdlp_dl.log" 2> "$WORKDIR/ytdlp_dl.err"; then
        ok=1
        break
      fi
      note "下載第 $attempt 次失敗"
    done
    if [ "$ok" -ne 1 ]; then
      state_set status "failed"
      state_set error "yt-dlp 影片下載失敗（地區鎖/會員限定可能，已重試不再重試）"
      echo "❌ 下載失敗（已重試 2 次）：URL=$URL" >&2
      tail -10 "$WORKDIR/ytdlp_dl.err" >&2 2>/dev/null || true
      exit 1
    fi
  fi

  if [ ! -s "$WORKDIR/source.mp4" ]; then
    state_set status "failed"
    state_set error "下載後找不到 source.mp4"
    exit 1
  fi

  state_set path_video_mp4 "$WORKDIR/source.mp4"
  state_set_step 2
  note "Step1 完成: title=${title}"
}

# ---------------------------------------------------------------------------
# Step 2：取得原語言字幕（人工字幕 > 自動字幕 > whisper-cli > OpenAI whisper-1 API）
# ---------------------------------------------------------------------------
step2_subtitles() {
  note "Step2: 取得原語言字幕"
  local meta_json="$WORKDIR/meta.json"

  if [ -s "$WORKDIR/source.srt" ]; then
    note "source.srt 已存在，略過字幕抓取"
    state_set_step 3
    return
  fi

  local manual_lang
  manual_lang=$(pick_lang "$meta_json" "subtitles" || true)
  if [ -n "$manual_lang" ]; then
    if yt-dlp --no-warnings --skip-download --write-subs --sub-langs "$manual_lang" \
        --convert-subs srt -o "$WORKDIR/source" "$URL" \
        > "$WORKDIR/ytdlp_subs.log" 2> "$WORKDIR/ytdlp_subs.err"; then
      local produced="$WORKDIR/source.${manual_lang}.srt"
      if [ -s "$produced" ]; then
        mv "$produced" "$WORKDIR/source.srt"
        printf '%s' "$manual_lang" > "$WORKDIR/source.lang"
        state_set subtitle_source "manual"
        state_set path_source_srt "$WORKDIR/source.srt"
        state_set path_source_lang "$manual_lang"
        state_set_step 3
        note "字幕來源: 人工字幕 (${manual_lang})"
        return
      fi
    fi
    note "人工字幕($manual_lang)抓取失敗或無檔案，改試自動字幕"
  fi

  local auto_lang
  auto_lang=$(pick_lang "$meta_json" "automatic_captions" || true)
  if [ -n "$auto_lang" ]; then
    if yt-dlp --no-warnings --skip-download --write-auto-subs --sub-langs "$auto_lang" \
        --convert-subs srt -o "$WORKDIR/source" "$URL" \
        > "$WORKDIR/ytdlp_autosubs.log" 2> "$WORKDIR/ytdlp_autosubs.err"; then
      local produced="$WORKDIR/source.${auto_lang}.srt"
      if [ -s "$produced" ]; then
        mv "$produced" "$WORKDIR/source.srt"
        printf '%s' "$auto_lang" > "$WORKDIR/source.lang"
        state_set subtitle_source "auto"
        state_set path_source_srt "$WORKDIR/source.srt"
        state_set path_source_lang "$auto_lang"
        state_set_step 3
        note "字幕來源: 自動字幕 (${auto_lang}，品質未經校對)"
        return
      fi
    fi
    note "自動字幕($auto_lang)抓取失敗或無檔案，改走 whisper 聽寫"
  else
    note "來源影片沒有人工也沒有自動字幕，改走 whisper 聽寫"
  fi

  step2_whisper
}

step2_whisper() {
  # F12：進 whisper 前先驗證有音軌。沒有就明確報「無音軌」並終止，不要讓它拖到
  # ffmpeg 抽音軌那層才含糊失敗。
  if ! has_audio_track "$WORKDIR/source.mp4"; then
    state_set status "failed"
    state_set error "來源影片無音軌，無法聽寫字幕"
    echo "❌ 來源影片無音軌（ffprobe 偵測不到 audio stream）：$WORKDIR/source.mp4" >&2
    exit 1
  fi

  local model_path model_base
  if ! model_path=$(find_whisper_model); then
    note "whisper-cli 模型缺失（找遍 \$HOME/.cache/whisper*、/opt/homebrew/share/whisper*、\$HOME/.claude-video-vision/models 都沒有 ggml 格式模型）"
    state_set status "degraded"
    step2_whisper_openai_fallback
    return
  fi
  model_base=$(basename "$model_path")
  if [ "$model_base" != "ggml-medium.bin" ] && [ "$model_base" != "ggml-medium.en.bin" ]; then
    note "規格要求 whisper-cli medium 模型，本機沒有，改用可用模型：${model_base}（degraded：非規格指定模型）"
    state_set status "degraded"
  fi

  local wav="$WORKDIR/audio16k.wav"
  if [ ! -s "$wav" ]; then
    if ! ffmpeg -y -i "$WORKDIR/source.mp4" -ar 16000 -ac 1 -c:a pcm_s16le "$wav" \
        > "$WORKDIR/ffmpeg_extract.log" 2>&1; then
      state_set status "failed"
      state_set error "ffmpeg 抽音軌失敗，whisper 聽寫無法進行"
      echo "❌ ffmpeg 抽音軌失敗，見 $WORKDIR/ffmpeg_extract.log" >&2
      exit 1
    fi
  fi

  if ! whisper-cli -m "$model_path" -l auto -osrt -of "$WORKDIR/source" "$wav" \
      > "$WORKDIR/whisper.log" 2>&1; then
    note "whisper-cli 執行失敗，改走 OpenAI whisper-1 API"
    step2_whisper_openai_fallback
    return
  fi

  if [ -s "$WORKDIR/source.srt" ]; then
    printf 'auto' > "$WORKDIR/source.lang"
    state_set subtitle_source "whisper-cli:${model_base}"
    state_set path_source_srt "$WORKDIR/source.srt"
    state_set_step 3
    note "字幕來源: 本機 whisper-cli 聽寫 (model=${model_base})"
  else
    note "whisper-cli 沒有產出 srt，改走 OpenAI whisper-1 API"
    step2_whisper_openai_fallback
  fi
}

step2_whisper_openai_fallback() {
  local api_key
  api_key=$(read_env_var "OPENAI_API_KEY")
  if [ -z "$api_key" ]; then
    state_set status "degraded"
    state_set error "whisper-cli 不可用/模型缺，且找不到 OPENAI_API_KEY（${ENV_FILE}），字幕段卡住"
    note "❌ 無本機 whisper 模型也無 OpenAI API key，已保留下載的影片，字幕段卡住待人工處理"
    echo "❌ 字幕段卡住：${WORKDIR}（已下載影片，未取得字幕）" >&2
    exit 1
  fi

  local audio_mp3="$WORKDIR/audio.mp3"
  if [ ! -s "$audio_mp3" ]; then
    ffmpeg -y -i "$WORKDIR/source.mp4" -vn -ar 16000 -ac 1 -b:a 64k "$audio_mp3" \
      > "$WORKDIR/ffmpeg_mp3.log" 2>&1 || true
  fi
  if [ ! -s "$audio_mp3" ]; then
    state_set status "degraded"
    state_set error "ffmpeg 轉 mp3 失敗，OpenAI whisper-1 fallback 中止；已保留下載的影片"
    echo "❌ 字幕段卡住（ffmpeg 轉檔失敗）：$WORKDIR" >&2
    exit 1
  fi

  local size_bytes limit
  size_bytes=$(stat -f%z "$audio_mp3" 2>/dev/null || stat -c%s "$audio_mp3")
  limit=$((25*1024*1024))

  : > "$WORKDIR/source.srt"
  if [ "$size_bytes" -le "$limit" ]; then
    if ! curl -sf https://api.openai.com/v1/audio/transcriptions \
        -H "Authorization: Bearer $api_key" \
        -F model="whisper-1" -F response_format="srt" -F file=@"$audio_mp3" \
        -o "$WORKDIR/source.srt" 2> "$WORKDIR/openai_whisper.err"; then
      state_set status "failed"
      state_set error "OpenAI whisper-1 API 呼叫失敗，字幕段卡住"
      echo "❌ 字幕段卡住（OpenAI API 失敗）：$WORKDIR" >&2
      exit 1
    fi
  else
    note "音檔超過 25MB，分段呼叫 OpenAI whisper-1 API"
    # F14：duration_sec 原本用 ffprobe 抓音檔總長，但從未被使用（seg_time 是固定寫死
    # 的保守值），屬未用變數，直接刪除該行與其宣告。
    local seg_time offset idx seg seg_srt
    seg_time=$(python3 -c 'print(int(600))')  # 保守切 10 分鐘一段，實測 64kbps mp3 遠低於 25MB 上限
    rm -f "$WORKDIR"/seg_*.mp3
    ffmpeg -y -i "$audio_mp3" -f segment -segment_time "$seg_time" -c copy "$WORKDIR/seg_%03d.mp3" \
      > "$WORKDIR/ffmpeg_segment.log" 2>&1
    offset=0
    idx=0
    for seg in "$WORKDIR"/seg_*.mp3; do
      [ -e "$seg" ] || continue
      seg_srt="$WORKDIR/seg_${idx}.srt"
      # F11（MEDIUM）：任一分段轉錄失敗/空回傳一律整段 abort，不再用 `|| true` 吞掉
      # 錯誤繼續組出「看起來完整、實際缺段」的 source.srt，避免拿部分字幕誤導翻譯與上傳。
      if ! curl -sf https://api.openai.com/v1/audio/transcriptions \
          -H "Authorization: Bearer $api_key" \
          -F model="whisper-1" -F response_format="srt" -F file=@"$seg" \
          -o "$seg_srt" 2>> "$WORKDIR/openai_whisper.err"; then
        state_set status "degraded"
        state_set error "OpenAI whisper-1 分段轉錄第 $((idx+1)) 段失敗，為避免用部分字幕，整段 abort"
        echo "❌ OpenAI whisper-1 分段轉錄失敗（第 $((idx+1)) 段），已中止（不使用部分字幕）：$WORKDIR" >&2
        rm -f "$WORKDIR"/seg_*.mp3 "$WORKDIR/source.srt"
        exit 1
      fi
      if [ ! -s "$seg_srt" ]; then
        state_set status "degraded"
        state_set error "OpenAI whisper-1 分段轉錄第 $((idx+1)) 段回傳空檔，整段 abort"
        echo "❌ OpenAI whisper-1 分段轉錄空回傳（第 $((idx+1)) 段），已中止：$WORKDIR" >&2
        rm -f "$WORKDIR"/seg_*.mp3 "$WORKDIR/source.srt"
        exit 1
      fi
      python3 -c '
import sys
def shift(ts, offset_sec):
    h, m, rest = ts.split(":")
    s, ms = rest.split(",")
    total = int(h) * 3600 + int(m) * 60 + int(s) + offset_sec
    h2 = int(total // 3600)
    m2 = int((total % 3600) // 60)
    s2 = int(total % 60)
    return "%02d:%02d:%02d,%s" % (h2, m2, s2, ms)

path, offset_arg = sys.argv[1], float(sys.argv[2])
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()
out = []
for line in lines:
    if "-->" in line:
        a, b = line.split(" --> ")
        out.append(shift(a, offset_arg) + " --> " + shift(b, offset_arg))
    else:
        out.append(line)
print("\n".join(out))
' "$seg_srt" "$offset" >> "$WORKDIR/source.srt"
      printf '\n' >> "$WORKDIR/source.srt"
      offset=$(python3 -c 'print(float(sys.argv[1]) + float(sys.argv[2]))' "$offset" "$seg_time")
      idx=$((idx+1))
    done
  fi

  if [ -s "$WORKDIR/source.srt" ]; then
    printf 'auto' > "$WORKDIR/source.lang"
    state_set subtitle_source "openai-whisper-1-api"
    state_set path_source_srt "$WORKDIR/source.srt"
    state_set_step 3
    state_set status "degraded"
    note "字幕來源: OpenAI whisper-1 API（本機 whisper-cli 不可用，降級）"
  else
    state_set status "failed"
    state_set error "OpenAI whisper-1 API 也失敗，字幕段卡住"
    echo "❌ 字幕段卡住：$WORKDIR" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Step 3：翻譯斷點——產出 JSON flag 後 exit 0，等主 session 派 sonnet 子代理翻譯
# ---------------------------------------------------------------------------

# F13（LOW，處置＝改 JSON）：NEED_TRANSLATE.flag 從 key=value 純文字改成 JSON，
# 不再是可被 `source` 當 shell 腳本執行的格式——title 內容不會變成 shell 語法。
write_translate_flag() {
  local flag_file="$WORKDIR/NEED_TRANSLATE.flag" title source_sha256 source_segments
  title=$(state_get title)
  source_sha256=$(sha256_file "$WORKDIR/source.srt")
  source_segments=$(srt_segment_count "$WORKDIR/source.srt")
  jq -n \
    --arg source_srt "$WORKDIR/source.srt" \
    --arg target_zh_srt "$WORKDIR/zh.srt" \
    --arg target_done "$WORKDIR/TRANSLATE_DONE.json" \
    --arg video_id "$VIDEO_ID" \
    --arg title "$title" \
    --arg source_sha256 "$source_sha256" \
    --argjson source_segments "$source_segments" \
    '{
      source_srt: $source_srt,
      target_zh_srt: $target_zh_srt,
      target_done_marker: $target_done,
      video_id: $video_id,
      title: $title,
      source_sha256: $source_sha256,
      source_segments: $source_segments,
      instructions: "翻譯完成後：1) 把 zh.srt 寫到 target_zh_srt；2) 把 TRANSLATE_DONE.json 寫到 target_done_marker，內容需為 {\"source_sha256\": <與此檔 source_sha256 相同>, \"zh_segments\": <zh.srt 實際段數，需等於 source_segments>}；3) 用 --resume 續跑。三者缺一，翻譯閘不會放行。"
    }' > "$flag_file"
  state_set path_flag_file "$flag_file"
}

# F1（CRITICAL 翻譯閘）：--resume 進 Step4 前要求三件齊備——zh.srt 存在、
# TRANSLATE_DONE.json 存在且結構正確、zh.srt 段數與 source.srt 段數一致、
# source_sha256 對得上目前的 source.srt（防止 source.srt 被事後改動而驗證失效）。
# 任一條件不成立一律視為翻譯閘未通過，不放行。
check_translate_ready() {
  local done_file="$WORKDIR/TRANSLATE_DONE.json" zh_srt="$WORKDIR/zh.srt"
  local recorded_sha recorded_segments actual_sha source_segments zh_segments

  if [ ! -s "$zh_srt" ]; then
    return 1
  fi
  if [ ! -s "$done_file" ]; then
    echo "❌ 翻譯閘未通過：zh.srt 存在但缺 $done_file （需 {source_sha256, zh_segments}）" >&2
    return 1
  fi
  if ! jq empty "$done_file" 2>/dev/null; then
    echo "❌ TRANSLATE_DONE.json 不是合法 JSON: $done_file" >&2
    return 1
  fi

  recorded_sha=$(jq -r '.source_sha256 // empty' "$done_file")
  recorded_segments=$(jq -r '.zh_segments // empty' "$done_file")
  if [ -z "$recorded_sha" ] || [ -z "$recorded_segments" ]; then
    echo "❌ TRANSLATE_DONE.json 缺必要鍵 source_sha256/zh_segments: $done_file" >&2
    return 1
  fi

  actual_sha=$(sha256_file "$WORKDIR/source.srt")
  if [ "$recorded_sha" != "$actual_sha" ]; then
    echo "❌ 翻譯閘：TRANSLATE_DONE.json 記錄的 source_sha256 與目前 source.srt 不符（source.srt 可能被改動過），拒絕放行" >&2
    return 1
  fi

  source_segments=$(srt_segment_count "$WORKDIR/source.srt")
  zh_segments=$(srt_segment_count "$zh_srt")
  if [ "$zh_segments" != "$source_segments" ]; then
    echo "❌ 翻譯閘：zh.srt 段數($zh_segments) != source.srt 段數($source_segments)" >&2
    return 1
  fi
  if [ "$recorded_segments" != "$zh_segments" ]; then
    echo "❌ 翻譯閘：TRANSLATE_DONE.json 記錄的 zh_segments($recorded_segments) 與實際 zh.srt 段數($zh_segments) 不符" >&2
    return 1
  fi

  return 0
}

step3_pause_translate() {
  if [ ! -s "$WORKDIR/source.srt" ]; then
    state_set status "failed"
    state_set error "source.srt 不存在，無法建立翻譯斷點（Step2 可能未完成）"
    echo "❌ source.srt 不存在: $WORKDIR/source.srt" >&2
    exit 1
  fi

  if check_translate_ready; then
    note "翻譯閘通過：zh.srt 與 TRANSLATE_DONE.json 驗證一致（段數/sha256 皆符合）"
    state_set path_zh_srt "$WORKDIR/zh.srt"
    state_set_step 4
    return
  fi

  if [ -s "$WORKDIR/zh.srt" ]; then
    note "⚠️ zh.srt 已存在但翻譯閘驗證未通過（見上方錯誤），仍視為翻譯斷點，不放行 Step4"
  fi

  write_translate_flag
  state_set status "paused_need_translate"
  state_set_step 3
  echo "⏸ 翻譯斷點：$WORKDIR/NEED_TRANSLATE.flag（JSON 格式）"
  echo "   來源字幕: $WORKDIR/source.srt"
  echo "   請主 session 派 sonnet 子代理翻繁中，完成後："
  echo "     1) 把 zh.srt 放到: $WORKDIR/zh.srt"
  echo "     2) 寫 TRANSLATE_DONE.json 到: $WORKDIR/TRANSLATE_DONE.json（{\"source_sha256\":..., \"zh_segments\":...}）"
  echo "   （可選）繁中譯題放到: $WORKDIR/zh-title.txt；繁中描述放到: $WORKDIR/zh-desc.txt"
  echo "   續跑指令: bash $SCRIPT_DIR/relay.sh --resume $VIDEO_ID"
  exit 0
}

# ---------------------------------------------------------------------------
# Step 4：合成——ffmpeg 燒錄版 ＋ 軟字幕版（軟字幕版＝原檔，caption 另外掛）
# ---------------------------------------------------------------------------
step4_synthesize() {
  # F1 防線第二層：即使 state.step 因某種原因（手動編輯/舊 state）已經 >= 4，
  # 進 Step4 前再驗一次翻譯閘，未通過就退回翻譯斷點，不放行合成/上傳。
  if ! check_translate_ready; then
    note "Step4 防線：翻譯閘再次檢查未通過，退回翻譯斷點"
    step3_pause_translate
    return
  fi
  state_set path_zh_srt "$WORKDIR/zh.srt"

  note "Step4: 合成（format_mode=${FORMAT_MODE}）"
  case "$FORMAT_MODE" in
    both|burn)
      step4_burn
      ;;
    soft)
      note "soft-only 模式，略過燒錄"
      ;;
  esac
  state_set_step 5
}

step4_burn() {
  local burned="$WORKDIR/burned.mp4"
  if [ -s "$burned" ]; then
    note "burned.mp4 已存在，略過燒錄"
    state_set path_burned_mp4 "$burned"
    return
  fi
  # 用 subtitles=filename='<path>' 明確具名參數語法（而非 subtitles='<path>' 位置參數），
  # 未具名時 ffmpeg 對未知/未編譯 filter 會在「填參數」階段就丟 parse error，
  # 具名 filename= 才會正確走到「filter 不存在」這層乾淨錯誤，兩者親測有別。
  local escaped_srt burn_ffmpeg
  escaped_srt=$(escape_ffmpeg_subtitles_path "$WORKDIR/zh.srt")
  burn_ffmpeg=$(pick_burn_ffmpeg)
  note "燒錄使用: $burn_ffmpeg"
  if "$burn_ffmpeg" -y -i "$WORKDIR/source.mp4" -vf "subtitles=filename='${escaped_srt}'" -c:a copy "$burned" \
      > "$WORKDIR/ffmpeg_burn.log" 2>&1; then
    state_set path_burned_mp4 "$burned"
    note "燒錄完成: $burned （ffmpeg=${burn_ffmpeg}）"
  else
    note "⚠️ ffmpeg 燒錄失敗（ffmpeg=${burn_ffmpeg}），保留軟字幕版（原檔＋zh.srt caption），不整案報廢"
    if [ "$FORMAT_MODE" = "burn" ]; then
      FORMAT_MODE="soft"
      state_set format_mode "soft"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 5：上傳（videos.insert + captions.insert，交給 yt_relay_upload.py）
# ---------------------------------------------------------------------------
step5_upload() {
  note "Step5: 上傳（privacy=${PRIVACY}，dry_run=${DRY_RUN}）"
  local marker="$WORKDIR/upload-started.marker"
  local video_file
  case "$FORMAT_MODE" in
    burn)
      video_file="$WORKDIR/burned.mp4"
      if [ ! -s "$video_file" ]; then
        note "⚠️ burn 模式但 burned.mp4 不存在，改用 source.mp4"
        video_file="$WORKDIR/source.mp4"
      fi
      ;;
    *)
      video_file="$WORKDIR/source.mp4"
      ;;
  esac

  local title zh_title url channel desc_file title_file
  title=$(state_get title)
  url=$(state_get url)
  channel=$(state_get channel)
  zh_title="$title"
  if [ -s "$WORKDIR/zh-title.txt" ]; then
    zh_title=$(cat "$WORKDIR/zh-title.txt")
    state_set path_zh_title_txt "$WORKDIR/zh-title.txt"
  fi

  desc_file="$WORKDIR/description.txt"
  {
    printf '原始影片：%s（%s）\n\n' "$url" "$channel"
    if [ -s "$WORKDIR/zh-desc.txt" ]; then
      cat "$WORKDIR/zh-desc.txt"
    fi
  } > "$desc_file"

  title_file="$WORKDIR/upload_title.txt"
  printf '%s' "$zh_title" > "$title_file"

  # F3（HIGH）：--dry-run（或 env YT_RELAY_NO_UPLOAD=1）到這裡為止全部真做（下載/字幕/翻譯/
  # 合成/檔案準備），只有 Step5 這一步改成印出將送出的 payload，完全不呼叫 YouTube API，
  # 也不寫 upload-started.marker（純測試可以重複跑，不會被鎖）。
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Step5(dry-run): 不呼叫 YouTube API，僅印出將送出的 payload"
    echo "--- DRY RUN payload（不會真的上傳）---"
    jq -n \
      --arg video "$video_file" \
      --arg title "$zh_title" \
      --arg desc "$(cat "$desc_file")" \
      --arg privacy "$PRIVACY" \
      --arg caption "$WORKDIR/zh.srt" \
      --arg caption_lang "zh-Hant" \
      --arg category "27" \
      '{video:$video, title:$title, description:$desc, privacy:$privacy, caption:$caption, caption_lang:$caption_lang, category:$category}'
    echo "--- 以上為 dry-run，未呼叫任何 API，未寫 upload-started.marker ---"
    state_set status "dry_run_ok"
    return
  fi

  # F2（CRITICAL 鎖）：step5 開始前寫 upload-started.marker；已存在就拒絕重跑
  # （除非 --force-reupload），防止資料損毀/誤 resume 導致同一支影片重複上傳。
  if [ -s "$marker" ] && [ "$FORCE_REUPLOAD" -ne 1 ]; then
    echo "❌ 偵測到先前已啟動過上傳（$marker 存在）。若確定要重傳（例如先前上傳確認徹底失敗、未產生任何影片），加 --force-reupload。" >&2
    exit 1
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$marker"

  local upload_rc
  set +e
  python3 "$SCRIPT_DIR/yt_relay_upload.py" upload \
      --video "$video_file" \
      --title-file "$title_file" \
      --desc-file "$desc_file" \
      --privacy "$PRIVACY" \
      --caption "$WORKDIR/zh.srt" \
      --caption-lang "zh-Hant" \
      --category 27 \
      --uploaded-id-file "$WORKDIR/uploaded_id" \
      --out "$WORKDIR/upload_result.json"
  upload_rc=$?
  set -e

  case "$upload_rc" in
    0) ;;
    3)
      note "⚠️ 影片已上傳但字幕未成功掛載（exit 3 = completed_no_captions），需事後手動補掛"
      ;;
    *)
      state_set status "failed"
      state_set error "上傳失敗（可能配額爆或憑證問題），本地成品已保留"
      note "❌ 上傳失敗，本地成品保留在 $WORKDIR"
      echo "❌ 上傳失敗，本地成品保留在 $WORKDIR" >&2
      exit 1
      ;;
  esac

  local vid_url uploaded_id
  vid_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("video_url",""))' "$WORKDIR/upload_result.json")
  uploaded_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("video_id",""))' "$WORKDIR/upload_result.json")

  # F7：字幕沒掛上不算一般 completed，落地成 completed_no_captions。
  if [ "$upload_rc" -eq 3 ]; then
    state_set status "completed_no_captions"
  else
    state_set status "completed"
  fi
  state_set uploaded_video_url "$vid_url"
  state_set uploaded_id "$uploaded_id"
  state_set_step 6

  if [ "$upload_rc" -eq 3 ]; then
    echo "✅ 上傳完成（⚠️ 字幕未掛載成功，需事後手動補掛）: $vid_url (${PRIVACY})"
  else
    echo "✅ 上傳完成: $vid_url (${PRIVACY})"
  fi
  # F10：轉公開提示改印 uploaded_id（YouTube 回應的真實 video id），
  # 不再印來源影片的 $VIDEO_ID （原本兩者常一樣，但邏輯上是不同東西，遇到轉碼/
  # 特殊來源 id 時會印錯）。
  echo "   使用者過目後說「轉公開」再跑: python3 $SCRIPT_DIR/yt_relay_upload.py --update-privacy $uploaded_id public"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local YT_URL="" RESUME_ID="" PRIVACY="unlisted" FORMAT_MODE="both"
  YT_CHANNEL_TOKEN="${YT_RELAY_TOKEN:-$HOME/.config/yt-sub-translate/token.json}"
  local DRY_RUN=0 APPROVE_UPLOAD=0 FORCE_REUPLOAD=0 RESTART=0
  # #5（resume 覆寫 bug）：追蹤 CLI 是否「明確」指定了 --privacy/--burn/--soft-only，
  # 之後 --resume（或撞到既有 state.json）時才知道要不要用 CLI 值覆寫 state.json 裡
  # 記錄的既有設定，而不是每次都用這裡的預設值把 state 存的設定悄悄蓋掉。
  local PRIVACY_SET=0 FORMAT_MODE_SET=0

  if [ "$#" -eq 0 ]; then
    usage
    exit 2
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resume)
        if [ "$#" -lt 2 ]; then echo "❌ --resume 需要接 video_id" >&2; exit 2; fi
        RESUME_ID="$2"; shift 2 ;;
      --privacy)
        if [ "$#" -lt 2 ]; then echo "❌ --privacy 需要接 unlisted|public|private" >&2; exit 2; fi
        PRIVACY="$2"; PRIVACY_SET=1; shift 2 ;;
      --burn)
        FORMAT_MODE="burn"; FORMAT_MODE_SET=1; shift ;;
      --soft-only)
        FORMAT_MODE="soft"; FORMAT_MODE_SET=1; shift ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      --approve-upload)
        APPROVE_UPLOAD=1; shift ;;
      --channel)
        case "${2:-}" in
          yourchannel) YT_CHANNEL_TOKEN="$HOME/.config/yt-sub-translate/token.json" ;;
          yourchannel2) YT_CHANNEL_TOKEN="$HOME/.config/yt-sub-translate/token-yourchannel2.json" ;;
          *) echo "❌ --channel 只支援 yourchannel|yourchannel2" >&2; exit 2 ;;
        esac
        shift 2 ;;
      --force-reupload)
        FORCE_REUPLOAD=1; shift ;;
      --restart)
        RESTART=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      -*)
        echo "❌ 未知參數: $1" >&2
        usage
        exit 2 ;;
      *)
        if [ -z "$YT_URL" ]; then
          YT_URL="$1"
        else
          echo "❌ 多餘參數: $1" >&2
          exit 2
        fi
        shift ;;
    esac
  done

  if [ "${YT_RELAY_NO_UPLOAD:-0}" = "1" ]; then
    DRY_RUN=1
  fi

  if [ -z "$YT_URL" ] && [ -z "$RESUME_ID" ]; then
    usage
    exit 2
  fi

  case "$PRIVACY" in
    unlisted|public|private) ;;
    *) echo "❌ --privacy 必須是 unlisted|public|private，收到: $PRIVACY" >&2; exit 2 ;;
  esac

  # F9（MEDIUM）：relay.sh 不接受 --privacy public。搬運內容一律先 unlisted 過目，
  # 要轉公開走事後的 yt_relay_upload.py --update-privacy（明確的第二道動作，不是
  # 一個 CLI flag 就能一步到位公開別人的內容重傳版本）。
  if [ "$PRIVACY" = "public" ]; then
    echo "❌ relay.sh 不接受 --privacy public：初次上傳一律先 unlisted 過目，要轉公開請跑: python3 $SCRIPT_DIR/yt_relay_upload.py --update-privacy <uploaded_video_id> public" >&2
    exit 2
  fi

  mkdir -p "$WORK_ROOT"

  local VIDEO_ID WORKDIR STATE_FILE URL

  if [ -n "$RESUME_ID" ]; then
    VIDEO_ID="$RESUME_ID"
    WORKDIR="$WORK_ROOT/$VIDEO_ID"
    STATE_FILE="$WORKDIR/state.json"
    # #1（lock 時序修正）：一知道 WORKDIR 立刻上鎖，早於 --restart 的 init_state
    # 與 --resume 的 validate_state_schema/state_get/state_set 等所有 state 存取。
    acquire_lock

    if [ "$RESTART" -eq 1 ]; then
      if [ -z "$YT_URL" ]; then
        echo "❌ --restart 需同時提供原始 <YT_URL> 以重建 state.json（既有產出檔案會被沿用，不必重下載）" >&2
        exit 1
      fi
      init_state "$VIDEO_ID" "$YT_URL" "$WORKDIR"
      URL="$YT_URL"
      note "⚠️ --restart：state.json 已重建（既有產出檔案如 source.mp4/source.srt/zh.srt 若存在，後續步驟會偵測並沿用）"
    else
      if [ ! -s "$STATE_FILE" ]; then
        echo "❌ 找不到 $STATE_FILE ，無法 --resume（先用 <YT_URL> 開新流程，或帶 <YT_URL> --resume $VIDEO_ID --restart 重建）" >&2
        exit 1
      fi
      if ! validate_state_schema "$STATE_FILE"; then
        echo "❌ state.json 損毀或必要鍵不齊全: $STATE_FILE" >&2
        echo "   指示: bash $SCRIPT_DIR/relay.sh <原始 YT_URL> --resume $VIDEO_ID --restart 重建" >&2
        exit 1
      fi
      URL=$(state_get url)
      # #5：CLI 沒明確帶 --privacy/--burn/--soft-only 就不覆寫，從 state 讀回既有設定。
      sync_privacy_format_with_state
    fi
  else
    local tmp_meta tmp_err
    tmp_meta="$WORK_ROOT/.pending-$$.json"
    tmp_err="$WORK_ROOT/.pending-$$.err"
    if ! yt-dlp --no-warnings --dump-json --skip-download "$YT_URL" > "$tmp_meta" 2> "$tmp_err"; then
      echo "❌ 無法解析網址或抓取影片資訊: $YT_URL" >&2
      tail -10 "$tmp_err" >&2 2>/dev/null || true
      rm -f "$tmp_meta" "$tmp_err"
      exit 1
    fi
    rm -f "$tmp_err"

    VIDEO_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$tmp_meta")
    if [ -z "$VIDEO_ID" ]; then
      echo "❌ 抓不到 video_id，URL 可能無效: $YT_URL" >&2
      rm -f "$tmp_meta"
      exit 1
    fi

    WORKDIR="$WORK_ROOT/$VIDEO_ID"
    STATE_FILE="$WORKDIR/state.json"
    # #1（lock 時序修正）：剛算出 video_id/WORKDIR 就立刻上鎖，早於 state.json
    # 存在性檢查與 init_state/mv meta.json 等寫入（video_id 是靠 yt-dlp dump-json
    # 算出來的，這步不碰任何 workdir 的 state，鎖不了也不用鎖）。
    acquire_lock

    if [ -s "$STATE_FILE" ]; then
      echo "ℹ️ state.json 已存在，視為續跑既有進度: $STATE_FILE"
      if ! validate_state_schema "$STATE_FILE"; then
        echo "❌ state.json 損毀或必要鍵不齊全: $STATE_FILE" >&2
        echo "   指示: bash $SCRIPT_DIR/relay.sh $YT_URL --resume $VIDEO_ID --restart 重建" >&2
        rm -f "$tmp_meta"
        exit 1
      fi
      URL=$(state_get url)
      # #5：同一個 bug 在「用原 URL 撞到既有 state.json」這條路徑一樣存在，一併修。
      sync_privacy_format_with_state
      rm -f "$tmp_meta"
    else
      init_state "$VIDEO_ID" "$YT_URL" "$WORKDIR"
      URL="$YT_URL"
      mv -f "$tmp_meta" "$WORKDIR/meta.json"
    fi
  fi

  local CUR_STEP CUR_STATUS
  CUR_STATUS=$(state_get status)
  if [ "$CUR_STATUS" = "completed" ] || [ "$CUR_STATUS" = "completed_no_captions" ]; then
    echo "ℹ️ 這支影片已完成上傳: $(state_get uploaded_video_url)（status=${CUR_STATUS}）"
    exit 0
  fi

  CUR_STEP=$(state_get step)
  if [ "$CUR_STEP" -le 1 ]; then step1_download; fi
  CUR_STEP=$(state_get step)
  if [ "$CUR_STEP" -le 2 ]; then step2_subtitles; fi
  CUR_STEP=$(state_get step)
  if [ "$CUR_STEP" -le 3 ]; then step3_pause_translate; fi
  # #6（step=5 旁路修正）：Step4 合成一律呼叫，不再用 `if [ "$CUR_STEP" -le 4 ]` 當
  # 唯一守門——state.step 這個數字本身可能被竄改、或殘留自一個半殘/舊版流程，一旦它
  # 已經是 5，舊寫法會整個跳過這次呼叫，讓 step4_synthesize() 內建的翻譯閘再驗證
  # （F1 防線第二層）形同虛設，直接讓 --resume 衝進 Step5 上傳批准畫面。
  # 改成無條件呼叫：閘門條件（check_translate_ready）每次都實檢，不信任 state 的
  # step 數字。對已經完成合成的情況是 idempotent（burned.mp4 已存在就略過燒錄），
  # 不會重複做工。
  step4_synthesize

  CUR_STEP=$(state_get step)
  if [ "$CUR_STEP" -le 5 ]; then
    # F1（CRITICAL）：Step4 完成後，沒有 --approve-upload（且不是 --dry-run）
    # 就停在這裡，不自動進 Step5 實際上傳——2026-07-03 事故（測試續跑直通上傳段，
    # 垃圾影片真的上了頻道）就是這個閘沒守住。
    if [ "$APPROVE_UPLOAD" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
      state_set status "awaiting_upload_approval"
      echo "⏸ Step4 已完成，尚未上傳（需要 --approve-upload 才會進入 Step5 實際上傳）。"
      echo "   工作目錄: $WORKDIR"
      echo "   核可後執行: bash $SCRIPT_DIR/relay.sh --resume $VIDEO_ID --approve-upload"
      echo "   純測試不想真上傳: bash $SCRIPT_DIR/relay.sh --resume $VIDEO_ID --dry-run"
      exit 0
    fi
    step5_upload
  fi

  echo "🎉 全流程完成。工作目錄: $WORKDIR"
}

main "$@"
