#!/bin/bash
# Magic Stream - 直播推流腳本 v0.1

# ===== 基礎配置 =====
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
VOD_DIR="$BASE_DIR/vod"                       # 文件推流目錄
LOG_DIR="$BASE_DIR/logs"                      # 日誌目錄
AUTO_SCRIPT="$BASE_DIR/magic_autostream.py"   # 自動推流 Python 腳本
YOUTUBE_RTMP_BASE="rtmp://a.rtmp.youtube.com/live2"

mkdir -p "$VOD_DIR" "$LOG_DIR"

# 是否有 sudo
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

# ===== 顏色 =====
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

pause() {
  echo
  read -p "按回車鍵返回菜單..." _
}

# ===== 1.1 手動轉播推流 =====
manual_relay() {
  clear
  echo -e "${CYAN}Magic Stream -> 轉播推流 -> 手動推流${RESET}"
  echo "說明：本模式只負責把直播源轉發到 RTMP，不調用 YouTube API。"
  echo

  read -p "請輸入直播源地址 (http://... 或 rtmp://...): " SOURCE_URL
  if [ -z "$SOURCE_URL" ]; then
    echo -e "${RED}直播源地址不能為空。${RESET}"
    pause; return
  fi

  echo "默認平台：YouTube ($YOUTUBE_RTMP_BASE)"
  read -p "請輸入直播碼 (只填 key，例如 abcd-xxxx-1234): " STREAM_KEY
  if [ -z "$STREAM_KEY" ]; then
    echo -e "${RED}直播碼不能為空。${RESET}"
    pause; return
  fi

  read -p "如需自定 RTMP 前綴，輸入（留空=使用默認 $YOUTUBE_RTMP_BASE）: " RTMP_PREFIX
  [ -z "$RTMP_PREFIX" ] && RTMP_PREFIX="$YOUTUBE_RTMP_BASE"

  RTMP_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  read -p "請輸入直播時間（秒，0 = 跟隨直播源，不自動停止）: " DURATION
  [ -z "$DURATION" ] && DURATION=0

  if [[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -gt 0 ]; then
    DURATION_OPT="-t $DURATION"
  else
    DURATION_OPT=""
  fi

  SESSION_NAME="ms_manual_$(date +%m%d_%H%M%S)"
  LOG_FILE="$LOG_DIR/${SESSION_NAME}.log"

  CMD="ffmpeg -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -i \"$SOURCE_URL\" $DURATION_OPT \
    -c:v copy -c:a copy -f flv \"$RTMP_URL\" \
    2>&1 | tee \"$LOG_FILE\""

  echo -e "${GREEN}將以 screen 後台啟動推流，會話名：${SESSION_NAME}${RESET}"
  echo "日誌文件：$LOG_FILE"
  echo
  echo "ffmpeg 命令："
  echo "$CMD"
  echo

  read -p "確認開始推流？(y/n): " go
  if [ "$go" != "y" ] && [ "$go" != "Y" ]; then
    echo "已取消。"
    pause; return
  fi

  screen -S "$SESSION_NAME" -dm bash -lc "$CMD"
  echo -e "${GREEN}已啟動，你可以用 'screen -r $SESSION_NAME' 查看推流狀態。${RESET}"
  pause
}

# ===== 1.2 自動轉播推流（YouTube API） =====
auto_relay() {
  clear
  echo -e "${CYAN}Magic Stream -> 轉播推流 -> 自動推流 (YouTube API)${RESET}"
  echo "需要：$BASE_DIR/youtube_auth/client_secret.json, token.json"
  echo

  if [ ! -f "$AUTO_SCRIPT" ]; then
    echo -e "${RED}未找到自動推流腳本：$AUTO_SCRIPT${RESET}"
    pause; return
  fi

  read -p "請輸入直播源地址 (http://... 或 rtmp://...): " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo -e "${RED}直播源地址不能為空。${RESET}"; pause; return; }

  read -p "請輸入 YouTube 直播間標題: " TITLE
  [ -z "$TITLE" ] && TITLE="Magic Stream Auto Live"

  read -p "請輸入斷線重連時間閾值（秒，默認 300，超過則視為新一場）: " RECONNECT_SEC
  [ -z "$RECONNECT_SEC" ] && RECONNECT_SEC=300

  SESSION_NAME="ms_auto_$(date +%m%d_%H%M%S)"
  LOG_FILE="$LOG_DIR/${SESSION_NAME}.log"

  CMD="python3 \"$AUTO_SCRIPT\" \
    --source-url \"$SOURCE_URL\" \
    --title \"$TITLE\" \
    --reconnect-seconds $RECONNECT_SEC \
    2>&1 | tee \"$LOG_FILE\""

  echo -e "${GREEN}將以 screen 後台啟動自動推流，會話名：${SESSION_NAME}${RESET}"
  echo "日誌文件：$LOG_FILE"
  echo
  echo "運行命令："
  echo "$CMD"
  echo

  read -p "確認開始自動推流？(y/n): " go
  if [ "$go" != "y" ] && [ "$go" != "Y" ]; then
    echo "已取消。"
    pause; return
  fi

  screen -S "$SESSION_NAME" -dm bash -lc "$CMD"
  echo -e "${GREEN}已啟動，你可以用 'screen -r $SESSION_NAME' 查看日誌。${RESET}"
  pause
}

