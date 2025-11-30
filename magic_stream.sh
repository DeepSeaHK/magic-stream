#!/bin/bash

# ============================================
# Magic Stream 直播推流腳本  v0.8.3 (License UI)
# ============================================

INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
PYTHON_BIN="$INSTALL_DIR/venv/bin/python"

# 顏色定義
C_RESET="\e[0m"
C_TITLE="\e[38;5;51m"
C_MENU="\e[38;5;45m"
C_WARN="\e[38;5;220m"
C_ERR="\e[31m"
C_OK="\e[32m"
C_DIM="\e[90m"
C_INPUT="\e[38;5;159m"

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR"

if [ ! -x "$PYTHON_BIN" ]; then PYTHON_BIN="python3"; fi

# ------------------ 核心 UI ------------------
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
  echo "            Magic Stream 直播推流腳本  v0.8.3"
  echo -e "============================================================${C_RESET}"
  echo
}

pause_return() { echo; read -rp "按任意鍵返回選單..." -n1 _; }

confirm_action() {
  echo
  echo -e "${C_WARN}請確認以上信息無誤。${C_RESET}"
  read -rp "是否立即啟動推流？(y/n): " ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

ensure_env() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${C_ERR}[致命錯誤] 系統缺失 ffmpeg！${C_RESET}"
    echo "請重新運行 install.sh 進行修復。"
    pause_return; main_menu
  fi
}

ensure_python_venv() {
  if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
    echo -e "${C_WARN}[提示] 正在初始化環境...${C_RESET}"
  fi
}

ensure_python_auth() {
  if [ ! -f "$AUTH_DIR/token.json" ]; then
    echo -e "${C_ERR}[錯誤] 未找到 API 憑證 (token.json)！${C_RESET}"
    echo "自動模式需要 YouTube API 授權。"
    echo "請將憑證上傳至: $AUTH_DIR"
    pause_return; return 1
  fi
}

next_screen_name() {
  local prefix="$1"
  local max_id
  max_id=$(screen -ls 2>/dev/null | grep -o "${prefix}_[0-9]\+" | sed 's/.*_//' | sort -n | tail -n1 || true)
  if [ -z "$max_id" ]; then max_id=1; else max_id=$((max_id + 1)); fi
  printf "%s_%02d" "$prefix" "$max_id"
}

# ------------- 1. 轉播推流 -------------

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流${C_RESET}"
    echo "1. 手動 RTMP 轉播 (輸入連結 -> 直接推流)"
    echo "2. 自動轉播 (API 監控模式 - 斷流自動重建)"
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

relay_manual_rtmp() {
  ensure_env
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動 RTMP 轉播${C_RESET}"
  echo
  read -rp "請輸入直播源 URL: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return
  read -rp "請輸入 RTMP 位址（預設 rtmp://a.rtmp.youtube.com/live2）: " TMP_RTMP
  RTMP_ADDR="${TMP_RTMP:-rtmp://a.rtmp.youtube.com/live2}"
  read -rp "請輸入直播串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  draw_header
  echo -e "${C_MENU}--- 任務摘要 (直接推流) ---${C_RESET}"
  echo -e "直播源   : ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "核心優化 : ${C_OK}H.264 流複製 (無轉碼/防卡頓)${C_RESET}"
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD
  CMD="while true; do \
    echo \"[\$(date)] 啟動推流...\"; \
    ffmpeg -hide_banner -loglevel error \
      -user_agent \"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1\" \
      -headers \"Referer: https://live.douyin.com/\" \
      -rw_timeout 10000000 \
      -i \"$SOURCE_URL\" \
      -c copy -f flv \"$RTMP_ADDR/$STREAM_KEY\"; \
    echo \"[\$(date)] 直播中斷，5秒後重連...\"; \
    sleep 5; \
  done"

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""
  echo -e "${C_OK}推流已啟動 [$SCREEN_NAME]。${C_RESET}"; pause_return
}

relay_auto_youtube() {
  ensure_env
  ensure_python_auth || return

  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播 (API 監控)${C_RESET}"
  echo
  read -rp "請輸入直播源 URL (探針目標): " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return

  read -rp "請輸入 YouTube 直播標題: " TITLE
  [ -z "$TITLE" ] && TITLE="Magic Stream Live"

  echo; echo "隱私狀態: 1.公開  2.不公開(預設)  3.私享"
  read -rp "選擇: " p
  case "$p" in 1) PRIV="public";; 3) PRIV="private";; *) PRIV="unlisted";; esac

  echo; read -rp "斷流容忍時間 (秒，預設300): " TO
  TIMEOUT="${TO:-300}"

  draw_header
  echo -e "${C_MENU}--- 任務摘要 (自動值守) ---${C_RESET}"
  echo -e "監控源   : ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "標題     : ${C_INPUT}$TITLE${C_RESET}"
  echo -e "核心狀態 : ${C_OK}已啟用加密內核 (v0.7.5 Ultra)${C_RESET}"
  
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME=$(next_screen_name "ms_auto")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD="cd \"$INSTALL_DIR\" && \"$PYTHON_BIN\" -u \"$INSTALL_DIR/magic_autostream.py\" \
    --source-url \"$SOURCE_URL\" \
    --title \"$TITLE\" \
    --privacy \"$PRIV\" \
    --reconnect-seconds \"$TIMEOUT\" \
    --auth-dir \"$AUTH_DIR\""

  screen -S "$SCREEN_NAME" -dm bash -c "$CMD 2>&1 | tee \"$LOG_FILE\""
  echo -e "${C_OK}自動值守進程已啟動 [$SCREEN_NAME]。${C_RESET}"; pause_return
}

