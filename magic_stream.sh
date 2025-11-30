#!/bin/bash

# ============================================
# Magic Stream 直播推流腳本  v0.7.8 (Process Manager Pro)
# ============================================

INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"

# 顏色定義
C_RESET="\e[0m"
C_TITLE="\e[38;5;51m"
C_MENU="\e[38;5;45m"
C_WARN="\e[38;5;220m"
C_ERR="\e[31m"
C_OK="\e[32m"
C_DIM="\e[90m"
C_INPUT="\e[38;5;159m"

mkdir -p "$LOG_DIR" "$VOD_DIR"

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
  echo "            Magic Stream 直播推流腳本  v0.7.8"
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

next_screen_name() {
  local prefix="$1"
  local max_id
  max_id=$(screen -ls 2>/dev/null | grep -o "${prefix}_[0-9]\+" | sed 's/.*_//' | sort -n | tail -n1 || true)
  if [ -z "$max_id" ]; then
    max_id=1
  else
    max_id=$((max_id + 1))
  fi
  printf "%s_%02d" "$prefix" "$max_id"
}

# ------------- 1. 轉播推流 (純淨手動版) -------------

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 1. 轉播推流${C_RESET}"
    echo
    echo "1. 手動 RTMP 轉播 (輸入連結 -> 直接推流)"
    echo "0. 返回主選單"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) relay_manual_rtmp ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

relay_manual_rtmp() {
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動 RTMP 轉播${C_RESET}"
  echo
  read -rp "請輸入直播源 URL（例如 FLV 連結）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && return

  read -rp "請輸入 RTMP 位址（預設 rtmp://a.rtmp.youtube.com/live2）: " TMP_RTMP
  RTMP_ADDR="${TMP_RTMP:-rtmp://a.rtmp.youtube.com/live2}"

  read -rp "請輸入直播串流金鑰（Stream Key）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  draw_header
  echo -e "${C_MENU}--- 任務摘要 (直接推流) ---${C_RESET}"
  echo -e "直播源 URL : ${C_INPUT}$SOURCE_URL${C_RESET}"
  echo -e "推流目標   : ${C_INPUT}$RTMP_ADDR/$STREAM_KEY${C_RESET}"
  echo -e "核心優化   : ${C_OK}H.264 流複製 (解決卡頓/黃色警告)${C_RESET}"
  
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD
  CMD="while true; do \
    echo \"[\$(date)] 啟動優化推流...\"; \
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
  echo -e "${C_OK}優化推流已啟動 [$SCREEN_NAME]。${C_RESET}"
  pause_return
}

# ------------- 2. 文件推流 (時長/次數控制) -------------

menu_vod() {
  ensure_ffmpeg
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo
  echo "視頻文件目錄：$VOD_DIR"
  read -rp "請輸入文件名（含副檔名）: " FILE_NAME
  [ -z "$FILE_NAME" ] && return
  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then
    echo -e "${C_ERR}[錯誤] 找不到檔案：$FULL_PATH${C_RESET}"; pause_return; return;
  fi
  
  read -rp "請輸入直播串流金鑰: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && return

  echo
  echo "請選擇推流模式："
  echo "1. 無限循環 (直到手動停止) [預設]"
  echo "2. 定時停止 (例如推流 60 分鐘後自動關閉)"
  echo "3. 定次播放 (例如重複播放 4 次後自動關閉)"
  read -rp "請選擇 (1-3): " mode_choice

  local FFMPEG_OPTS=""
  local MODE_DESC=""

  case "$mode_choice" in
    2)
      read -rp "請輸入推流時長 (分鐘): " mins
      local secs=$((mins * 60))
      FFMPEG_OPTS="-stream_loop -1 -t $secs"
      MODE_DESC="定時停止 ($mins 分鐘)"
      ;;
    3)
      read -rp "請輸入重複次數 (例如 4 代表播完1次再重複4次): " loop_count
      FFMPEG_OPTS="-stream_loop $loop_count"
      MODE_DESC="定次播放 (重複 $loop_count 次)"
      ;;
    *)
      FFMPEG_OPTS="-stream_loop -1"
      MODE_DESC="無限循環 (直到手動停止)"
      ;;
  esac

  draw_header
  echo -e "${C_MENU}--- 任務摘要 (文件推流) ---${C_RESET}"
  echo -e "文件路徑   : ${C_INPUT}$FULL_PATH${C_RESET}"
  echo -e "推流模式   : ${C_OK}$MODE_DESC${C_RESET}"
  echo -e "推流目標   : ...$STREAM_KEY"
  
  confirm_action || { echo "已取消。"; pause_return; return; }

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}_$(date +%m%d_%H%M%S).log"

  local CMD="ffmpeg -re $FFMPEG_OPTS -i \"$FULL_PATH\" -c copy -f flv \"rtmp://a.rtmp.youtube.com/live2/$STREAM_KEY\""
  local FULL_CMD="$CMD; echo '推流任務已完成，Screen 將在 60 秒後關閉...'; sleep 60"

  screen -S "$SCREEN_NAME" -dm bash -c "$FULL_CMD 2>&1 | tee \"$LOG_FILE\""

  echo
  echo -e "${C_OK}文件推流已啟動 [$SCREEN_NAME]。${C_RESET}"
  echo -e "推流結束後，Screen 會自動關閉。"
  pause_return
}

