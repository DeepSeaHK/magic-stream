#!/bin/bash
set -e

# ============================================
# Magic Stream 直播推流腳本  v0.5.0
# ============================================

INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
RUN_DIR="$INSTALL_DIR"
PYTHON_BIN="$INSTALL_DIR/venv/bin/python"
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 顏色
C_RESET="\e[0m"
C_TITLE="\e[38;5;51m"
C_MENU="\e[38;5;45m"
C_WARN="\e[38;5;214m"
C_ERR="\e[31m"
C_OK="\e[32m"
C_DIM="\e[90m"

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

# ------------------ 通用 UI ------------------
draw_header() {
  clear
  echo -e "${C_TITLE}"
  echo "============================================================"
  printf "  %-54s\n" "Magic Stream 直播推流腳本"
  printf "  %-54s\n" "v0.5.0"
  echo "============================================================"
  echo -e "${C_RESET}"
}

pause_any() {
  echo
  read -rp "按回車鍵返回菜單..." _
}

# ------------------ 輔助函數 ------------------

# 生成 screen 名稱，如 ms_auto_01 / ms_manual_02 / ms_vod_01
next_screen_name() {
  local prefix="$1"  # ms_auto / ms_manual / ms_vod
  local i=1
  while true; do
    local num
    num=$(printf "%02d" "$i")
    local name="${prefix}_${num}"
    if ! screen -ls | grep -q "[[:space:]]${name}[[:space:]]"; then
      echo "$name"
      return
    fi
    i=$((i + 1))
  done
}

start_in_screen() {
  local screen_name="$1"
  local cmd="$2"
  local log_file="$LOG_DIR/${screen_name}.log"

  echo -e "${C_MENU}將在 screen 後台啟動進程：${C_RESET}"
  echo "  screen 名稱：$screen_name"
  echo "  日誌文件：$log_file"
  echo
  echo -e "${C_DIM}提示：可在主菜單 4. 推流進程管理 中查看狀態或結束進程。${C_RESET}"
  echo

  # -dm: detach, bash -lc 確保加載 PATH
  screen -S "$screen_name" -dm bash -lc "$cmd 2>&1 | tee -a \"$log_file\""
}

ensure_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${C_ERR}[錯誤] 未找到 ffmpeg，請先在 3. 直播系統安裝 中安裝。${C_RESET}"
    pause_any
    return 1
  fi
}

# ================== 1. 轉播推流 ==================

relay_manual_menu() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動轉播（RTMP 模式）${C_RESET}"
  echo
  echo "說明："
  echo "  - 使用現成 RTMP 地址轉播（例如 YouTube 直播碼）。"
  echo "  - 內置探針：源未開播時 standby，源上線自動推流。"
  echo "  - 連續 ${C_WARN}offline_seconds${C_RESET} 秒沒有畫面，認為本場結束，停止推流，回到 standby。"
  echo

  read -rp "請輸入直播源地址（FLV/HLS）： " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo "已取消。"; pause_any; return; }

  local default_rtmp="rtmp://a.rtmp.youtube.com/live2"
  read -rp "RTMP 串流地址前綴（回車默認：$default_rtmp）： " RTMP_PREFIX
  RTMP_PREFIX=${RTMP_PREFIX:-$default_rtmp}

  read -rp "請輸入直播碼（只填 key 部分）： " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo "已取消。"; pause_any; return; }

  local RTMP_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  echo
  read -rp "探針間隔秒數 probe_interval（默認 30）： " PROBE_INTERVAL
  PROBE_INTERVAL=${PROBE_INTERVAL:-30}

  read -rp "下播判定秒數 offline_seconds（默認 300）： " OFFLINE_SECONDS
  OFFLINE_SECONDS=${OFFLINE_SECONDS:-300}

  draw_header
  echo -e "${C_MENU}即將啟動 手動轉播：${C_RESET}"
  echo "  來源：$SOURCE_URL"
  echo "  RTMP：$RTMP_URL"
  echo "  探針間隔：${PROBE_INTERVAL}s"
  echo "  下播判定：${OFFLINE_SECONDS}s 無畫面視為本場結束"
  echo

  read -rp "確認開始？ (y/n)： " yn
  [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "已取消。"; pause_any; return; }

  ensure_ffmpeg || return

  local screen_name
  screen_name=$(next_screen_name "ms_manual")
  local cmd="$PYTHON_BIN \"$RUN_DIR/magic_autostream.py\" \
    --mode manual \
    --source-url \"$SOURCE_URL\" \
    --rtmp-url \"$RTMP_URL\" \
    --probe-interval \"$PROBE_INTERVAL\" \
    --offline-seconds \"$OFFLINE_SECONDS\""

  start_in_screen "$screen_name" "$cmd"
  pause_any
}