relay_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 1. 轉播推流${RESET}"
    echo "1. 手動推流（源地址 + 直播碼）"
    echo "2. 自動推流（YouTube API + 自動建直播間）"
    echo "0. 返回主菜單"
    echo
    read -p "請選擇: " choice
    case "$choice" in
      1) manual_relay ;;
      2) auto_relay ;;
      0) break ;;
      *) echo "無效選擇"; sleep 1 ;;
    esac
  done
}

# ===== 2. 文件推流 =====
file_relay() {
  clear
  echo -e "${CYAN}Magic Stream -> 2. 文件推流${RESET}"
  echo "請先把視頻放到：$VOD_DIR"
  echo

  read -p "請輸入需要直播的文件名（含擴展名）: " FILENAME
  [ -z "$FILENAME" ] && { echo -e "${RED}文件名不能為空。${RESET}"; pause; return; }

  INPUT_FILE="$VOD_DIR/$FILENAME"
  if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${RED}找不到文件：$INPUT_FILE${RESET}"
    pause; return
  fi

  echo "默認平台：YouTube ($YOUTUBE_RTMP_BASE)"
  read -p "請輸入直播碼 (只填 key): " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo -e "${RED}直播碼不能為空。${RESET}"; pause; return; }

  read -p "如需自定 RTMP 前綴，輸入（留空=默認 $YOUTUBE_RTMP_BASE）: " RTMP_PREFIX
  [ -z "$RTMP_PREFIX" ] && RTMP_PREFIX="$YOUTUBE_RTMP_BASE"
  RTMP_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  read -p "請輸入直播時間（秒，0 = 按文件時長及循環自動結束）: " DURATION
  [ -z "$DURATION" ] && DURATION=0
  if [[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -gt 0 ]; then
    DURATION_OPT="-t $DURATION"
  else
    DURATION_OPT=""
  fi

  read -p "請輸入循環次數（0 = 無限循環）: " LOOP
  [ -z "$LOOP" ] && LOOP=0

  if [[ "$LOOP" =~ ^[0-9]+$ ]]; then
    if [ "$LOOP" -eq 0 ]; then
      STREAM_LOOP_OPT="-stream_loop -1"
    elif [ "$LOOP" -eq 1 ]; then
      STREAM_LOOP_OPT="-stream_loop 0"
    else
      EXTRA=$((LOOP - 1))
      STREAM_LOOP_OPT="-stream_loop $EXTRA"
    fi
  else
    STREAM_LOOP_OPT="-stream_loop 0"
  fi

  SESSION_NAME="ms_vod_$(date +%m%d_%H%M%S)"
  LOG_FILE="$LOG_DIR/${SESSION_NAME}.log"

  CMD="ffmpeg -re $STREAM_LOOP_OPT -i \"$INPUT_FILE\" $DURATION_OPT \
    -c:v copy -c:a copy -f flv \"$RTMP_URL\" \
    2>&1 | tee \"$LOG_FILE\""

  echo -e "${GREEN}將以 screen 後台啟動文件推流，會話名：${SESSION_NAME}${RESET}"
  echo "日誌文件：$LOG_FILE"
  echo
  echo "ffmpeg 命令："
  echo "$CMD"
  echo

  read -p "確認開始文件推流？(y/n): " go
  if [ "$go" != "y" ] && [ "$go" != "Y" ]; then
    echo "已取消。"
    pause; return
  fi

  screen -S "$SESSION_NAME" -dm bash -lc "$CMD"
  echo -e "${GREEN}已啟動，你可以用 'screen -r $SESSION_NAME' 查看推流狀態。${RESET}"
  pause
}