# ------------- 4. 推流進程管理 (重大升級：數字選擇) -------------

process_list_and_kill() {
  draw_header
  echo -e "${C_MENU}4.2 停止指定直播${C_RESET}"
  echo
  
  # 獲取所有相關的 screen 會話 (ms_manual, ms_vod, ms_smart, ms_auto)
  # 使用 mapfile 將 grep 結果存入數組
  mapfile -t SESSIONS < <(screen -ls | grep -oE "[0-9]+\.ms_(manual|vod|smart|auto)_[0-9]+" | sort)

  if [ ${#SESSIONS[@]} -eq 0 ]; then
    echo -e "${C_WARN}目前沒有運行中的直播進程。${C_RESET}"
    pause_return
    return
  fi

  echo "運行中的直播進程："
  echo "--------------------------------"
  local i=1
  for sess in "${SESSIONS[@]}"; do
    # 去掉前面的 PID，只顯示名稱 (例如 ms_manual_01)
    local name="${sess#*.}"
    echo -e " ${C_OK}[$i]${C_RESET} $name"
    ((i++))
  done
  echo "--------------------------------"
  echo " 0. 取消並返回"
  echo
  
  read -rp "請輸入要停止的序號 (1-${#SESSIONS[@]}): " kill_idx

  # 輸入 0 返回
  if [[ "$kill_idx" == "0" ]]; then
    return
  fi

  # 驗證輸入是否為數字且在範圍內
  if [[ ! "$kill_idx" =~ ^[0-9]+$ ]] || [ "$kill_idx" -gt "${#SESSIONS[@]}" ] || [ "$kill_idx" -lt 1 ]; then
    echo -e "${C_ERR}無效序號！${C_RESET}"
    sleep 1
    return
  fi

  # 獲取目標 session
  local target="${SESSIONS[$((kill_idx-1))]}"
  local target_name="${target#*.}"

  echo
  read -rp "確認要停止 [$target_name] 嗎？(y/n): " confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    screen -S "$target" -X quit
    echo -e "${C_OK}已成功停止直播進程：$target_name${C_RESET}"
  else
    echo "已取消操作。"
  fi
  pause_return
}

process_status() {
  draw_header
  echo -e "${C_MENU}4.1 直播狀態概覽${C_RESET}"
  echo
  # 簡單列出 screen -ls 的結果
  screen -ls | grep "ms_" || echo "目前沒有運行中的直播。"
  echo
  pause_return
}

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo "1. 查看狀態概覽"
    echo "2. 停止指定直播 (選擇序號 1, 2, 3...)"
    echo "0. 返回"
    read -rp "選擇: " c
    case "$c" in
      1) process_status ;;
      2) process_list_and_kill ;;
      0) return ;;
    esac
  done
}

# ---------------- 輔助功能 (保持不變) ----------------

menu_update() {
    draw_header; echo "正在更新..."; 
    curl -fsSL "https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main/magic_stream.sh" -o magic_stream.sh
    chmod +x magic_stream.sh
    echo "更新完成，重啟中..."; sleep 1; exec "$0" "$@"
}

menu_install() { echo "請使用 install.sh 進行完整安裝。"; pause_return; }
show_license_info() { echo "功能保留。"; pause_return; }

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主選單${C_RESET}"
    echo "1. 轉播推流 (手動優化版)"
    echo "2. 文件推流 (定時/定次)"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本"
    echo "0. 退出"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) relay_manual_rtmp ;;
      2) menu_vod ;;
      3) menu_install ;;
      4) menu_process ;;
      5) menu_update ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu
