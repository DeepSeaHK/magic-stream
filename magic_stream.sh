#!/bin/bash
set -e

# ============================================
# Magic Stream 直播推流腳本  v0.5.1
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

mkdir -p "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR" "$INSTALL_DIR/run"

# 如果 venv python 不存在，用系統 python3
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python3"
fi

# ------------------ 通用 UI ------------------

draw_header() {
  clear
  echo -e "${C_TITLE}==============================================${C_RESET}"
  echo -e "${C_TITLE}  Magic Stream 直播推流腳本        v0.5.1${C_RESET}"
  echo -e "${C_TITLE}==============================================${C_RESET}"
  echo
}

pause() {
  echo
  echo -ne "${C_DIM}按回車鍵返回...${C_RESET}"
  read -r _
}

# 根據類型取下一個 ID（log 名來決定）
next_id() {
  local prefix="$1" max=0 num f
  if [ -d "$LOG_DIR" ]; then
    for f in "$LOG_DIR"/${prefix}_*.log; do
      [ -e "$f" ] || continue
      num="${f##${LOG_DIR}/${prefix}_}"
      num="${num%.log}"
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        (( num > max )) && max="$num"
      fi
    done
  fi
  printf "%02d" $((max + 1))
}

# 只列出 Magic Stream 用的 screen 名
list_ms_screens() {
  screen -ls 2>/dev/null | \
    sed -n 's/^[[:space:]]*[0-9]\+\.\(ms_[^[:space:]]*\).*/\1/p'
}

# ------------------ 1. 轉播推流 ------------------

start_manual_relay() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.1 手動轉播（任意 RTMP）${C_RESET}"
  echo
  echo -e "${C_DIM}說明：用現成的直播碼 + RTMP 位址，從抖音 / 其它平台轉播到 YouTube 或任何 RTMP 服務。${C_RESET}"
  echo
  read -rp "請輸入直播源地址（如抖音 FLV 播放地址）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo -e "${C_ERR}源地址不能為空。${C_RESET}"; pause; return; }

  read -rp "請輸入直播碼（僅 key，例如 44zx-xxxx-xxxx-xxxx）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo -e "${C_ERR}直播碼不能為空。${C_RESET}"; pause; return; }

  echo
  echo -e "${C_MENU}預設 RTMP 平台：${C_RESET}${C_DIM}YouTube${C_RESET}"
  echo -e "${C_DIM}預設地址：rtmp://a.rtmp.youtube.com/live2${C_RESET}"
  read -rp "如需自定 RTMP 前綴，請輸入（留空使用預設）: " RTMP_PREFIX
  [ -z "$RTMP_PREFIX" ] && RTMP_PREFIX="rtmp://a.rtmp.youtube.com/live2"

  local TARGET_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  local id screen_name log_file run_script
  id="$(next_id "ms_manual")"
  screen_name="ms_manual_${id}"
  log_file="$LOG_DIR/${screen_name}.log"
  run_script="$RUN_DIR/run/${screen_name}.sh"

  cat > "$run_script" <<EOF
#!/bin/bash
LOG_FILE="$log_file"
echo "===== Magic Stream 手動轉播啟動 =====" >> "\$LOG_FILE"
ffmpeg -re -i "$SOURCE_URL" -c:v copy -c:a copy -f flv "$TARGET_URL" >> "\$LOG_FILE" 2>&1
echo "===== Magic Stream 手動轉播結束 =====" >> "\$LOG_FILE"
EOF
  chmod +x "$run_script"

  echo
  echo -e "${C_MENU}啟動 screen 會話: ${C_OK}${screen_name}${C_RESET}"
  echo -e "${C_MENU}log 檔案: ${C_OK}${log_file}${C_RESET}"
  echo

  screen -S "$screen_name" -dm "$run_script"

  echo -e "${C_OK}已在後台啟動 ffmpeg 轉播。${C_RESET}"
  echo -e "${C_DIM}可用 4. 推流進程管理 查看狀態或結束。${C_RESET}"
  pause
}

