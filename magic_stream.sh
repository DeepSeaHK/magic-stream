#!/bin/bash

# ============================================
# Magic Stream 直播推流腳本  v0.7.4 (Full Auth)
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
C_WARN="\e[38;5;220m" # 亮黄色
C_ERR="\e[31m"
C_OK="\e[32m"
C_DIM="\e[90m"
C_INPUT="\e[38;5;159m"

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR"

if [ ! -x "$PYTHON_BIN" ]; then PYTHON_BIN="python3"; fi

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
  # 注意：版本号在这里
  echo -e "            Magic Stream 直播推流腳本  v0.7.4 (Full Auth)"
  echo -e "============================================================${C_RESET}"
  echo
}

pause_return() {
  echo; read -rp "按任意鍵返回選單..." -n1 _;
}

confirm_action() {
  echo; echo -e "${C_WARN}請確認以上信息無誤。${C_RESET}"
  read -rp "是否立即啟動推流？(y/n): " ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

ensure_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${C_ERR}[錯誤] 找不到 ffmpeg。${C_RESET}"; pause_return; main_menu
  fi
}

ensure_python_venv() {
  if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
    echo -e "${C_WARN}[提示] 尚未建立 Python venv。${C_RESET}"
  fi
}

# 🔴 核心安全门：调用 Python 静默验证，拦截未授权用户
verify_license_gatekeeper() {
  # 调用 Python 脚本的 --check-license 参数
  # 如果验证通过返回 0，失败返回 1
  "$PYTHON_BIN" "$INSTALL_DIR/magic_autostream.py" --check-license >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo
    echo -e "${C_ERR}========================================${C_RESET}"
    echo -e "${C_ERR} [拒絕訪問] 此設備未獲得商業授權！${C_RESET}"
    echo -e "${C_ERR}========================================${C_RESET}"
    echo "請前往「6. 功能授權」獲取機器碼並聯繫管理員。"
    echo
    pause_return
    main_menu # 强制返回主菜单
    exit 1 # 防止继续执行
  fi
}

next_screen_name() {
  local prefix="$1"
  local max_id
  max_id=$(screen -ls 2>/dev/null | grep -o "${prefix}_[0-9]\+" | sed 's/.*_//' | sort -n | tail -n1 || true)
  if [ -z "$max_id" ]; then max_id=1; else max_id=$((max_id + 1)); fi
  printf "%s_%02d" "$prefix" "$max_id"
}

# ------------- 1. 轉播推流 (已加锁) -------------

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流${C_RESET}"
    echo
    echo "1. 手動 RTMP 轉播（YouTube/B站/Twitch）"
    echo "2. 自動轉播（YouTube API 專用）"
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

# 1.1 手動 RTMP (已加锁)
relay_manual_rtmp() {
  verify_license_gatekeeper # 🔒 拦截点
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}1.1 手動 RTMP 轉播 (防掉線版)${C_RESET}"
  echo
  read -rp "直播源 URL: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return
  read -rp "RTMP 位址（Enter 使用預設）: " TMP_RTMP_ADDR
  RTMP_ADDR="${TMP_RTMP_ADDR:-rtmp://a.rtmp.youtube.com/live2}"
  read -rp "串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  draw_header
  echo -e "${C_MENU}--- 任務摘要 ---${C_RESET}"
  echo -e "源: ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "推: ${C_INPUT}$RTMP_ADDR${C_RESET}"
  echo -e "鑰: ${C_INPUT}$STREAM_KEY${C_RESET}"
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"
  # 注意：使用了日期转义符 \$(date) 保证每次循环时间正确
  local CMD="while true; do echo \"[\$(date)] 啟動 FFmpeg...\"; ffmpeg -re -i \"$SOURCE_URL\" -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\"; echo \"[\$(date)] 斷線重連中...\"; sleep 10; done"

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""
  echo; echo -e "${C_OK}已啟動 [$SCREEN_NAME]${C_RESET}"; pause_return
}

# 1.2 自動轉播 (已加锁)
relay_auto_youtube() {
  verify_license_gatekeeper # 🔒 拦截点
  ensure_ffmpeg
  ensure_python_venv
  if [ ! -f "$AUTH_DIR/token.json" ]; then
    echo -e "${C_ERR}[錯誤] 缺少 token.json${C_RESET}"; pause_return; return
  fi

  draw_header
  echo -e "${C_MENU}1.2 自動轉播 (YouTube API)${C_RESET}"
  echo
  read -rp "直播源 URL: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return
  read -rp "標題: " TITLE
  [ -z "$TITLE" ] && TITLE="Magic Stream Live"
  
  echo; echo "隱私狀態: 1)公開 2)不公開 3)私享"
  read -rp "選擇: " p_choice
  case "$p_choice" in 1) P="public";; 3) P="private";; *) P="unlisted";; esac
  
  echo; read -rp "重連等待(秒): " OFFLINE_SEC
  [ -z "$OFFLINE_SEC" ] && OFFLINE_SEC=300

  draw_header
  echo -e "${C_MENU}--- 任務摘要 ---${C_RESET}"
  echo -e "源: ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "題: ${C_INPUT}$TITLE${C_RESET}"
  echo -e "私: ${C_INPUT}$P${C_RESET}"
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_auto")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"
  local CMD="cd \"$INSTALL_DIR\" && \"$PYTHON_BIN\" -u \"$INSTALL_DIR/magic_autostream.py\" --source-url \"$SOURCE_URL\" --title \"$TITLE\" --privacy \"$P\" --reconnect-seconds \"$OFFLINE_SEC\" --auth-dir \"$AUTH_DIR\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""
  echo; echo -e "${C_OK}已啟動 [$SCREEN_NAME]${C_RESET}"; pause_return
}