# ------------- 2. 文件推流 -------------

menu_vod() {
  ensure_env
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo "視頻目錄：$VOD_DIR"
  read -rp "請輸入文件名: " FILE_NAME
  [ -z "$FILE_NAME" ] && return
  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then echo -e "${C_ERR}文件不存在${C_RESET}"; pause_return; return; fi
  read -rp "請輸入串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  echo; echo "推流模式： 1.無限循環  2.定時停止  3.定次播放"
  read -rp "請選擇 (1-3): " mode_choice
  local FFMPEG_OPTS="-stream_loop -1"
  local MODE_DESC="無限循環"

  case "$mode_choice" in
    2) read -rp "時長(分鐘): " m; FFMPEG_OPTS="-stream_loop -1 -t $((m*60))"; MODE_DESC="定時 $m 分鐘" ;;
    3) read -rp "重複次數: " c; FFMPEG_OPTS="-stream_loop $c"; MODE_DESC="定次 $c 回" ;;
  esac

  draw_header
  echo -e "${C_MENU}--- 任務摘要 ---${C_RESET}"
  echo -e "文件: ${C_INPUT}$FILE_NAME${C_RESET}"
  echo -e "模式: ${C_OK}$MODE_DESC${C_RESET}"
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"
  local CMD="ffmpeg -re $FFMPEG_OPTS -i \"$FULL_PATH\" -c copy -f flv \"rtmp://a.rtmp.youtube.com/live2/$STREAM_KEY\""
  local FULL_CMD="$CMD; echo '任務完成，60秒後關閉...'; sleep 60"

  screen -S "$SCREEN_NAME" -dm bash -c "$FULL_CMD 2>&1 | tee \"$LOG_FILE\""
  echo -e "${C_OK}推流已啟動 [$SCREEN_NAME]。${C_RESET}"; pause_return
}

# ------------- 3. 進程管理 -------------

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 進程管理${C_RESET}"
    echo "1. 查看狀態"
    echo "2. 停止指定直播"
    echo "0. 返回"
    read -rp "選擇: " c
    case "$c" in
      1) screen -ls | grep "ms_" || echo "無運行中進程"; pause_return ;;
      2) process_kill ;;
      0) return ;;
    esac
  done
}

process_kill() {
  draw_header; echo -e "${C_MENU}停止指定直播${C_RESET}"; echo
  mapfile -t SESSIONS < <(screen -ls | grep -oE "[0-9]+\.ms_(manual|vod|smart|auto)_[0-9]+" | sort)
  if [ ${#SESSIONS[@]} -eq 0 ]; then echo "無進程。"; pause_return; return; fi

  local i=1
  for sess in "${SESSIONS[@]}"; do
    echo -e " ${C_OK}[$i]${C_RESET} ${sess#*.}"
    ((i++))
  done
  echo; read -rp "輸入序號 (0返回): " k
  if [[ "$k" == "0" ]]; then return; fi
  if [[ ! "$k" =~ ^[0-9]+$ ]] || [ "$k" -gt "${#SESSIONS[@]}" ]; then echo "無效序號"; sleep 1; return; fi
  
  local target="${SESSIONS[$((k-1))]}"
  screen -S "$target" -X quit
  echo -e "${C_OK}已停止: ${target#*.}${C_RESET}"; pause_return
}

# ------------- 4. 系統維護 -------------

menu_update() {
    draw_header; echo "正在從 GitHub 拉取最新版..."; 
    curl -fsSL "https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main/magic_stream.sh?t=$(date +%s)" -o magic_stream.sh
    chmod +x magic_stream.sh
    echo "更新完成，重啟中..."; sleep 1; exec "$0" "$@"
}

# 5. 功能授權 (全新升級版)
show_license_info() {
  ensure_python_venv
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 功能授權${C_RESET}"
  echo "正在連接授權服務器 (GitHub Gist)..."
  
  cd "$INSTALL_DIR" || return
  
  # 1. 獲取 Python 輸出 (機器碼)
  # 2. 獲取 Python 退出狀態碼 (0=已授權, 1=未授權)
  MACHINE_ID=$("$PYTHON_BIN" magic_autostream.py --check-license)
  RET_CODE=$?
  
  echo
  echo "============================================"
  echo -e " 本機機器碼: ${C_WARN}${MACHINE_ID}${C_RESET}"
  
  if [ $RET_CODE -eq 0 ]; then
      echo -e " 授權狀態  : ${C_OK}✅ 已授權 (Active)${C_RESET}"
      echo "============================================"
      echo
      echo -e "${C_OK}恭喜！您的設備已在白名單中。${C_RESET}"
      echo "您可以正常使用所有功能。"
  else
      echo -e " 授權狀態  : ${C_ERR}❌ 未授權 (Inactive)${C_RESET}"
      echo "============================================"
      echo
      echo -e "${C_ERR}[警告] 腳本未激活，無法使用自動轉播功能。${C_RESET}"
      echo "請複製上方黃色機器碼，發送給管理員開通權限。"
  fi
  echo
  pause_return
}

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream 主控台${C_RESET}"
    echo "1. 轉播推流"
    echo "2. 文件推流"
    echo "3. 進程管理"
    echo "4. 更新腳本"
    echo "5. 功能授權 (狀態檢測)"
    echo "0. 退出"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) menu_process ;;
      4) menu_update ;;
      5) show_license_info ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu