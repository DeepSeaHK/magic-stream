#!/usr/bin/env bash

# Magic Stream 主腳本 v0.4.0

# ========= 全局設置 =========
BASE_DIR="$HOME/magic_stream"
LOG_DIR="$BASE_DIR/logs"
VOD_DIR="$BASE_DIR/vod"
YTAUTH_DIR="$BASE_DIR/youtube_auth"
RUN_DIR="$BASE_DIR/run"

RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

VERSION="v0.4.0"

# 顏色
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# sudo 判斷
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

mkdir -p "$LOG_DIR" "$VOD_DIR" "$YTAUTH_DIR" "$RUN_DIR"

# ========= 通用小工具 =========

pause() {
  echo
  read -rp "按回車鍵返回..." _
}

invalid_option() {
  echo -e "${YELLOW}無效選項，請重新輸入。${RESET}"
  pause
}

# 秒數 -> HH:MM:SS
format_seconds() {
  local total="$1"
  local h=$(( total / 3600 ))
  local m=$(( (total % 3600) / 60 ))
  local s=$(( total % 60 ))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

# 取得下一個短 screen 名稱索引：vod_01、manual_01 這樣
next_index() {
  local type="$1"
  local file="$RUN_DIR/${type}_index"
  local idx=0
  if [ -f "$file" ]; then
    idx=$(cat "$file" 2>/dev/null || echo 0)
  fi
  idx=$((idx + 1))
  echo "$idx" > "$file"
  printf "%02d" "$idx"
}

# ========= 4. 推流進程管理相關 =========

list_screens() {
  clear
  echo -e "${CYAN}Magic Stream -> 4.1 所有 screen 會話${RESET}"
  echo
  # 沒有會話時 screen -ls 會返回非零，因此加上 || true
  screen -ls || true
  pause
}

show_stream_status() {
  clear
  echo -e "${CYAN}Magic Stream -> 4.2 推流狀態總覽${RESET}"
  echo

  # 只取 screen 名稱部分，例如 "  1234.ms_vod_01 (Detached)" -> ms_vod_01
  local screen_names
  screen_names=$(screen -ls 2>/dev/null | sed -n 's/^[[:space:]]\+[0-9]\+\.\([^.[:space:]]\+\).*/\1/p')

  if [ -z "$screen_names" ]; then
    echo "目前沒有任何 Magic Stream 推流進程在運行。"
    pause
    return
  fi

  local now
  now=$(date +%s)
  local idx=1

  for name in $screen_names; do
    # 只處理我們自己的會話
    if [[ "$name" != ms_* ]]; then
      continue
    fi

    local type="[其他]"
    if [[ "$name" == ms_vod_* ]]; then
      type="[文件推流]"
    elif [[ "$name" == ms_manual_* ]]; then
      type="[手動轉播]"
    elif [[ "$name" == ms_auto_* ]]; then
      type="[自動推流]"
    fi

    # 已運行時間：用日誌文件建立時間估算
    local log_file="$LOG_DIR/${name}.log"
    local elapsed="未知"
    if [ -f "$log_file" ]; then
      local start_ts
      start_ts=$(stat -c %Y "$log_file" 2>/dev/null || echo "")
      if [ -n "$start_ts" ]; then
        local diff=$(( now - start_ts ))
        elapsed=$(format_seconds "$diff")
      fi
    fi

    # 循環設定
    local loop_info="未知"
    if [ -f "$RUN_DIR/${name}.loop" ]; then
      local loop_cfg
      loop_cfg=$(cat "$RUN_DIR/${name}.loop")
      if [ "$loop_cfg" = "0" ] || [ "$loop_cfg" = "-1" ]; then
        loop_info="無限循環"
      else
        loop_info="預設循環 ${loop_cfg} 次"
      fi
    fi

    # 最近一行日誌（截斷一下避免太長）
    local last_line=""
    if [ -f "$log_file" ]; then
      last_line=$(tail -n 1 "$log_file")
      last_line=${last_line:0:100}
    fi

    echo "[$idx] $type  $name"
    echo "    已運行時間：$elapsed"
    echo "    循環設定：$loop_info"
    if [ -n "$last_line" ]; then
      echo "    最近日誌：$last_line"
    fi
    echo

    idx=$((idx + 1))
  done

  pause
}

attach_screen() {
  clear
  echo -e "${CYAN}Magic Stream -> 4.3 進入指定 screen${RESET}"
  echo
  screen -ls || true
  echo
  read -rp "輸入要進入的 screen 名稱（例如 ms_vod_01）： " name
  if [ -z "$name" ]; then
    echo "未輸入名稱。"
    pause
    return
  fi
  screen -r "$name"
}

kill_screen() {
  clear
  echo -e "${CYAN}Magic Stream -> 4.4 結束指定 screen${RESET}"
  echo
  screen -ls || true
  echo
  read -rp "輸入要結束的 screen 名稱（例如 ms_vod_01）： " name
  if [ -z "$name" ]; then
    echo "未輸入名稱。"
    pause
    return
  fi
  screen -S "$name" -X quit || true
  echo "已嘗試結束 screen：$name"
  pause
}

manage_screen_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 4. 推流進程管理${RESET}"
    echo "1. 查看所有 screen 會話（原始列表）"
    echo "2. 查看推流狀態（簡潔總覽）"
    echo "3. 進入指定 screen（查看完整 ffmpeg 輸出）"
    echo "4. 結束指定 screen（等於結束該路直播）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇：" choice
    case "$choice" in
      1) list_screens ;;
      2) show_stream_status ;;
      3) attach_screen ;;
      4) kill_screen ;;
      0) break ;;
      *) invalid_option ;;
    esac
  done
}

