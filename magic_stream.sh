#!/bin/bash
set -e

# ============================================
# Magic Stream 直播推流腳本  v0.6.0
# ============================================

INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
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
  # 如果還沒建 venv，就先用系統 python3
  PYTHON_BIN="python3"
fi

# ------------------ 通用 UI ------------------
draw_header() {
  clear
  echo -e "${C_TITLE}"
  echo "============================================================"
  echo "   ████   ███   █  █  ███   ███   ████   ███   ████  ████ "
  echo "   █     █   █  ██ █ █   █ █   █  █   █ █   █  █     █    "
  echo "   ███   █   █  █ ██ █   █ █   █  ████  █   █  ███   ███  "
  echo "   █     █   █  █  █ █   █ █   █  █   █ █   █  █        █ "
  echo "   █      ███   █  █  ███   ███   ████   ███   ████ ████ "
  echo "------------------------------------------------------------"
  echo "              Magic Stream 直播推流腳本  v0.6.0"
  echo "============================================================${C_RESET}"
  echo
}

pause_return() {
  echo
  read -rp "按任意鍵返回選單..." -n1 _
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

# 取得下一個 screen 名稱
next_screen_name() {
  local prefix="$1"          # ms_auto / ms_manual / ms_vod
  local max_id
  max_id=$(screen -ls 2>/dev/null | grep -o "${prefix}_[0-9]\+" | sed 's/.*_//' | sort -n | tail -n1)
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
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流（直播源 → YouTube）${C_RESET}"
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
  [ -z "$SOURCE_URL" ] && { echo "已取消。"; pause_return; return; }

  read -rp "請輸入 RTMP 串流位址（例如 rtmp://a.rtmp.youtube.com/live2）: " RTMP_ADDR
  [ -z "$RTMP_ADDR" ] && { echo "已取消。"; pause_return; return; }

  read -rp "請輸入直播串流金鑰（只填 key 部分）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  echo
  echo -e "${C_OK}即將以 screen 後台啟動手動轉播。${C_RESET}"
  echo "screen 名稱: $SCREEN_NAME"
  echo "日誌檔: $LOG_FILE"
  echo

  local CMD
  CMD="ffmpeg -re -i \"$SOURCE_URL\" \
    -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo -e "${C_OK}已啟動轉播。使用「4. 推流進程管理」可查看狀態。${C_RESET}"
  pause_return
}

# 1.2 自動轉播（YouTube API + 探針）
relay_auto_youtube() {
  ensure_ffmpeg
  ensure_python_venv
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播（YouTube API）${C_RESET}"
  echo
  read -rp "請輸入直播源 URL（例如 FLV 連結）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo "已取消。"; pause_return; return; }

  read -rp "請輸入 YouTube 直播標題（預設: test）: " TITLE
  [ -z "$TITLE" ] && TITLE="test"

  read -rp "短暫掉線容忍秒數（例如 300，超過視為本場結束）: " OFFLINE_SEC
  [ -z "$OFFLINE_SEC" ] && OFFLINE_SEC=300

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_auto")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  echo
  echo -e "${C_OK}即將以 screen 啟動自動轉播。${C_RESET}"
  echo "screen 名稱: $SCREEN_NAME"
  echo "日誌檔: $LOG_FILE"
  echo "認證目錄: $AUTH_DIR"
  echo

  local CMD
  CMD="cd \"$INSTALL_DIR\" && \"$PYTHON_BIN\" \"$INSTALL_DIR/magic_autostream.py\" \
    --source-url \"$SOURCE_URL\" \
    --title \"$TITLE\" \
    --reconnect-seconds \"$OFFLINE_SEC\" \
    --auth-dir \"$AUTH_DIR\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo -e "${C_OK}自動轉播腳本已在後台運行。${C_RESET}"
  echo -e "${C_DIM}說明：探針會常駐偵測直播源，下播後會進入待命狀態，下次開播會自動重新開一場 YouTube 直播。${C_RESET}"
  pause_return
}

# ---------------- 2. 文件推流 ----------------

menu_vod() {
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo
  echo "請先把視頻放到：$VOD_DIR"
  echo
  read -rp "請輸入需要直播的文件名（含副檔名）: " FILE_NAME
  [ -z "$FILE_NAME" ] && { echo "已取消。"; pause_return; return; }

  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then
    echo -e "${C_ERR}[錯誤] 找不到檔案：$FULL_PATH${C_RESET}"
    pause_return
    return
  fi

  read -rp "預設平台: YouTube (rtmp://a.rtmp.youtube.com/live2) ，直接按 Enter 使用預設: " TMP
  local RTMP_ADDR="${TMP:-rtmp://a.rtmp.youtube.com/live2}"

  read -rp "請輸入直播串流金鑰（只填 key 部分）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  echo
  echo -e "${C_OK}即將以 screen 後台啟動文件推流。${C_RESET}"
  echo "screen 名稱: $SCREEN_NAME"
  echo "日誌檔: $LOG_FILE"
  echo

  local CMD
  CMD="ffmpeg -re -stream_loop -1 -i \"$FULL_PATH\" \
    -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""

  echo -e "${C_OK}文件推流已啟動（無限循環播放）。${C_RESET}"
  pause_return
}

# ------------- 3. 直播系統安裝 -------------

menu_install() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo "1. 系統升級 & 更新  (apt update && apt upgrade)"
    echo "2. 安裝 Python3 與 pip (python3, python3-venv, python3-pip)"
    echo "3. 安裝 ffmpeg"
    echo "4. 建立 / 修復 YouTube API 依賴 (建立 venv, 安裝套件)"
    echo "0. 返回主選單"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1)
        apt update && apt upgrade -y
        pause_return
        ;;
      2)
        apt update
        apt install -y python3 python3-venv python3-pip
        pause_return
        ;;
      3)
        apt update
        apt install -y ffmpeg
        pause_return
        ;;
      4)
        install_yt_api_deps
        pause_return
        ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