# ===== 3. 系統安裝 =====
install_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 3. 直播系統安裝${RESET}"
    echo "1. 系統升級 & 更新 (apt update && upgrade)"
    echo "2. 安裝 Python 環境 (python3, pip)"
    echo "3. 安裝 ffmpeg"
    echo "4. 安裝 YouTube API 依賴"
    echo "0. 返回主菜單"
    echo
    read -p "請選擇: " choice
    case "$choice" in
      1) $SUDO apt update && $SUDO apt -y upgrade; pause ;;
      2) $SUDO apt install -y python3 python3-pip python3-venv; pause ;;
      3) $SUDO apt install -y ffmpeg; pause ;;
      4) pip3 install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib; pause ;;
      0) break ;;
      *) echo "無效選擇"; sleep 1 ;;
    esac
  done
}

# ===== 4. 推流進程管理 =====
process_menu() {
  while true; do
    clear
    echo -e "${CYAN}Magic Stream -> 4. 推流進程管理${RESET}"
  echo "1. 查看所有 screen 會話"
    echo "2. 進入指定 screen 查看推流狀態"
    echo "3. 結束指定 screen（等於結束該路直播）"
    echo "0. 返回主菜單"
    echo
    read -p "請選擇: " choice
    case "$choice" in
      1) screen -ls || echo "當前沒有 screen 會話。"; pause ;;
      2)
        read -p "輸入要進入的 screen 名稱: " SNAME
        [ -z "$SNAME" ] && { echo "名稱不能為空。"; sleep 1; continue; }
        screen -r "$SNAME"
        ;;
      3)
        read -p "輸入要結束的 screen 名稱: " SNAME
        [ -z "$SNAME" ] && { echo "名稱不能為空。"; sleep 1; continue; }
        screen -S "$SNAME" -X quit || echo "結束失敗，可能沒有這個會話。"
        pause
        ;;
      0) break ;;
      *) echo "無效選擇"; sleep 1 ;;
    esac
  done
}

# ===== 主菜單 =====
main_menu() {
  while true; do
    clear
    echo -e "${CYAN}"
    echo "========================================"
    echo "             Magic Stream"
    echo "           直播推流腳本 v0.1"
    echo "========================================"
    echo -e "${RESET}"
    echo "1. 轉播推流"
    echo "2. 文件推流"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "0. 退出腳本"
    echo "----------------------------------------"
    read -p "請選擇: " choice
    case "$choice" in
      1) relay_menu ;;
      2) file_relay ;;
      3) install_menu ;;
      4) process_menu ;;
      0) echo "Bye~"; exit 0 ;;
      *) echo "無效選擇"; sleep 1 ;;
    esac
  done
}

main_menu
