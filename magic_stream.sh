#!/bin/bash
set -e

# ============================================
# Magic Stream 直播推流腳本  v0.5.0
# ============================================

# 安裝目錄（預設：當前用戶的 home）
INSTALL_DIR="$HOME/magic_stream"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
RUN_DIR="$INSTALL_DIR/run"

# Python venv
PYTHON_BIN="$INSTALL_DIR/venv/bin/python"

# GitHub 原始碼位置（給更新腳本用）
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 命令別名：安裝後直接輸入 ms 就能呼出腳本
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"

# ---------- 顏色 ----------
C_RESET="\e[0m"
C_TITLE="\e[96m"
C_MENU="\e[92m"
C_WARN="\e[93m"
C_ERR="\e[91m"
C_DIM="\e[90m"
C_HL="\e[36m"

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR" "$RUN_DIR"

# 如果 venv 還沒建好，先退回系統 python3
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

# ---------- 通用 UI ----------
draw_header() {
  clear
  echo -e "${C_TITLE}============================================================${C_RESET}"
  echo -e "${C_TITLE}  Magic Stream 直播推流腳本   v0.5.0${C_RESET}"
  echo -e "${C_TITLE}============================================================${C_RESET}"
  echo
}

pause() {
  echo
  read -rp "按回車鍵返回菜單..." _
}

# 自動生成 screen 名稱：ms_vod_01 / ms_manual_01 / ms_auto_01 ...
next_screen_name() {
  local prefix="$1"   # 例如 ms_vod / ms_manual / ms_auto
  local n=1
  while true; do
    local name
    name=$(printf "%s_%02d" "$prefix" "$n")
    if ! screen -ls 2>/dev/null | grep -q "$name"; then
      echo "$name"
      return
    fi
    n=$((n + 1))
  done
}

# ============================================================
# 1. 轉播推流（手動 RTMP / 自動 YouTube API）
# ============================================================

relay_manual() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動轉播 (RTMP 中繼)${C_RESET}"
  echo
  read -rp "輸入直播源地址 (rtmp / http-flv / m3u8 等)： " SOURCE_URL
  if [ -z "$SOURCE_URL" ]; then
    echo -e "${C_ERR}錯誤：直播源地址不能為空。${C_RESET}"
    pause
    return
  fi

  local DEFAULT_RTMP="rtmp://a.rtmp.youtube.com/live2"
  read -rp "輸入目標 RTMP 前綴（預設：$DEFAULT_RTMP）：" RTMP_PREFIX
  if [ -z "$RTMP_PREFIX" ]; then
    RTMP_PREFIX="$DEFAULT_RTMP"
  fi

  read -rp "輸入直播碼 (stream key)： " STREAM_KEY
  if [ -z "$STREAM_KEY" ]; then
    echo -e "${C_ERR}錯誤：直播碼不能為空。${C_RESET}"
    pause
    return
  fi

  local RTMP_URL="${RTMP_PREFIX%/}/$STREAM_KEY"

  read -rp "輸入推流時長（分鐘，0 = 不限制）： " DURATION_MIN
  DURATION_MIN=${DURATION_MIN:-0}

  read -rp "如需額外 ffmpeg 參數可輸入（可留空，例如：-vf \"scale=1080:1920\"）： " EXTRA_OPTS

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_manual")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}.log"

  local SRC_Q RTMP_Q LOG_Q
  SRC_Q=$(printf '%q' "$SOURCE_URL")
  RTMP_Q=$(printf '%q' "$RTMP_URL")
  LOG_Q=$(printf '%q' "$LOG_FILE")

  local FF_CMD="ffmpeg -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"

  if [ "$DURATION_MIN" -gt 0 ] 2>/dev/null; then
    local DURATION_SEC=$((DURATION_MIN * 60))
    FF_CMD+=" -t $DURATION_SEC"
  fi

  if [ -n "$EXTRA_OPTS" ]; then
    FF_CMD+=" $EXTRA_OPTS"
  fi

  FF_CMD+=" -i $SRC_Q -c copy -f flv $RTMP_Q"

  echo
  echo -e "${C_MENU}將使用 screen 啟動以下命令，會話名：${C_HL}${SCREEN_NAME}${C_RESET}"
  echo -e "${C_DIM}$FF_CMD${C_RESET}"
  echo -e "日誌檔案：${C_DIM}$LOG_FILE${C_RESET}"
  echo
  read -rp "確認開始推流並進入後台？ (y/n)： " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    pause
    return
  fi

  screen -dmS "$SCREEN_NAME" bash -c "$FF_CMD 2>&1 | tee -a $LOG_Q"
  echo
  echo -e "${C_MENU}已在後台啟動手動轉播，screen 會話：${C_HL}${SCREEN_NAME}${C_RESET}"
  pause
}

relay_auto() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播 (YouTube API)${C_RESET}"
  echo
  echo -e "${C_DIM}※ 需要事先在 ${AUTH_DIR} 放入 client_secret.json 和 token.json${C_RESET}"
  echo

  read -rp "輸入直播源地址 (http-flv / m3u8 等)： " SOURCE_URL
  if [ -z "$SOURCE_URL" ]; then
    echo -e "${C_ERR}錯誤：直播源地址不能為空。${C_RESET}"
    pause
    return
  fi

  read -rp "YouTube 直播標題（可含日期、平台等）： " TITLE
  [ -z "$TITLE" ] && TITLE="Magic Stream 自動轉播"

  read -rp "斷線重連窗口（秒，超過視為本場直播結束，預設 300）： " RECONNECT_SEC
  RECONNECT_SEC=${RECONNECT_SEC:-300}

  read -rp "探針檢測間隔（秒，預設 30）： " PROBE_SEC
  PROBE_SEC=${PROBE_SEC:-30}

  read -rp "隱私狀態（public / unlisted / private，預設 unlisted）： " PRIVACY
  PRIVACY=${PRIVACY:-unlisted}

  if [ ! -f "$AUTH_DIR/client_secret.json" ]; then
    echo -e "${C_ERR}錯誤：找不到 ${AUTH_DIR}/client_secret.json${C_RESET}"
    pause
    return
  fi

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_auto")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}.log"

  local PY_Q SCRIPT_Q SRC_Q TITLE_Q AUTH_Q LOG_Q
  PY_Q=$(printf '%q' "$PYTHON_BIN")
  SCRIPT_Q=$(printf '%q' "$INSTALL_DIR/magic_autostream.py")
  SRC_Q=$(printf '%q' "$SOURCE_URL")
  TITLE_Q=$(printf '%q' "$TITLE")
  AUTH_Q=$(printf '%q' "$AUTH_DIR")
  LOG_Q=$(printf '%q' "$LOG_FILE")
  PRIV_Q=$(printf '%q' "$PRIVACY")

  local CMD="$PY_Q $SCRIPT_Q --source-url $SRC_Q --title $TITLE_Q --reconnect-seconds $RECONNECT_SEC --probe-interval $PROBE_SEC --privacy-status $PRIV_Q --auth-dir $AUTH_Q"

  echo
  echo -e "${C_MENU}將以 screen 會話 ${C_HL}${SCREEN_NAME}${C_RESET} 啟動自動轉播。"
  echo -e "${C_DIM}$CMD${C_RESET}"
  echo -e "日誌檔案：${C_DIM}$LOG_FILE${C_RESET}"
  echo
  read -rp "確認啟動自動轉播守護進程？ (y/n)： " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    pause
    return
  fi

  screen -dmS "$SCREEN_NAME" bash -c "$CMD 2>&1 | tee -a $LOG_Q"
  echo
  echo -e "${C_MENU}已在後台啟動自動轉播守護進程。screen 會話：${C_HL}${SCREEN_NAME}${C_RESET}"
  pause
}

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}主菜單 -> 1. 轉播推流${C_RESET}"
    echo
    echo "  1. 手動轉播  (自定 RTMP，適合單次測試 / 非 YouTube 平台)"
    echo "  2. 自動轉播  (對接 YouTube API，斷線自動開新直播)"
    echo "  0. 返回主菜單"
    echo
    read -rp "請選擇： " CH
    case "$CH" in
      1) relay_manual ;;
      2) relay_auto ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# ============================================================
# 2. 文件推流
# ============================================================

