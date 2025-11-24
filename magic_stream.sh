#!/bin/bash

# ============================================
# Magic Stream 直播推流腳本  v0.7.1 (Stable)
# ============================================

# 注意：移除了 set -e 以防止非致命錯誤導致腳本閃退
INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
PYTHON_BIN="$INSTALL_DIR/venv/bin/python"
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 顏色定義
C_RESET="\e[0m"
C_TITLE="\e[38;5;51m"
C_MENU="\e[38;5;45m"
C_WARN="\e[38;5;214m"
C_ERR="\e[31m"
C_OK="\e[32m"
C_DIM="\e[90m"
C_INPUT="\e[38;5;159m"

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

# ------------------ 通用 UI ------------------
draw_header() {
  clear
  echo -e "${C_TITLE}"
  echo "============================================================"
  echo "  __  __    _    ____ ___ ____ "
  echo " |  \/  |  / \  / ___|_ _/ ___|"
  echo " | |\/| | / _ \| |  _ | | |    "
  echo " | |  | |/ ___ \ |_| || | |___ "
  echo " |_|  |_/_/   \_\____|___\____|"
  echo "------------------------------------------------------------"
  echo "            Magic Stream 直播推流腳本  v0.7.1 (Stable)"
  # 注意：這裡加上了 -e 修復了之前的顯示 bug
  echo -e "============================================================${C_RESET}"
  echo
}

pause_return() {
  echo
  read -rp "按任意鍵返回選單..." -n1 _
}

confirm_action() {
  echo
  echo -e "${C_WARN}請確認以上信息無誤。${C_RESET}"
  read -rp "是否立即啟動推流？(y/n): " ans
  case "$ans" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${C_ERR}[錯誤] 找不到 ffmpeg，請先在「3. 直播系統安裝」裡安裝。${C_RESET}"
    pause_return
    main_menu
  fi
}

ensure_python_venv() {
  if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
    echo -e "${C_WARN}[提示] 尚未建立 Python venv，將使用系統 python3。${C_RESET}"
  fi
}

next_screen_name() {
  local prefix="$1"
  local max_id
  # 增加 || true 防止 grep 失敗導致報錯
  max_id=$(screen -ls 2>/dev/null | grep -o "${prefix}_[0-9]\+" | sed 's/.*_//' | sort -n | tail -n1 || true)
  if [ -z "$max_id" ]; then
    max_id=1
  else
    max_id=$((max_id + 1))
  fi
  printf "%s_%02d" "$prefix" "$max_id"
}

# ------------- 1. 轉播推流（含自動 / 手動） -------------

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流${C_RESET}"
    echo
    echo "1. 手動 RTMP 轉播（YouTube Studio 手動建立直播）"
    echo "2. 自動轉播（使用 YouTube API 自動開播 + 探針守候）"
    echo "0. 返回主選單"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) relay_manual_rtmp ;;
      2) relay_auto_youtube ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# 1.1 手動 RTMP 轉播