start_auto_relay() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 1.2 自動轉播（YouTube API）${C_RESET}"
  echo
  echo -e "${C_DIM}說明：用 Douyin / 其它直播源，自動建立 YouTube 直播間並推流。${C_RESET}"
  echo -e "${C_DIM}需要：${AUTH_DIR}/client_secret.json 及 token.json${C_RESET}"
  echo

  read -rp "請輸入直播源地址（如抖音 FLV 播放地址）: " SOURCE_URL
  [ -z "$SOURCE_URL" ] && { echo -e "${C_ERR}源地址不能為空。${C_RESET}"; pause; return; }

  read -rp "請輸入 YouTube 直播標題（留空自動生成）: " TITLE
  # 去掉標題裡的引號，以免破壞命令
  TITLE="${TITLE//\"/}"
  TITLE="${TITLE//\'/}"

  read -rp "斷線重連間隔秒數（預設 60）: " RECONNECT
  [ -z "$RECONNECT" ] && RECONNECT="60"

  read -rp "源長時間離線後停止本次直播的秒數（0 = 永不停止，預設 0）: " OFFLINE
  [ -z "$OFFLINE" ] && OFFLINE="0"

  local id screen_name log_file run_script
  id="$(next_id "ms_auto")"
  screen_name="ms_auto_${id}"
  log_file="$LOG_DIR/${screen_name}.log"
  run_script="$RUN_DIR/run/${screen_name}.sh"

  cat > "$run_script" <<EOF
#!/bin/bash
LOG_FILE="$log_file"
echo "===== Magic Stream 自動轉播啟動 =====" >> "\$LOG_FILE"
"$PYTHON_BIN" "$RUN_DIR/magic_autostream.py" \
  --source-url "$SOURCE_URL" \
  --title "$TITLE" \
  --reconnect-seconds "$RECONNECT" \
  --offline-seconds "$OFFLINE" \
  --auth-dir "$AUTH_DIR" >> "\$LOG_FILE" 2>&1
echo "===== Magic Stream 自動轉播結束 =====" >> "\$LOG_FILE"
EOF
  chmod +x "$run_script"

  echo
  echo -e "${C_MENU}啟動 screen 會話: ${C_OK}${screen_name}${C_RESET}"
  echo -e "${C_MENU}log 檔案: ${C_OK}${log_file}${C_RESET}"
  echo

  screen -S "$screen_name" -dm "$run_script"

  echo -e "${C_OK}已在後台啟動自動轉播流程。${C_RESET}"
  echo -e "${C_DIM}首次使用 YouTube API 會彈出瀏覽器要求授權。${C_RESET}"
  pause
}

menu_relay() {
  while true; do
    draw_header
    echo -e "${C_MENU}1. 轉播推流（直播源 -> RTMP）${C_RESET}"
    echo
    echo "  1. 手動轉播（任意 RTMP，輸入串流地址 + key）"
    echo "  2. 自動轉播（YouTube API，自動開直播間）"
    echo "  0. 返回主菜單"
    echo
    read -rp "請選擇: " sub
    case "$sub" in
      1) start_manual_relay ;;
      2) start_auto_relay ;;
      0) return ;;
      *) echo -e "${C_ERR}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# ------------------ 2. 文件推流 ------------------