# 2. 文件推流 (已加锁)
menu_vod() {
  verify_license_gatekeeper # 🔒 拦截点
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}2. 文件推流${C_RESET}"
  read -rp "文件名: " FILE_NAME
  [ -z "$FILE_NAME" ] && return
  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then echo -e "${C_ERR}找不到文件${C_RESET}"; pause_return; return; fi
  
  read -rp "RTMP 位址: " TMP_RTMP_ADDR
  RTMP_ADDR="${TMP_RTMP_ADDR:-rtmp://a.rtmp.youtube.com/live2}"
  read -rp "串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  confirm_action || return
  local SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"
  local CMD="ffmpeg -re -stream_loop -1 -i \"$FULL_PATH\" -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\""
  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""
  echo -e "${C_OK}已啟動 [$SCREEN_NAME]${C_RESET}"; pause_return
}

# 3. 系統安裝 (省略了部分逻辑，请确保完整的 install.sh 是最新的)
menu_install() {
  while true; do
    draw_header
    echo -e "${C_MENU}3. 直播系統安裝${C_RESET}"
    echo "1. 更新系統 (apt update)"
    echo "2. 安裝基礎依賴"
    echo "3. 修復 Python 環境 (requests/google-api)"
    echo "0. 返回"
    read -rp "選擇: " c
    case "$c" in
      1) apt update && apt upgrade -y; pause_return ;;
      2) apt update; apt install -y python3 python3-venv python3-pip ffmpeg; pause_return ;;
      3) install_yt_api_deps; pause_return ;;
      0) return ;;
    esac
  done
}

install_yt_api_deps() {
  mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
  [ ! -d "venv" ] && python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip
  # 确保这里安装了 requests
  pip install google-api-python-client google-auth google-auth-oauthlib google-auth-httplib2 requests pyarmor
  deactivate
  echo -e "${C_OK}修復完成。${C_RESET}"
}

# 4. 進程管理
menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}4. 推流進程管理${C_RESET}"
    echo "1. 查看列表"
    echo "2. 查看詳情"
    echo "3. 停止直播"
    echo "0. 返回"
    read -rp "選擇: " c
    case "$c" in
      1) screen -ls || echo "無會話"; pause_return ;;
      2) process_status ;;
      3) process_kill ;;
      0) return ;;
    esac
  done
}

process_status() {
  draw_header
  local S=$(screen -ls 2>/dev/null | grep -E "ms_(auto|manual|vod)_" | awk '{print $1}' || true)
  [ -z "$S" ] && { echo "無推流進程"; pause_return; return; }
  echo "$S"
  pause_return
}

process_kill() {
  read -rp "輸入 screen 名稱: " SNAME
  [ -n "$SNAME" ] && screen -S "$SNAME" -X quit && echo -e "${C_OK}已停止${C_RESET}"
  pause_return
}

# 5. 更新
menu_update() {
  mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
  curl -fsSL "$RAW_BASE/magic_stream.sh" -o magic_stream.sh.tmp
  curl -fsSL "$RAW_BASE/magic_autostream.py" -o magic_autostream.py
  mv magic_stream.sh.tmp magic_stream.sh
  chmod +x magic_stream.sh magic_autostream.py
  echo -e "${C_OK}已更新，重啟中...${C_RESET}"; sleep 1; exec "$0" "$@"
}

# 🔴 6. 功能授權 (含狀態檢測)
show_license_info() {
  draw_header
  echo -e "${C_MENU}6. 功能授權 & 機器碼${C_RESET}"
  echo
  
  # 1. 确保 Python 环境存在
  local PY_CMD="$PYTHON_BIN"
  if [ ! -x "$PY_CMD" ]; then PY_CMD="python3"; fi
  if ! command -v "$PY_CMD" >/dev/null 2>&1; then
    echo -e "${C_ERR}[錯誤] 找不到 Python 環境，請先執行安裝步驟。${C_RESET}"; pause_return; return
  fi
  
  # 2. 获取机器码 (Python)
  local MACHINE_ID
  MACHINE_ID=$($PY_CMD -c "import uuid, hashlib; node = uuid.getnode(); mac = ':'.join(['{:02x}'.format((node >> ele) & 0xff) for ele in range(0,8*6,8)][::-1]); signature = f'magic_stream_{mac}_v1'; print(hashlib.md5(signature.encode()).hexdigest())")

  # 3. 检查授权状态
  echo -n "正在檢測授權狀態... "
  # 调用 Python 脚本的 --check-license 参数进行联网验证 (静默模式)
  "$PYTHON_BIN" "$INSTALL_DIR/magic_autostream.py" --check-license >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo -e "${C_OK}【已授權】${C_RESET}"
  else
    echo -e "${C_ERR}【未授權】${C_RESET}"
  fi

  echo
  echo -e "============================================"
  echo -e " 本機機器碼: ${C_WARN}${MACHINE_ID}${C_RESET}"
  echo -e "============================================"
  echo "請複製黃色機器碼發送給管理員。"
  pause_return
}

# 主循環
main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主選單${C_RESET}"
    echo "1. 轉播推流（手動 / 自動）"
    echo "2. 文件推流"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本"
    echo "6. 功能授權 (檢測狀態)"
    echo "0. 退出"
    echo
    read -rp "請選擇: " c
    case "$c" in
      1) menu_relay ;; 2) menu_vod ;; 3) menu_install ;; 4) menu_process ;; 5) menu_update ;; 6) show_license_info ;; 0) exit 0 ;;
      *) echo "無效"; sleep 1 ;;
    esac
  done
}

main_menu