relay_manual_rtmp() {
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動 RTMP 轉播${C_RESET}"
  echo
  read -rp "請輸入直播源 URL（例如 FLV 連結）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return

  read -rp "請輸入 RTMP 串流位址（預設 rtmp://a.rtmp.youtube.com/live2）: " TMP_RTMP
  RTMP_ADDR="${TMP_RTMP:-rtmp://a.rtmp.youtube.com/live2}"

  read -rp "請輸入直播串流金鑰（Stream Key）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  # --- 確認環節 ---
  draw_header
  echo -e "${C_MENU}--- 任務摘要 (手動轉播) ---${C_RESET}"
  echo -e "直播源 URL : ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "推流服務器 : ${C_INPUT}$RTMP_ADDR${C_RESET}"
  echo -e "串流金鑰   : ${C_INPUT}$STREAM_KEY${C_RESET}"
  
  confirm_action || { echo "已取消操作。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD
  CMD="ffmpeg -re -i \"$SOURCE_URL\" \
    -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo
  echo -e "${C_OK}已啟動手動轉播 [$SCREEN_NAME]。${C_RESET}"
  pause_return
}

# 1.2 自動轉播（YouTube API + 探針）
relay_auto_youtube() {
  ensure_ffmpeg
  ensure_python_venv
  
  # 檢查憑證是否存在
  if [ ! -f "$AUTH_DIR/token.json" ] || [ ! -f "$AUTH_DIR/client_secret.json" ]; then
    draw_header
    echo -e "${C_ERR}[錯誤] 找不到憑證文件！${C_RESET}"
    echo "請確保已上傳 client_secret.json 和 token.json 到："
    echo -e "${C_WARN}$AUTH_DIR${C_RESET}"
    pause_return
    return
  fi

  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播（YouTube API）${C_RESET}"
  echo
  read -rp "請輸入直播源 URL（例如 FLV 連結）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return

  read -rp "請輸入 YouTube 直播標題（預設: Magic Stream Live）: " TMP_TITLE
  TITLE="${TMP_TITLE:-Magic Stream Live}"

  echo
  echo "請選擇直播隱私狀態："
  echo "1) 公開 (Public)"
  echo "2) 不公開 (Unlisted) [預設]"
  echo "3) 私享 (Private)"
  read -rp "請選擇 (1-3): " p_choice
  
  local PRIVACY
  case "$p_choice" in
    1) PRIVACY="public" ;;
    3) PRIVACY="private" ;;
    *) PRIVACY="unlisted" ;;
  esac

  echo
  read -rp "短暫掉線容忍秒數（預設 300）: " TMP_SEC
  OFFLINE_SEC="${TMP_SEC:-300}"

  # --- 確認環節 ---
  draw_header
  echo -e "${C_MENU}--- 任務摘要 (自動轉播) ---${C_RESET}"
  echo -e "直播源 URL : ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "直播標題   : ${C_INPUT}$TITLE${C_RESET}"
  echo -e "隱私設定   : ${C_INPUT}$PRIVACY${C_RESET}"
  echo -e "掉線容忍   : ${C_INPUT}${OFFLINE_SEC} 秒${C_RESET}"
  echo -e "認證目錄   : ${C_DIM}$AUTH_DIR${C_RESET}"
  
  confirm_action || { echo "已取消操作。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_auto")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  # 注意：Python 增加 -u 參數
  local CMD
  CMD="cd \"$INSTALL_DIR\" && \"$PYTHON_BIN\" -u \"$INSTALL_DIR/magic_autostream.py\" \
    --source-url \"$SOURCE_URL\" \
    --title \"$TITLE\" \
    --privacy \"$PRIVACY\" \
    --reconnect-seconds \"$OFFLINE_SEC\" \
    --auth-dir \"$AUTH_DIR\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo
  echo -e "${C_OK}自動轉播腳本已在後台運行 [$SCREEN_NAME]。${C_RESET}"
  pause_return
}

# ---------------- 2. 文件推流 ----------------

menu_vod() {
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo
  echo "視頻文件目錄：$VOD_DIR"
  echo
  read -rp "請輸入文件名（含副檔名）: " FILE_NAME
  [ -z "$FILE_NAME" ] && return

  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then
    echo -e "${C_ERR}[錯誤] 找不到檔案：$FULL_PATH${C_RESET}"
    pause_return
    return
  fi

  read -rp "RTMP 位址（Enter 使用 YouTube 預設）: " TMP_RTMP
  RTMP_ADDR="${TMP_RTMP:-rtmp://a.rtmp.youtube.com/live2}"

  read -rp "請輸入直播串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  # --- 確認環節 ---
  draw_header
  echo -e "${C_MENU}--- 任務摘要 (文件推流) ---${C_RESET}"
  echo -e "文件路徑   : ${C_INPUT}$FULL_PATH${C_RESET}"
  echo -e "推流服務器 : ${C_INPUT}$RTMP_ADDR${C_RESET}"
  echo -e "串流金鑰   : ${C_INPUT}$STREAM_KEY${C_RESET}"
  
  confirm_action || { echo "已取消操作。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD
  CMD="ffmpeg -re -stream_loop -1 -i \"$FULL_PATH\" \
    -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo
  echo -e "${C_OK}文件推流已啟動 [$SCREEN_NAME]。${C_RESET}"
  pause_return
}

# ------------- 3. 直播系統安裝 -------------

menu_install() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo "1. 系統升級 & 更新  (apt update && upgrade)"
    echo "2. 安裝 Python3 與 pip"
    echo "3. 安裝 ffmpeg"
    echo "4. 建立 Python 環境 (安裝 Google API 依賴)"
    echo "0. 返回主選單"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) apt update && apt upgrade -y; pause_return ;;
      2) apt update; apt install -y python3 python3-venv python3-pip; pause_return ;;
      3) apt update; apt install -y ffmpeg; pause_return ;;
      4) install_yt_api_deps; pause_return ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