start_vod_stream() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 2. 文件推流（點播文件 = 直播）${C_RESET}"
  echo
  echo -e "${C_DIM}請先把視頻放到：${VOD_DIR}${C_RESET}"
  echo

  read -rp "請輸入需要直播的文件名（含擴展名）: " VOD_NAME
  local VOD_PATH="$VOD_DIR/$VOD_NAME"
  if [ ! -f "$VOD_PATH" ]; then
    echo -e "${C_ERR}文件不存在：$VOD_PATH${C_RESET}"
    pause
    return
  fi

  read -rp "請輸入直播碼（僅 key，例如 44zx-xxxx-xxxx-xxxx）: " STREAM_KEY
  [ -z "$STREAM_KEY" ] && { echo -e "${C_ERR}直播碼不能為空。${C_RESET}"; pause; return; }

  echo
  echo -e "${C_MENU}預設 RTMP 平台：${C_RESET}${C_DIM}YouTube${C_RESET}"
  echo -e "${C_DIM}預設地址：rtmp://a.rtmp.youtube.com/live2${C_RESET}"
  read -rp "如需自定 RTMP 前綴，請輸入（留空使用預設）: " RTMP_PREFIX
  [ -z "$RTMP_PREFIX" ] && RTMP_PREFIX="rtmp://a.rtmp.youtube.com/live2"
  local TARGET_URL="${RTMP_PREFIX}/${STREAM_KEY}"

  echo
  read -rp "循環播放次數（0 = 無限循環，預設 0）: " LOOP
  [ -z "$LOOP" ] && LOOP="0"

  local LOOP_OPT=""
  if [ "$LOOP" = "0" ]; then
    LOOP_OPT="-stream_loop -1"
  else
    LOOP_OPT="-stream_loop $LOOP"
  fi

  local id screen_name log_file run_script
  id="$(next_id "ms_vod")"
  screen_name="ms_vod_${id}"
  log_file="$LOG_DIR/${screen_name}.log"
  run_script="$RUN_DIR/run/${screen_name}.sh"

  cat > "$run_script" <<EOF
#!/bin/bash
LOG_FILE="$log_file"
echo "===== Magic Stream 文件推流啟動 =====" >> "\$LOG_FILE"
ffmpeg -re $LOOP_OPT -i "$VOD_PATH" -c:v copy -c:a copy -f flv "$TARGET_URL" >> "\$LOG_FILE" 2>&1
echo "===== Magic Stream 文件推流結束 =====" >> "\$LOG_FILE"
EOF
  chmod +x "$run_script"

  echo
  echo -e "${C_MENU}啟動 screen 會話: ${C_OK}${screen_name}${C_RESET}"
  echo -e "${C_MENU}log 檔案: ${C_OK}${log_file}${C_RESET}"
  echo

  screen -S "$screen_name" -dm "$run_script"

  echo -e "${C_OK}已在後台啟動文件推流。${C_RESET}"
  pause
}

menu_vod() {
  start_vod_stream
}

# ------------------ 3. 系統安裝 ------------------

install_system() {
  while true; do
    draw_header
    echo -e "${C_MENU}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo "1. 系統升級 & 更新（apt update && upgrade）"
    echo "2. 安裝 Python 環境（python3, pip）"
    echo "3. 安裝 ffmpeg"
    echo "4. 安裝 / 修復 YouTube API 依賴（建立 venv）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇: " sub
    case "$sub" in
      1)
        apt update && apt upgrade -y
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
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"
        python3 -m venv venv
        "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
        "$INSTALL_DIR/venv/bin/pip" install --upgrade \
          google-api-python-client google-auth-httplib2 google-auth-oauthlib
        echo -e "${C_OK}YouTube API 依賴已安裝完成。${C_RESET}"
        pause
        ;;
      0) return ;;
      *) echo -e "${C_ERR}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# ------------------ 4. 推流進程管理 ------------------

show_all_screens() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.1 所有 screen 會話${C_RESET}"
  echo
  local list
  list="$(list_ms_screens)"
  if [ -z "$list" ]; then
    echo -e "${C_WARN}當前沒有 Magic Stream 推流 screen 會話。${C_RESET}"
  else
    echo -e "${C_MENU}當前 Magic Stream 推流相關 screen:${C_RESET}"
    echo "$list" | sed 's/^/  - /'
  fi
  echo
  echo -e "${C_DIM}提示：Magic Stream 推流的會話名稱一般為：ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
  pause
}