# ========= 2. 文件推流 =========

file_stream_menu() {
  clear
  echo -e "${CYAN}Magic Stream -> 2. 文件推流${RESET}"
  echo "請先把視頻放到：$VOD_DIR"
  echo
  read -rp "請輸入需要直播的文件名（含擴展名）： " file_name
  if [ -z "$file_name" ]; then
    echo "文件名不能為空。"
    pause
    return
  fi
  if [ ! -f "$VOD_DIR/$file_name" ]; then
    echo -e "${RED}找不到文件：$VOD_DIR/$file_name${RESET}"
    pause
    return
  fi

  local default_rtmp="rtmp://a.rtmp.youtube.com/live2"
  echo "默認平台：YouTube ($default_rtmp)"
  read -rp "請輸入直播碼（只填 key）： " stream_key
  if [ -z "$stream_key" ]; then
    echo "直播碼不能為空。"
    pause
    return
  fi

  read -rp "如需自定 RTMP 前綴，輸入（留空=默認 $default_rtmp）： " rtmp_prefix
  if [ -z "$rtmp_prefix" ]; then
    rtmp_prefix="$default_rtmp"
  fi

  read -rp "請輸入直播時間（秒）（0=按文件時長自動結束）： " duration
  duration=${duration:-0}

  read -rp "請輸入循環次數（0=無限循環）： " loop_times
  loop_times=${loop_times:-0}

  local stream_loop_arg
  local loop_record="$loop_times"
  if [ "$loop_times" -le 0 ] 2>/dev/null; then
    stream_loop_arg="-1"
    loop_record="0"
  else
    # ffmpeg 的含義是「額外重播 N 次」，所以要減 1
    stream_loop_arg=$((loop_times - 1))
  fi

  local target="${rtmp_prefix%/}/$stream_key"

  local idx
  idx=$(next_index "vod")
  local screen_name="ms_vod_${idx}"
  local log_file="$LOG_DIR/${screen_name}.log"

  # 記錄循環設定，供狀態查詢使用
  echo "$loop_record" > "$RUN_DIR/${screen_name}.loop"

  # 組合 ffmpeg 命令
  local ffmpeg_cmd="ffmpeg -re -stream_loop ${stream_loop_arg} -i \"$VOD_DIR/$file_name\" -c:v copy -c:a copy"

  if [ "$duration" -gt 0 ] 2>/dev/null; then
    ffmpeg_cmd+=" -t $duration"
  fi

  ffmpeg_cmd+=" -f flv \"$target\" 2>&1 | tee \"$log_file\""

  clear
  echo -e "${CYAN}Magic Stream -> 2. 文件推流${RESET}"
  echo "文件：$VOD_DIR/$file_name"
  echo "推流目標：$target"
  echo "screen 會話名：$screen_name"
  echo "日誌文件：$log_file"
  echo
  echo "ffmpeg 命令："
  echo "$ffmpeg_cmd"
  echo
  read -rp "確認開始文件推流？(y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消。"
    pause
    return
  fi

  # 在 screen 中後台啟動
  screen -S "$screen_name" -dm bash -lc "$ffmpeg_cmd"
  echo
  echo -e "${GREEN}已在 screen 後台啟動推流。${RESET}"
  echo "使用 4. 推流進程管理 可以查看或結束該路直播。"
  pause
}

# ========= 1. 轉播推流（暫時簡化版） =========