relay_auto_menu() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播（YouTube API 模式）${C_RESET}"
  echo
  echo "說明："
  echo "  - 需要先在 $AUTH_DIR 中完成 OAuth 授權（client_secret.json / token.json）。"
  echo "  - 源上線時，自動在 YouTube 建立新直播間並推流。"
  echo "  - 連續 offline_seconds 秒無畫面：標記本場 complete，回到 standby 等下一場。"
  echo

  read -rp "請輸入直播源地址（FLV/HLS）： " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo "已取消。"; pause_any; return; }

  read -rp "請輸入 YouTube 直播標題： " TITLE
  [ -z "$TITLE" ] && { echo "已取消。"; pause_any; return; }

  echo
  echo "隱私選項："
  echo "  1. public   (公開)"
  echo "  2. unlisted (不公開 / 連結可見)"
  echo "  3. private  (私人)"
  read -rp "請選擇隱私狀態 (默認 2)： " privacy_choice
  local PRIVACY="unlisted"
  case "$privacy_choice" in
    1) PRIVACY="public" ;;
    3) PRIVACY="private" ;;
    *) PRIVACY="unlisted" ;;
  esac

  echo
  read -rp "探針間隔秒數 probe_interval（默認 30）： " PROBE_INTERVAL
  PROBE_INTERVAL=${PROBE_INTERVAL:-30}

  read -rp "下播判定秒數 offline_seconds（默認 300）： " OFFLINE_SECONDS
  OFFLINE_SECONDS=${OFFLINE_SECONDS:-300}

  draw_header
  echo -e "${C_MENU}即將啟動 自動轉播：${C_RESET}"
  echo "  來源：$SOURCE_URL"
  echo "  標題：$TITLE"
  echo "  隱私：$PRIVACY"
  echo "  探針間隔：${PROBE_INTERVAL}s"
  echo "  下播判定：${OFFLINE_SECONDS}s 無畫面視為本場結束"
  echo

  read -rp "確認開始？ (y/n)： " yn
  [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "已取消。"; pause_any; return; }

  ensure_ffmpeg || return

  local screen_name
  screen_name=$(next_screen_name "ms_auto")

  local cmd="$PYTHON_BIN \"$RUN_DIR/magic_autostream.py\" \
    --mode auto \
    --source-url \"$SOURCE_URL\" \
    --title \"$TITLE\" \
    --privacy-status \"$PRIVACY\" \
    --probe-interval \"$PROBE_INTERVAL\" \
    --offline-seconds \"$OFFLINE_SECONDS\" \
    --auth-dir \"$AUTH_DIR\""

  start_in_screen "$screen_name" "$cmd"
  pause_any
}

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流${C_RESET}"
    echo
    echo "1. 手動轉播（RTMP 模式）"
    echo "2. 自動轉播（YouTube API 模式）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇： " opt
    case "$opt" in
      1) relay_manual_menu ;;
      2) relay_auto_menu ;;
      0) return ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
  done
}

# ================== 2. 文件推流 ==================