view_stream_status() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.2 推流狀態瀏覽${C_RESET}"
  echo
  local list
  list="$(list_ms_screens)"
  if [ -z "$list" ]; then
    echo -e "${C_WARN}當前沒有 Magic Stream 推流 screen 會話。${C_RESET}"
    pause
    return
  fi

  echo -e "${C_MENU}當前 Magic Stream 推流 screen:${C_RESET}"
  echo "$list" | sed 's/^/  - /'
  echo
  read -rp "輸入要查看的 screen 名稱（如 ms_auto_01）: " SNAME
  [ -z "$SNAME" ] && return

  local log_file="$LOG_DIR/${SNAME}.log"
  if [ ! -f "$log_file" ]; then
    echo -e "${C_WARN}找不到對應 log 檔案：$log_file${C_RESET}"
    pause
    return
  fi

  clear
  echo -e "${C_MENU}Magic Stream -> 4.2 推流狀態瀏覽${C_RESET}"
  echo -e "${C_MENU}screen: ${C_OK}${SNAME}${C_RESET}"
  echo -e "${C_MENU}log:    ${C_OK}${log_file}${C_RESET}"
  echo -e "${C_DIM}(顯示最後 30 行 ffmpeg 輸出)${C_RESET}"
  echo "----------------------------------------------"
  tail -n 30 "$log_file"
  echo "----------------------------------------------"
  pause
}

kill_stream_screen() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 4.3 結束指定 screen（結束該路直播）${C_RESET}"
  echo
  local list
  list="$(list_ms_screens)"
  if [ -z "$list" ]; then
    echo -e "${C_WARN}當前沒有 Magic Stream 推流 screen 會話。${C_RESET}"
    pause
    return
  fi

  echo -e "${C_MENU}當前 Magic Stream 推流 screen:${C_RESET}"
  echo "$list" | sed 's/^/  - /'
  echo
  read -rp "輸入要結束的 screen 名稱（如 ms_auto_01）: " SNAME
  [ -z "$SNAME" ] && return

  if screen -S "$SNAME" -Q select . >/dev/null 2>&1; then
    screen -S "$SNAME" -X quit || true
    echo -e "${C_OK}已發送結束指令給 screen: ${SNAME}${C_RESET}"
  else
    echo -e "${C_WARN}找不到 screen: ${SNAME}${C_RESET}"
  fi
  pause
}

menu_process() {
  while true; do
    draw_header
    echo -e "${C_MENU}4. 推流進程管理${C_RESET}"
    echo
    echo "1. 查看所有 screen 會話"
    echo "2. 查看指定 screen 推流狀態（讀取 log）"
    echo "3. 結束指定 screen（等於結束該路直播）"
    echo "0. 返回主菜單"
    echo
    read -rp "請選擇: " sub
    case "$sub" in
      1) show_all_screens ;;
      2) view_stream_status ;;
      3) kill_stream_screen ;;
      0) return ;;
      *) echo -e "${C_ERR}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

# ------------------ 5. 更新腳本 ------------------

update_script() {
  draw_header
  echo -e "${C_MENU}Magic Stream -> 5. 更新腳本（從 GitHub 拉取最新版）${C_RESET}"
  echo
  echo -e "${C_DIM}將從倉庫下載 magic_stream.sh / magic_autostream.py 覆蓋當前版本。${C_RESET}"
  echo
  read -rp "確認更新？(y/n): " yn
  case "$yn" in
    y|Y)
      curl -fsSL "$RAW_BASE/magic_stream.sh" -o "$RUN_DIR/magic_stream.sh"
      curl -fsSL "$RAW_BASE/magic_autostream.py" -o "$RUN_DIR/magic_autostream.py"
      chmod +x "$RUN_DIR/magic_stream.sh"
      echo -e "${C_OK}腳本已更新完成。重新執行 ms 即可。${C_RESET}"
      pause
      ;;
    *)
      echo -e "${C_WARN}已取消更新。${C_RESET}"
      sleep 1
      ;;
  esac
}

# ------------------ 主菜單 ------------------

main_menu() {
  while true; do
    draw_header
    echo -e "${C_MENU}主菜單${C_RESET}"
    echo
    echo "1. 轉播推流   （含：手動 RTMP / 自動 YouTube API）"
    echo "2. 文件推流   （點播文件 = 直播）"
    echo "3. 直播系統安裝"
    echo "4. 推流進程管理"
    echo "5. 更新腳本（從 GitHub 拉取最新版）"
    echo "0. 退出腳本"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
      1) menu_relay ;;
      2) menu_vod ;;
      3) install_system ;;
      4) menu_process ;;
      5) update_script ;;
      0) exit 0 ;;
      *) echo -e "${C_ERR}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

main_menu