manual_relay() {
  clear
  echo -e "${CYAN}Magic Stream -> 1.1 手動轉播${RESET}"
  echo
  read -rp "請輸入直播源地址（rtmp:// 或 http(s)://m3u8 等）： " src_url
  if [ -z "$src_url" ]; then
    echo "直播源地址不能為空。"
    pause
    return
  fi

  local default_rtmp="rtmp://a.rtmp.youtube.com/live2"
  echo "默認平台：YouTube ($default_rtmp)"
  read -rp "請輸入直播碼（只填 key）： " stream_key
  if [ -z "$stream_key" ]; then
    echo "直播碼不能為空。"
    pause
    return
  fi
  read -rp "如需自定 RTMP 前綴，輸入（留空=默認 $default_rtmp）： " rtmp_prefix
  if [ -z "$rtmp_prefix" ]; then
    rtmp_prefix="$default_rtmp"
  fi

  local target="${rtmp_prefix%/}/$stream_key"

  local idx
  idx=$(next_index "manual")
  local screen_name="ms_manual_${idx}"
  local log_file="$LOG_DIR/${screen_name}.log"

  # 現階段先做一次性推流，有需要再升級成自動重連
  local ffmpeg_cmd="ffmpeg -re -i \"$src_url\" -c:v copy -c:a copy -f flv \"$target\" 2>&1 | tee \"$log_file\""

  clear
  echo -e "${CYAN}Magic Stream -> 1.1 手動轉播${RESET}"
  echo "源地址：$src_url"
  echo "推流目標：$target"
  echo "screen 會話名：$screen_name"
  echo "日誌文件：$log_file"
  echo
  echo "ffmpeg 命令："
  echo "$ffmpeg_cmd"
  echo
  read -rp "確認開始轉播？(y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消。"
    pause
    return
  fi

  screen -S "$screen_name" -dm bash -lc "$ffmpeg_cmd"
  echo
  echo -e "${GREEN}已在 screen 後台啟動手動轉播。${RESET}"
  echo "使用 4. 推流進程管理 可以查看或結束該路直播。"
  pause
}

auto_relay() {
  clear
  echo -e "${CYAN}Magic Stream -> 1.2 自動推流（YouTube API）${RESET}"
  echo "注意：需要事先在 $YTAUTH_DIR 放入 client_secret.json 和 token.json"
  echo

  if [ ! -d "$BASE_DIR/venv" ]; then
    echo -e "${RED}找不到 Python venv：$BASE_DIR/venv${RESET}"
    echo "請先在 3. 直播系統安裝 中執行『4. 安裝 / 修復 YouTube API 依賴』。"
    pause
    return
  fi

  if [ ! -f "$YTAUTH_DIR/client_secret.json" ] || [ ! -f "$YTAUTH_DIR/token.json" ]; then
    echo -e "${RED}缺少 client_secret.json 或 token.json${RESET}"
    echo "請將這兩個文件放到：$YTAUTH_DIR"
    pause
    return
  fi

  read -rp "請輸入直播源地址（rtmp:// 或 http(s)://m3u8 等）： " src_url
  if [ -z "$src_url" ]; then
    echo "直播源地址不能為空。"
    pause
    return
  fi

  read -rp "請輸入新直播間標題： " title
  if [ -z "$title" ]; then
    echo "標題不能為空。"
    pause
    return
  fi

  read -rp "請輸入斷線判定秒數（例如 300，超過則視為本場結束）： " offline_sec
  offline_sec=${offline_sec:-300}

  local idx
  idx=$(next_index "auto")
  local screen_name="ms_auto_${idx}"
  local log_file="$LOG_DIR/${screen_name}.log"

  local py="$BASE_DIR/venv/bin/python"
  local cmd="$py \"$BASE_DIR/magic_autostream.py\" --source-url \"$src_url\" --title \"$title\" --offline-seconds \"$offline_sec\" --auth-dir \"$YTAUTH_DIR\" 2>&1 | tee \"$log_file\""

  clear
  echo -e "${CYAN}Magic Stream -> 1.2 自動推流（YouTube API）${RESET}"
  echo "源地址：$src_url"
  echo "標題：$title"
  echo "斷線判定秒數：$offline_sec"
  echo "screen 會話名：$screen_name"
  echo "日誌文件：$log_file"
  echo
  echo "Python 命令："
  echo "$cmd"
  echo
  read -rp "確認啟動自動推流守護進程？(y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消。"
    pause
    return
  fi

  screen -S "$screen_name" -dm bash -lc "$cmd"
  echo
  echo -e "${GREEN}已在 screen 後台啟動自動推流守護進程。${RESET}"
  echo "使用 4. 推流進程管理 可以查看或結束。"
  pause
}