install_yt_api_deps() {
  echo -e "${C_MENU}建立 Python venv 並安裝 YouTube API 相關套件...${C_RESET}"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [ ! -d "venv" ]; then
    python3 -m venv venv
  fi

  # shellcheck disable=SC1091
  source venv/bin/activate
  pip install --upgrade pip
  pip install google-api-python-client google-auth google-auth-oauthlib google-auth-httplib2
  deactivate

  echo -e "${C_OK}YouTube API 依賴安裝完成。${C_RESET}"
}

# ------------- 4. 推流進程管理 -------------

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo
    echo "1. 查看所有 screen 會話"
    echo "2. 查看推流狀態（摘要）"
    echo "3. 進入指定 screen（查看 ffmpeg log）"
    echo "4. 結束指定 screen（等於結束該路直播）"
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
  echo -e "${C_MENU}Magic Stream -> 4.1 所有 screen 會話${C_RESET}"
  echo
  screen -ls || echo "No Sockets found in /run/screen/S-$(whoami)."
  echo
  echo -e "${C_DIM}提示：Magic Stream 推流的會話名稱一般為：ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
  pause_return
}

process_status() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.2 推流狀態摘要${C_RESET}"
  echo
  local SESSIONS
  SESSIONS=$(screen -ls 2>/dev/null | grep -E "ms_(auto|manual|vod)_" | awk '{print $1}' || true)
  if [ -z "$SESSIONS" ]; then
    echo "目前沒有 Magic Stream 推流中的 screen 會話。"
    pause_return
    return
  fi

  local i=1
  echo "當前推流 screen 會話："
  echo
  while read -r line; do
    local name
    name=$(echo "$line" | cut -d. -f1)
    local log
    log=$(ls "$LOG_DIR/${name}_"*.log 2>/dev/null | tail -n1 || echo "（找不到對應日誌）")
    echo "[$i] $name    log: $log"
    i=$((i + 1))
  done <<<"$SESSIONS"

  pause_return
}

process_attach() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.3 進入指定 screen 會話${C_RESET}"
  echo
  screen -ls 2>/dev/null | grep -E "ms_(auto|manual|vod)_" || {
    echo "目前沒有 Magic Stream 推流中的 screen 會話。"
    pause_return
    return
  }
  echo
  read -rp "輸入要進入的 screen 名稱（例如 ms_auto_01）: " SNAME
  [ -z "$SNAME" ] && { echo "已取消。"; pause_return; return; }
  screen -r "$SNAME" || {
    echo -e "${C_ERR}無法進入 screen：$SNAME${C_RESET}"
    pause_return
  }
}

process_kill() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.4 結束指定 screen 會話${C_RESET}"
  echo
  screen -ls 2>/dev/null | grep -E "ms_(auto|manual|vod)_" || {
    echo "目前沒有 Magic Stream 推流中的 screen 會話。"
    pause_return
    return
  }
  echo
  read -rp "輸入要結束的 screen 名稱（例如 ms_auto_01）: " SNAME
  [ -z "$SNAME" ] && { echo "已取消。"; pause_return; return; }

  screen -S "$SNAME" -X quit || {
    echo -e "${C_ERR}結束 screen 失敗：$SNAME${C_RESET}"
    pause_return
    return
  }
  echo -e "${C_OK}已結束 screen：$SNAME${C_RESET}"
  pause_return
}

# ---------------- 5. 更新腳本 ----------------

menu_update() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 更新腳本（從 GitHub 拉取最新版）${C_RESET}"
  echo
  read -rp "確認要從 GitHub 更新 magic_stream.sh 與 magic_autostream.py？(y/n): " ans
  case "$ans" in
    y|Y)
      mkdir -p "$INSTALL_DIR"
      cd "$INSTALL_DIR"
      curl -fsSL "$RAW_BASE/magic_stream.sh" -o magic_stream.sh
      curl -fsSL "$RAW_BASE/magic_autostream.py" -o magic_autostream.py
      chmod +x magic_stream.sh magic_autostream.py
      echo -e "${C_OK}更新完成。${C_RESET}"
      pause_return
      ;;
    *)
      echo "已取消。"
      pause_return
      ;;
  esac
}

# ---------------- 主選單 ----------------

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主選單${C_RESET}"
    echo
    echo "1. 轉播推流（含：手動 RTMP / 自動 YouTube API）"
    echo "2. 文件推流（點播文件 = 直播）"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本（從 GitHub 拉取最新版）"
    echo "0. 退出腳本"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) menu_install ;;
      4) menu_process ;;
      5) menu_update ;;
      0) echo "Bye~"; exit 0 ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

main_menu
