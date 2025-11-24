#!/usr/bin/env bash
# Magic Stream 直播推流腳本
VERSION="0.5.1"

BASE_DIR="/root/magic_stream"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$LOG_DIR"

# 顏色
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[96m"
C_GREEN="\033[92m"
C_YELLOW="\033[93m"
C_MAGENTA="\033[95m"
C_RED="\033[91m"

pause() {
  echo
  read -rp "按 Enter 返回主選單..." _
}

print_header() {
  clear
  echo -e "${C_CYAN}============================================================${C_RESET}"
  echo -e "${C_BOLD}${C_GREEN}  Magic Stream 直播推流腳本${C_RESET}"
  echo -e "${C_DIM}  v${VERSION}  -  MagicNewMusic Lab${C_RESET}"
  echo -e "${C_CYAN}============================================================${C_RESET}"
  echo
  if [ -n "$1" ]; then
    echo -e ">> ${C_BOLD}$1${C_RESET}"
    echo
  fi
}

check_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${C_RED}缺少依賴：$1${C_RESET}"
    echo "請先執行：apt-get update && apt-get install -y $1"
    exit 1
  fi
}

init_env() {
  check_bin screen
  check_bin ffmpeg
  check_bin ffprobe
}

gen_screen_name() {
  local prefix="$1"
  local n
  while true; do
    n=$(printf "%02d" $((RANDOM % 90 + 10)))
    if ! screen -ls 2>/dev/null | grep -q "${prefix}_${n}"; then
      echo "${prefix}_${n}"
      return
    fi
  done
}

start_probe_stream() {
  local mode_label="$1"
  local prefix="$2"

  print_header "$mode_label"

  echo "來源可以是抖音、B 錄播、任何支持的直播 URL。"
  echo

  read -rp "輸入來源直播 URL: " src_url
  if [ -z "$src_url" ]; then
    echo "來源 URL 不能為空。"
    pause
    return
  fi

  read -rp "輸入 YouTube 推流 RTMP URL: " rtmp_url
  if [ -z "$rtmp_url" ]; then
    echo "RTMP URL 不能為空。"
    pause
    return
  fi

  read -rp "輸入直播標題（僅備註用，可留空）: " title

  read -rp "探針檢測間隔（秒，預設 30）: " probe_interval
  probe_interval=${probe_interval:-30}

  read -rp "無訊號自動結束秒數（預設 300，填 0 代表永不自動結束）: " stop_timeout
  stop_timeout=${stop_timeout:-300}

  local screen_name
  screen_name=$(gen_screen_name "$prefix")
  local log_file="$LOG_DIR/${screen_name}.log"

  echo
  echo "即將啟動 ${mode_label}:"
  echo "  來源: $src_url"
  echo "  推流: $rtmp_url"
  echo "  標題: ${title:-<未設定>}"
  echo "  探針間隔: ${probe_interval}s"
  if [ "$stop_timeout" -eq 0 ] 2>/dev/null; then
    echo "  無訊號結束: 不自動結束（需手動關閉 screen）"
  else
    echo "  無訊號結束: ${stop_timeout}s 連續無畫面視為本場結束"
  fi
  echo "  screen 名稱: $screen_name"
  echo "  日誌檔案: $log_file"
  echo

  read -rp "確認啟動？ (y/n): " confirm
  if [ "$confirm" != "y" ]; then
    echo "已取消。"
    pause
    return
  fi

  screen -dmS "$screen_name" bash -lc '
LOG_FILE="'"$log_file"'"
SRC_URL="'"$src_url"'"
RTMP_URL="'"$rtmp_url"'"
PROBE_INTERVAL='"$probe_interval"'
STOP_TIMEOUT='"$stop_timeout"'

echo "==============================================" >> "$LOG_FILE" 2>&1
echo "[info] Magic Stream probe-loop 開始運行" >> "$LOG_FILE" 2>&1
echo "[info] 來源: $SRC_URL" >> "$LOG_FILE" 2>&1
echo "[info] 目標: $RTMP_URL" >> "$LOG_FILE" 2>&1
echo "[info] 探針間隔: ${PROBE_INTERVAL}s, 無訊號超時: ${STOP_TIMEOUT}s" >> "$LOG_FILE" 2>&1

last_ok=$(date +%s)

while true; do
  now=$(date +%s)

  ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$SRC_URL" >> "$LOG_FILE" 2>&1
  probe_status=$?

  if [ $probe_status -eq 0 ]; then
    echo "[info] 探針 OK，啟動 ffmpeg 推流..." >> "$LOG_FILE" 2>&1
    last_ok=$now

    ffmpeg -re -i "$SRC_URL" -c copy -f flv "$RTMP_URL" >> "$LOG_FILE" 2>&1
    exit_code=$?
    echo "[warn] ffmpeg 結束，狀態碼: $exit_code，5 秒後重新檢測來源..." >> "$LOG_FILE" 2>&1
    sleep 5
    continue
  fi

  echo "[warn] 探針失敗，來源暫時無訊號。" >> "$LOG_FILE" 2>&1

  if [ "$STOP_TIMEOUT" -gt 0 ] 2>/dev/null; then
    diff=$(( now - last_ok ))
    if [ $diff -ge "$STOP_TIMEOUT" ]; then
      echo "[info] 連續無訊號已達 ${STOP_TIMEOUT}s，自動結束本次任務。" >> "$LOG_FILE" 2>&1
      break
    fi
  fi

  sleep "$PROBE_INTERVAL"
done

echo "[info] Magic Stream probe-loop 結束。" >> "$LOG_FILE" 2>&1
'

  echo
  echo -e "${C_GREEN}已在後台 screen 啟動：${C_BOLD}$screen_name${C_RESET}"
  echo "可在主選單 4. 查看當前 screen / 5. 查看日誌，或在 6. 關閉指定 screen。"
  pause
}