install_yt_api_deps() {
  echo -e "${C_MENU}正在設定 Python 環境...${C_RESET}"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || return

  if [ ! -d "venv" ]; then
    python3 -m venv venv
  fi

  source venv/bin/activate
  pip install --upgrade pip
  pip install google-api-python-client google-auth google-auth-oauthlib google-auth-httplib2
  deactivate
  echo -e "${C_OK}安裝完成。${C_RESET}"
}

# ------------- 4. 推流進程管理 -------------

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo
    echo "1. 查看所有 screen 會話"
    echo "2. 查看推流狀態（日誌摘要）"
    echo "3. 進入指定 screen（查看實時 log）"
    echo "4. 結束指定 screen（停止直播）"
    echo "0. 返回主選單"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) process_list ;;
      2) process_status ;;
      3) process_attach ;;
      4) process_kill ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

process_list() {
  draw_header
  echo -e "${C_MENU}4.1 所有 screen 會話${C_RESET}"
  echo
  screen -ls || echo "目前沒有運行中的 screen 會話。"
  echo
  pause_return
}

process_status() {
  draw_header
  echo -e "${C_MENU}4.2 推流狀態摘要${C_RESET}"
  echo
  local SESSIONS
  SESSIONS=$(screen -ls 2>/dev/null | grep -E "ms_(auto|manual|vod)_" | awk '{print $1}' || true)
  if [ -z "$SESSIONS" ]; then
    echo "目前沒有 Magic Stream 推流。"
    pause_return
    return
  fi

  local i=1
  while read -r line; do
    local name
    name=$(echo "$line" | cut -d. -f1)
    local log
    log=$(ls "$LOG_DIR/${name}_"*.log 2>/dev/null | tail -n1)
    echo "[$i] $name"
    if [ -f "$log" ]; then
      echo "    Log: $log"
      echo "    Last info: $(tail -n 1 "$log")"
    else
      echo "    Log: (未找到)"
    fi
    echo
    i=$((i + 1))
  done <<<"$SESSIONS"
  pause_return
}

process_attach() {
  draw_header
  echo -e "${C_MENU}4.3 進入 screen (按 Ctrl+A, D 離開)${C_RESET}"
  echo
  read -rp "輸入 screen 名稱 (如 ms_auto_01): " SNAME
  [ -z "$SNAME" ] && return
  screen -r "$SNAME"
}

process_kill() {
  draw_header
  echo -e "${C_MENU}4.4 停止直播${C_RESET}"
  echo
  read -rp "輸入要停止的 screen 名稱 (如 ms_auto_01): " SNAME
  [ -z "$SNAME" ] && return
  
  read -rp "確認要停止 $SNAME 嗎？(y/n): " ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    screen -S "$SNAME" -X quit
    echo -e "${C_OK}已停止。${C_RESET}"
  else
    echo "已取消。"
  fi
  pause_return
}

# ---------------- 5. 更新腳本 ----------------

menu_update() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 更新腳本${C_RESET}"
  echo
  read -rp "確認更新？(y/n): " ans
  case "$ans" in
    y|Y)
      mkdir -p "$INSTALL_DIR"
      cd "$INSTALL_DIR" || return
      # 為了避免覆蓋正在執行的腳本報錯，先下載為 tmp 文件
      curl -fsSL "$RAW_BASE/magic_stream.sh" -o magic_stream.sh.tmp
      curl -fsSL "$RAW_BASE/magic_autostream.py" -o magic_autostream.py
      
      mv magic_stream.sh.tmp magic_stream.sh
      chmod +x magic_stream.sh magic_autostream.py
      echo -e "${C_OK}更新完成，正在重啟腳本...${C_RESET}"
      
      # 延遲 1 秒後，使用 exec 替換當前進程，實現自動重啟
      sleep 1
      exec "$0" "$@"
      ;;
    *) echo "已取消。"; pause_return ;;
  esac
}

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主選單${C_RESET}"
    echo
    echo "1. 轉播推流（手動 / 自動）"
    echo "2. 文件推流"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本"
    echo "0. 退出"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) menu_install ;;
      4) menu_process ;;
      5) menu_update ;;
      0) exit 0 ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

main_menu