relay_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 1. 轉播推流${RESET}"
    echo "1. 手動推流（指定源地址 -> YouTube）"
    echo "2. 自動推流（YouTube API，自動建立直播間）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇：" choice
    case "$choice" in
      1) manual_relay ;;
      2) auto_relay ;;
      0) break ;;
      *) invalid_option ;;
    esac
  done
}

# ========= 3. 直播系統安裝 =========

install_system_update() {
  clear
  echo -e "${CYAN}Magic Stream -> 3.1 系統升級 & 更新${RESET}"
  $SUDO apt update && $SUDO apt upgrade -y
  pause
}

install_python_env() {
  clear
  echo -e "${CYAN}Magic Stream -> 3.2 安裝 Python 環境${RESET}"
  $SUDO apt update
  $SUDO apt install -y python3 python3-pip python3-venv
  pause
}

install_ffmpeg() {
  clear
  echo -e "${CYAN}Magic Stream -> 3.3 安裝 ffmpeg${RESET}"
  $SUDO apt update
  $SUDO apt install -y ffmpeg
  pause
}

install_youtube_api_deps() {
  clear
  echo -e "${CYAN}Magic Stream -> 3.4 安裝 / 修復 YouTube API 依賴（建立 venv）${RESET}"
  mkdir -p "$BASE_DIR"
  cd "$BASE_DIR" || exit 1
  python3 -m venv venv
  "$BASE_DIR/venv/bin/pip" install --upgrade pip
  "$BASE_DIR/venv/bin/pip" install google-api-python-client google-auth google-auth-oauthlib google-auth-httplib2
  echo
  echo "測試載入 YouTube API 模組..."
  "$BASE_DIR/venv/bin/python" -c "from googleapiclient.discovery import build; print('OK')" || {
    echo -e "${YELLOW}警告：測試導入 YouTube API 模組失敗，請檢查報錯內容。${RESET}"
  }
  pause
}

install_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 3. 直播系統安裝${RESET}"
    echo "1. 系統升級 & 更新 (apt update && upgrade)"
    echo "2. 安裝 Python 環境 (python3, pip, venv)"
    echo "3. 安裝 ffmpeg"
    echo "4. 安裝 / 修復 YouTube API 依賴（建立 venv）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇：" choice
    case "$choice" in
      1) install_system_update ;;
      2) install_python_env ;;
      3) install_ffmpeg ;;
      4) install_youtube_api_deps ;;
      0) break ;;
      *) invalid_option ;;
    esac
  done
}

# ========= 5. 更新腳本 =========

safe_download() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.tmp"
  if curl -fsSL "$url" -o "$tmp"; then
    mv "$tmp" "$dest"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

update_scripts() {
  clear
  echo -e "${CYAN}Magic Stream -> 5. 更新腳本${RESET}"
  echo "將從 GitHub 倉庫拉取最新版本：$RAW_BASE"
  echo
  echo "1) magic_stream.sh"
  if safe_download "$RAW_BASE/magic_stream.sh" "$BASE_DIR/magic_stream.sh"; then
    chmod +x "$BASE_DIR/magic_stream.sh"
    echo -e "${GREEN}已更新 magic_stream.sh${RESET}"
  else
    echo -e "${RED}下載 magic_stream.sh 失敗${RESET}"
  fi

  echo
  echo "2) magic_autostream.py"
  if safe_download "$RAW_BASE/magic_autostream.py" "$BASE_DIR/magic_autostream.py"; then
    echo -e "${GREEN}已更新 magic_autostream.py${RESET}"
  else
    echo -e "${YELLOW}下載 magic_autostream.py 失敗（如未使用自動推流可忽略）${RESET}"
  fi

  echo
  echo -e "${GREEN}更新完成。如剛剛更新的是本機正在運行的腳本，請退出後重新執行 ms。${RESET}"
  pause
}

# ========= 主菜單 =========

main_menu() {
  while true; do
    clear
    echo -e "${CYAN}==============================${RESET}"
    echo -e "${CYAN}      Magic Stream 直播推流腳本  ${RESET}"
    echo -e "${CYAN}            $VERSION             ${RESET}"
    echo -e "${CYAN}==============================${RESET}"
    echo
    echo "1. 轉播推流"
    echo "2. 文件推流"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本（從 GitHub 拉取最新版本）"
    echo "0. 退出腳本"
    echo
    read -rp "請選擇：" choice
    case "$choice" in
      1) relay_menu ;;
      2) file_stream_menu ;;
      3) install_menu ;;
      4) manage_screen_menu ;;
      5) update_scripts ;;
      0) exit 0 ;;
      *) invalid_option ;;
    esac
  done
}

main_menu