start_vod_loop() {
  print_header "檔案輪播模式 (VOD)"

  read -rp "輸入要輪播的影片檔完整路徑: " file_path
  if [ ! -f "$file_path" ]; then
    echo "檔案不存在：$file_path"
    pause
    return
  fi

  read -rp "輸入目標推流 RTMP URL: " rtmp_url
  if [ -z "$rtmp_url" ]; then
    echo "RTMP URL 不能為空。"
    pause
    return
  fi

  local screen_name
  screen_name=$(gen_screen_name "ms_vod")
  local log_file="$LOG_DIR/${screen_name}.log"

  echo
  echo "即將啟動 檔案輪播 (VOD):"
  echo "  檔案: $file_path"
  echo "  推流: $rtmp_url"
  echo "  screen 名稱: $screen_name"
  echo "  日誌檔案: $log_file"
  echo

  read -rp "確認啟動？ (y/n): " confirm
  if [ "$confirm" != "y" ]; then
    echo "已取消。"
    pause
    return
  fi

  screen -dmS "$screen_name" bash -lc '
LOG_FILE="'"$log_file"'"
FILE_PATH="'"$file_path"'"
RTMP_URL="'"$rtmp_url"'"

echo "==============================================" >> "$LOG_FILE" 2>&1
echo "[info] Magic Stream VOD loop 開始運行" >> "$LOG_FILE" 2>&1
echo "[info] 檔案: $FILE_PATH" >> "$LOG_FILE" 2>&1
echo "[info] 目標: $RTMP_URL" >> "$LOG_FILE" 2>&1

while true; do
  ffmpeg -re -stream_loop -1 -i "$FILE_PATH" -c copy -f flv "$RTMP_URL" >> "$LOG_FILE" 2>&1
  exit_code=$?
  echo "[warn] ffmpeg 意外結束 (code=$exit_code)，5 秒後重啟..." >> "$LOG_FILE" 2>&1
  sleep 5
done
'

  echo
  echo -e "${C_GREEN}已在後台 screen 啟動：${C_BOLD}$screen_name${C_RESET}"
  pause
}

list_screens() {
  print_header "當前 screen 會話"

  screen -ls || true
  echo
  echo -e "${C_DIM}提示：Magic Stream 相關名稱一般為：ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
  pause
}

stop_screen() {
  print_header "關閉指定 screen 會話"

  screen -ls || true
  echo
  read -rp "輸入要關閉的 screen 名稱（例如 ms_auto_01）: " name
  if [ -z "$name" ]; then
    echo "未輸入名稱。"
    pause
    return
  fi

  if screen -ls 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
    screen -S "$name" -X quit
    echo "已發送退出信號給：$name"
  else
    echo "找不到名為 $name 的 screen 會話。"
  fi

  pause
}

view_log() {
  print_header "查看日誌"

  echo "現有日誌檔："
  ls -1 "$LOG_DIR" 2>/dev/null | sed 's/^/  - /'
  echo
  read -rp "輸入要查看的日誌檔名（例如 ms_auto_01.log）: " log
  if [ -z "$log" ]; then
    pause
    return
  fi

  local path="$LOG_DIR/$log"
  if [ ! -f "$path" ]; then
    echo "檔案不存在：$path"
    pause
    return
  fi

  echo
  echo "===== tail -n 100 $path ====="
  tail -n 100 "$path"
  echo

  read -rp "要持續跟隨日誌輸出嗎？(y/n): " follow
  if [ "$follow" = "y" ]; then
    echo "按 Ctrl+C 結束查看。"
    sleep 1
    tail -n 20 -f "$path"
  fi
}

main_menu() {
  init_env
  while true; do
    print_header
    cat <<EOF
  1) 自動轉播（含探針待機）
  2) 手動轉播（任意來源 URL，同樣含探針）
  3) 檔案輪播 (VOD)
  4) 查看當前 screen 會話
  5) 查看日誌
  6) 關閉指定 screen
  0) 退出腳本
EOF
    echo
    read -rp "請輸入選項： " choice
    case "$choice" in
      1) start_probe_stream "自動轉播" "ms_auto" ;;
      2) start_probe_stream "手動轉播" "ms_manual" ;;
      3) start_vod_loop ;;
      4) list_screens ;;
      5) view_log ;;
      6) stop_screen ;;
      0) clear; exit 0 ;;
      *) echo "無效選項，請重新輸入。"; sleep 1 ;;
    esac
  done
}

main_menu