menu_vod() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo
  echo "說明："
  echo "  - 會從目錄：$VOD_DIR 中讀取影片檔。"
  echo "  - 支持單次播完或無限循環。"
  echo

  ensure_ffmpeg || return

  echo "請先把視頻文件上傳到：$VOD_DIR"
  echo
  read -rp "請輸入需要直播的文件名（含擴展名），例如 test.mp4： " FILE_NAME
  [ -z "$FILE_NAME" ] && { echo "已取消。"; pause_any; return; }

  local FILE_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FILE_PATH" ]; then
    echo -e "${C_ERR}[錯誤] 找不到文件：$FILE_PATH${C_RESET}"
    pause_any
    return
  fi

  local default_rtmp="rtmp://a.rtmp.youtube.com/live2"
  read -rp "RTMP 串流地址前綴（回車默認：$default_rtmp）： " RTMP_PREFIX
  RTMP_PREFIX=${RTMP_PREFIX:-$default_rtmp}

  read -rp "請輸入直播碼（只填 key 部分）： " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo "已取消。"; pause_any; return; }
  local RTMP_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  echo
  echo "播放模式："
  echo "  1. 播放一次"
  echo "  2. 無限循環"
  read -rp "請選擇（默認 2）： " loop_choice
  local LOOP_MODE="loop"
  [ "$loop_choice" = "1" ] && LOOP_MODE="once"

  local screen_name
  screen_name=$(next_screen_name "ms_vod")
  local log_file="$LOG_DIR/${screen_name}.log"

  draw_header
  echo -e "${C_MENU}即將啟動 文件推流：${C_RESET}"
  echo "  文件：$FILE_PATH"
  echo "  RTMP：$RTMP_URL"
  echo "  模式：$([ "$LOOP_MODE" = "once" ] && echo '播放一次' || echo '無限循環')"
  echo "  screen 名稱：$screen_name"
  echo "  日誌文件：$log_file"
  echo

  read -rp "確認開始？ (y/n)： " yn
  [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "已取消。"; pause_any; return; }

  local ff_cmd="ffmpeg -re "
  if [ "$LOOP_MODE" = "loop" ]; then
    ff_cmd+=" -stream_loop -1 "
  fi
  ff_cmd+=" -i \"$FILE_PATH\" -c:v copy -c:a copy -f flv \"$RTMP_URL\""

  start_in_screen "$screen_name" "$ff_cmd"
  pause_any
}

# ================== 3. 直播系統安裝 ==================

menu_setup() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo "1. 系統升級 & 更新   (apt update && apt upgrade)"
    echo "2. 安裝 Python 環境   (python3, venv, pip)"
    echo "3. 安裝 ffmpeg"
    echo "4. 安裝 / 修復 YouTube API 依賴 (在 venv 中)"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇： " opt
    case "$opt" in
      1)
        draw_header
        echo -e "${C_MENU}執行 apt update && apt upgrade...${C_RESET}"
        apt update && apt upgrade -y
        pause_any
        ;;
      2)
        draw_header
        echo -e "${C_MENU}安裝 Python3 / venv / pip...${C_RESET}"
        apt update
        apt install -y python3 python3-venv python3-pip
        if [ ! -d "$INSTALL_DIR/venv" ]; then
          python3 -m venv "$INSTALL_DIR/venv"
        fi
        "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
        pause_any
        ;;
      3)
        draw_header
        echo -e "${C_MENU}安裝 ffmpeg...${C_RESET}"
        apt update
        apt install -y ffmpeg
        pause_any
        ;;
      4)
        draw_header
        echo -e "${C_MENU}在 venv 中安裝 YouTube API 相關依賴...${C_RESET}"
        if [ ! -d "$INSTALL_DIR/venv" ]; then
          echo -e "${C_ERR}請先執行 3.2 安裝 Python 環境。${C_RESET}"
        else
          "$INSTALL_DIR/venv/bin/pip" install --upgrade \
            google-api-python-client \
            google-auth-httplib2 \
            google-auth-oauthlib
          echo
          echo -e "${C_OK}依賴安裝完成。請確保 $AUTH_DIR 下有 client_secret.json 並完成一次授權取得 token.json。${C_RESET}"
        fi
        pause_any
        ;;
      0) return ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
  done
}