menu_vod() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流${C_RESET}"
  echo -e "請先把影片放到：${C_HL}$VOD_DIR${C_RESET}"
  echo
  read -rp "輸入需要直播的文件名（含副檔名，例如 test.mp4）： " FILE_NAME

  if [ -z "$FILE_NAME" ]; then
    echo -e "${C_ERR}錯誤：文件名不能為空。${C_RESET}"
    pause
    return
  fi

  local FULL_PATH="$VOD_DIR/$FILE_NAME"
  if [ ! -f "$FULL_PATH" ]; then
    echo -e "${C_ERR}錯誤：找不到文件：$FULL_PATH${C_RESET}"
    pause
    return
  fi

  local DEFAULT_RTMP="rtmp://a.rtmp.youtube.com/live2"
  read -rp "輸入目標 RTMP 前綴（預設：$DEFAULT_RTMP）： " RTMP_PREFIX
  [ -z "$RTMP_PREFIX" ] && RTMP_PREFIX="$DEFAULT_RTMP"

  read -rp "輸入直播碼 (stream key)： " STREAM_KEY
  if [ -z "$STREAM_KEY" ]; then
    echo -e "${C_ERR}錯誤：直播碼不能為空。${C_RESET}"
    pause
    return
  fi
  local RTMP_URL="${RTMP_PREFIX%/}/$STREAM_KEY"

  read -rp "循環次數（0 = 無限循環）： " LOOP_COUNT
  LOOP_COUNT=${LOOP_COUNT:-0}

  read -rp "如需額外 ffmpeg 參數可輸入（可留空）： " EXTRA_OPTS

  local SCREEN_NAME
  SCREEN_NAME=$(next_screen_name "ms_vod")
  local LOG_FILE="$LOG_DIR/${SCREEN_NAME}.log"

  local FILE_Q RTMP_Q LOG_Q
  FILE_Q=$(printf '%q' "$FULL_PATH")
  RTMP_Q=$(printf '%q' "$RTMP_URL")
  LOG_Q=$(printf '%q' "$LOG_FILE")

  local FF_CMD="ffmpeg"

  if [ "$LOOP_COUNT" -eq 0 ] 2>/dev/null; then
    FF_CMD+=" -stream_loop -1"
  elif [ "$LOOP_COUNT" -gt 1 ] 2>/dev/null; then
    local LOOP_ARG=$((LOOP_COUNT - 1))
    FF_CMD+=" -stream_loop $LOOP_ARG"
  fi

  if [ -n "$EXTRA_OPTS" ]; then
    FF_CMD+=" $EXTRA_OPTS"
  fi

  FF_CMD+=" -re -i $FILE_Q -c copy -f flv $RTMP_Q"

  echo
  echo -e "${C_MENU}將使用 screen 會話 ${C_HL}${SCREEN_NAME}${C_RESET} 推送文件直播。"
  echo -e "${C_DIM}$FF_CMD${C_RESET}"
  echo -e "日誌檔案：${C_DIM}$LOG_FILE${C_RESET}"
  echo
  read -rp "確認開始文件推流？ (y/n)： " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    pause
    return
  fi

  screen -dmS "$SCREEN_NAME" bash -c "$FF_CMD 2>&1 | tee -a $LOG_Q"
  echo
  echo -e "${C_MENU}已在後台啟動文件推流，screen 會話：${C_HL}${SCREEN_NAME}${C_RESET}"
  pause
}

# ============================================================
# 3. 直播系統安裝
# ============================================================

install_system() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo "  1. 系統升級 & 更新   (apt update && apt upgrade)"
    echo "  2. 安裝 Python 環境  (python3, pip, venv)"
    echo "  3. 安裝 ffmpeg"
    echo "  4. 安裝 / 修復 YouTube API 依賴 (建立 venv)"
    echo "  0. 返回主菜單"
    echo
    read -rp "請選擇： " CH
    case "$CH" in
      1)
        apt update
        apt upgrade -y
        pause
        ;;
      2)
        apt install -y python3 python3-pip python3-venv
        pause
        ;;
      3)
        apt install -y ffmpeg
        pause
        ;;
      4)
        echo "建立 / 修復 Python venv..."
        mkdir -p "$INSTALL_DIR"
        python3 -m venv "$INSTALL_DIR/venv"
        "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
        "$INSTALL_DIR/venv/bin/pip" install google-auth google-auth-oauthlib google-api-python-client requests
        echo
        echo -e "${C_MENU}YouTube API 相關依賴已安裝完成。${C_RESET}"
        pause
        ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# ============================================================