# ================== 4. 推流進程管理 ==================

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo
    echo "1. 查看所有 screen 會話"
    echo "2. 查看指定 screen 狀態（簡要資訊）"
    echo "3. 結束指定 screen（等於結束該路直播）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇： " opt
    case "$opt" in
      1)
        draw_header
        echo -e "${C_MENU}當前 screen 會話：${C_RESET}"
        echo
        screen -ls || true
        echo
        echo -e "${C_DIM}提示：Magic Stream 相關名稱一般為：ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
        pause_any
        ;;
      2)
        draw_header
        echo -e "${C_MENU}查看指定 screen 狀態${C_RESET}"
        echo
        read -rp "輸入 screen 名稱（例如 ms_auto_01）： " sname
        [ -z "$sname" ] && { echo "已取消。"; pause_any; continue; }
        local logfile="$LOG_DIR/${sname}.log"
        echo
        echo "日誌文件：$logfile"
        echo
        if [ -f "$logfile" ]; then
          echo -e "${C_DIM}最近 20 行日誌：${C_RESET}"
          echo "----------------------------------------"
          tail -n 20 "$logfile" || true
          echo "----------------------------------------"
        else
          echo -e "${C_WARN}找不到日誌文件。可能該直播剛啟動不久或已結束。${C_RESET}"
        fi
        pause_any
        ;;
      3)
        draw_header
        echo -e "${C_MENU}結束指定 screen 會話${C_RESET}"
        echo
        read -rp "輸入 screen 名稱（例如 ms_auto_01）： " sname
        [ -z "$sname" ] && { echo "已取消。"; pause_any; continue; }
        if screen -ls | grep -q "[[:space:]]${sname}[[:space:]]"; then
          read -rp "確認結束 ${sname} ？ (y/n)： " yn
          if [[ "$yn" = "y" || "$yn" = "Y" ]]; then
            screen -S "$sname" -X quit || true
            echo -e "${C_OK}已嘗試結束 ${sname}。${C_RESET}"
          else
            echo "已取消。"
          fi
        else
          echo -e "${C_WARN}未找到名為 ${sname} 的 screen。${C_RESET}"
        fi
        pause_any
        ;;
      0) return ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
  done
}

# ================== 5. 更新腳本 ==================

menu_update() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 更新腳本（從 GitHub 拉取最新版）${C_RESET}"
  echo
  echo "將從：$RAW_BASE"
  echo "拉取：magic_stream.sh / magic_autostream.py"
  echo

  read -rp "確認更新？ (y/n)： " yn
  [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "已取消。"; pause_any; return; }

  mkdir -p "$INSTALL_DIR/backup_$(date +%Y%m%d_%H%M%S)"
  local backup_dir
  backup_dir="$INSTALL_DIR/backup_$(date +%Y%m%d_%H%M%S)"

  cp -f "$INSTALL_DIR/magic_stream.sh" "$backup_dir/" 2>/dev/null || true
  cp -f "$INSTALL_DIR/magic_autostream.py" "$backup_dir/" 2>/dev/null || true

  echo -e "${C_MENU}正在從 GitHub 下載最新腳本...${C_RESET}"
  curl -fsSL "$RAW_BASE/magic_stream.sh" -o "$INSTALL_DIR/magic_stream.sh"
  curl -fsSL "$RAW_BASE/magic_autostream.py" -o "$INSTALL_DIR/magic_autostream.py"
  chmod +x "$INSTALL_DIR/magic_stream.sh"

  echo
  echo -e "${C_OK}更新完成。如出現問題，可從 backup 目錄手動還原。${C_RESET}"
  pause_any
}

# ================== 主菜單 ==================

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主菜單${C_RESET}"
    echo
    echo "1. 轉播推流  （含：手動 RTMP / 自動 YouTube API）"
    echo "2. 文件推流  （點播文件 → 直播）"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本（從 GitHub 拉取最新版）"
    echo "0. 退出腳本"
    echo
    read -rp "請選擇： " opt
    case "$opt" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) menu_setup ;;
      4) menu_process ;;
      5) menu_update ;;
      0)
        echo
        echo -e "${C_OK}再見，祝推流順利。${C_RESET}"
        exit 0
        ;;
      *) echo "無效選項"; sleep 1 ;;
    esac
  done
}

main_menu