# 4. 推流進程管理
# ============================================================

manage_screens() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo
    echo "  1. 查看所有 screen 會話"
    echo "  2. 進入指定 screen 查看推流狀態"
    echo "  3. 結束指定 screen（等於結束該路直播）"
    echo "  0. 返回主菜單"
    echo
    read -rp "請選擇： " CH
    case "$CH" in
      1)
        draw_header
        echo -e "${C_MENU}Magic Stream -> 4.1 所有 screen 會話${C_RESET}"
        echo
        screen -ls || true
        echo
        echo -e "${C_DIM}提示：Magic Stream 推流的會話名稱一律為：${C_HL}ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
        pause
        ;;
      2)
        draw_header
        echo -e "${C_MENU}Magic Stream -> 4.2 進入指定 screen${C_RESET}"
        echo
        screen -ls || true
        echo
        read -rp "輸入要進入的 screen 名稱（例如 ms_vod_01）： " SNAME
        if [ -z "$SNAME" ]; then
          echo -e "${C_WARN}未輸入名稱。${C_RESET}"
          sleep 1
        else
          screen -r "$SNAME" || { echo -e "${C_ERR}無法進入會話：$SNAME${C_RESET}"; sleep 2; }
        fi
        ;;
      3)
        draw_header
        echo -e "${C_MENU}Magic Stream -> 4.3 結束指定 screen${C_RESET}"
        echo
        screen -ls || true
        echo
        read -rp "輸入要結束的 screen 名稱（例如 ms_auto_01）： " SNAME
        if [ -z "$SNAME" ]; then
          echo -e "${C_WARN}未輸入名稱。${C_RESET}"
          sleep 1
        else
          read -rp "確認結束會話 $SNAME ？ (y/n)： " CONFIRM
          if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            screen -S "$SNAME" -X quit || true
            echo -e "${C_MENU}已嘗試結束 screen：${C_HL}$SNAME${C_RESET}"
            sleep 1
          fi
        fi
        ;;
      0)
        return
        ;;
      *)
        echo -e "${C_WARN}無效選項。${C_RESET}"
        sleep 1
        ;;
    esac
  done
}

# ============================================================
# 5. 更新腳本
# ============================================================

update_script() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 更新腳本${C_RESET}"
  echo
  echo "從 GitHub 拉取最新版 magic_stream.sh / magic_autostream.py ..."
  echo

  mkdir -p "$INSTALL_DIR"

  if curl -fsSL "$RAW_BASE/magic_stream.sh" -o "$INSTALL_DIR/magic_stream.sh"; then
    chmod +x "$INSTALL_DIR/magic_stream.sh"
    echo -e "${C_MENU}已更新 magic_stream.sh${C_RESET}"
  else
    echo -e "${C_ERR}下載 magic_stream.sh 失敗。${C_RESET}"
  fi

  if curl -fsSL "$RAW_BASE/magic_autostream.py" -o "$INSTALL_DIR/magic_autostream.py"; then
    chmod +x "$INSTALL_DIR/magic_autostream.py"
    echo -e "${C_MENU}已更新 magic_autostream.py${C_RESET}"
  else
    echo -e "${C_ERR}下載 magic_autostream.py 失敗。${C_RESET}"
  fi

  echo
  echo -e "${C_DIM}如有修改安裝路徑或別名，可手動檢查 /usr/local/bin/ms 是否指向正確。${C_RESET}"
  pause
}

# ============================================================
# 主菜單
# ============================================================

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主菜單${C_RESET}"
    echo
    echo "  1. 轉播推流   （含：手動 RTMP / 自動 YouTube API）"
    echo "  2. 文件推流   （點播文件 = 直播）"
    echo "  3. 直播系統安裝"
    echo "  4. 推流進程管理"
    echo "  5. 更新腳本（從 GitHub 拉取最新版本）"
    echo "  0. 退出腳本"
    echo
    read -rp "請選擇： " CH
    case "$CH" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) install_system ;;
      4) manage_screens ;;
      5) update_script ;;
      0) echo "Bye~"; exit 0 ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

main_menu
