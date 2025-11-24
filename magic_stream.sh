#!/bin/bash
# Magic Stream 直播推流腳本 v0.6.0

set -e

#############################
#  路徑與常量
#############################

# 安裝目錄（以腳本所在目錄為準，更穩定）
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR="$SCRIPT_DIR"

RUN_DIR="$INSTALL_DIR/run"
LOG_DIR="$INSTALL_DIR/logs"
VOD_DIR="$INSTALL_DIR/vod"
AUTH_DIR="$INSTALL_DIR/youtube_auth"
PYTHON_BIN="$INSTALL_DIR/venv/bin/python"
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

VERSION="0.6.0"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$VOD_DIR" "$AUTH_DIR"

#############################
#  顏色
#############################
C_RESET="\e[0m"
C_TITLE="\e[38;5;45m"
C_SUB="\e[38;5;39m"
C_MENU="\e[38;5;82m"
C_WARN="\e[38;5;214m"
C_ERR="\e[31m"
C_DIM="\e[90m"

#############################
#  通用 UI
#############################

draw_header() {
  clear
  echo -e "${C_TITLE}============================================================${C_RESET}"
  echo -e "${C_TITLE}      ███╗   ███╗ █████╗  ██████╗  ██╗ ██████╗            ${C_RESET}"
  echo -e "${C_TITLE}      ████╗ ████║██╔══██╗██╔════╝ ███║██╔════╝            ${C_RESET}"
  echo -e "${C_TITLE}      ██╔████╔██║███████║██║  ███╗╚██║██║  ███╗           ${C_RESET}"
  echo -e "${C_TITLE}      ██║╚██╔╝██║██╔══██║██║   ██║ ██║██║   ██║           ${C_RESET}"
  echo -e "${C_TITLE}      ██║ ╚═╝ ██║██║  ██║╚██████╔╝ ██║╚██████╔╝           ${C_RESET}"
  echo -e "${C_TITLE}      ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝  ╚═╝ ╚═════╝            ${C_RESET}"
  echo -e "${C_TITLE}             Magic Stream 直播推流腳本  v${VERSION}        ${C_RESET}"
  echo -e "${C_TITLE}============================================================${C_RESET}"
  echo
}

pause() {
  echo
  read -rp "按回車鍵繼續..." _
}

read_nonempty() {
  local prompt="$1"
  local var
  while :; do
    read -rp "$prompt" var
    if [[ -n "$var" ]]; then
      echo "$var"
      return
    fi
    echo -e "${C_WARN}不能為空，請重新輸入。${C_RESET}"
  done
}

# 生成新的 screen 名稱（ms_auto_01 / ms_manual_01 / ms_vod_01）
next_screen_name() {
  local prefix="$1"
  local i=1
  while :; do
    local idx
    printf -v idx "%02d" "$i"
    local name="${prefix}_${idx}"
    if ! screen -list 2>/dev/null | grep -q " ${name}[[:space:]]"; then
      echo "$name"
      return
    fi
    i=$((i+1))
  done
}

ensure_python() {
  if [[ ! -x "$PYTHON_BIN" ]]; then
    echo -e "${C_WARN}找不到 Python 虛擬環境：$PYTHON_BIN${C_RESET}"
    echo -e "${C_WARN}請先在主選單中執行：3. 直播系統安裝 -> 2. 安裝 / 修復 Python 環境${C_RESET}"
    pause
    return 1
  fi
}

#############################
# 1. 轉播推流
#############################

menu_restream() {
  while :; do
    draw_header
    echo -e "${C_SUB}Magic Stream -> 1. 轉播推流（抖音 / 其他平台 → YouTube）${C_RESET}"
    echo
    echo -e "${C_MENU}1. 手動 RTMP 轉播（無需 API，直接填推流碼）${C_RESET}"
    echo -e "${C_MENU}2. 自動轉播（使用 YouTube API，自動開新直播間）${C_RESET}"
    echo -e "${C_MENU}0. 返回主選單${C_RESET}"
    echo
    read -rp "請選擇： " ans
    case "$ans" in
      1) restream_manual ;;
      2) restream_auto ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

restream_manual() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 1.1 手動 RTMP 轉播${C_RESET}"
  echo
  local src_url rtmp_url stream_key offline_sec

  src_url=$(read_nonempty "請輸入直播源地址（例如抖音 FLV URL）： ")
  read -rp "請輸入 RTMP 前綴（預設：rtmp://a.rtmp.youtube.com/live2）：" rtmp_url
  rtmp_url="${rtmp_url:-rtmp://a.rtmp.youtube.com/live2}"
  stream_key=$(read_nonempty "請輸入 YouTube 直播碼（僅 key）： ")
  read -rp "最大允許斷線時間（秒，預設 300，超時將認為本場結束）： " offline_sec
  offline_sec="${offline_sec:-300}"

  local session session_log script_file ts
  session=$(next_screen_name "ms_manual")
  ts=$(date +%m%d_%H%M%S)
  session_log="$LOG_DIR/${session}_${ts}.log"
  script_file="$RUN_DIR/${session}.sh"

  cat >"$script_file" <<EOF
#!/bin/bash
SRC_URL="$src_url"
RTMP_URL="$rtmp_url"
STREAM_KEY="$stream_key"
OFFLINE_LIMIT="$offline_sec"
LOG_FILE="$session_log"

echo "==== 手動轉播啟動 ====" >>"\$LOG_FILE"
echo "來源: \$SRC_URL"        >>"\$LOG_FILE"
echo "目標: \$RTMP_URL/\$STREAM_KEY" >>"\$LOG_FILE"
echo "最大離線: \$OFFLINE_LIMIT 秒" >>"\$LOG_FILE"

offline_acc=0

while :; do
  start_ts=\$(date +%s)
  ffmpeg -re -i "\$SRC_URL" \
    -c:v copy -c:a copy -f flv "\$RTMP_URL/\$STREAM_KEY" \
    >>"\$LOG_FILE" 2>&1
  exit_code=\$?
  end_ts=\$(date +%s)
  runtime=\$(( end_ts - start_ts ))

  if (( runtime >= 60 )); then
    # 播夠 60 秒算「正常直播」，重新計算累積離線時間
    offline_acc=0
  else
    offline_acc=\$(( offline_acc + runtime ))
  fi

  echo "[\$(date '+%F %T')] ffmpeg 退出 code=\$exit_code, 本輪運行 \$runtime 秒, 累積離線 \$offline_acc 秒" >>"\$LOG_FILE"

  if (( OFFLINE_LIMIT > 0 && offline_acc >= OFFLINE_LIMIT )); then
    echo "[\$(date '+%F %T')] 離線時間超過限制，結束本場轉播。" >>"\$LOG_FILE"
    break
  fi

  echo "[\$(date '+%F %T')] 30 秒後重試連線..." >>"\$LOG_FILE"
  sleep 30
done

echo "[\$(date '+%F %T')] 手動轉播腳本已結束。" >>"\$LOG_FILE"
EOF

  chmod +x "$script_file"

  echo
  echo -e "${C_MENU}即將以 screen 啟動推流會話：${session}${C_RESET}"
  echo -e "${C_MENU}日誌檔案：${session_log}${C_RESET}"
  echo
  screen -dmS "$session" bash "$script_file"

  echo -e "${C_OK:-$C_MENU}已啟動手動轉播。可以用『4. 推流進程管理』查看或結束。${C_RESET}"
  pause
}

restream_auto() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 1.2 自動轉播（YouTube API）${C_RESET}"
  echo

  if ! ensure_python; then
    return
  fi

  local src_url title offline_sec probe_interval
  src_url=$(read_nonempty "請輸入直播源地址（例如抖音 FLV URL）： ")
  title=$(read_nonempty   "請輸入 YouTube 直播標題： ")
  read -rp "最大允許斷線時間（秒，預設 300，超時視為本場結束）： " offline_sec
  offline_sec="${offline_sec:-300}"
  read -rp "探針檢查間隔（秒，預設 30）： " probe_interval
  probe_interval="${probe_interval:-30}"

  local session session_log ts
  session=$(next_screen_name "ms_auto")
  ts=$(date +%m%d_%H%M%S)
  session_log="$LOG_DIR/${session}_${ts}.log"

  echo
  echo -e "${C_MENU}即將以 screen 啟動自動轉播會話：${session}${C_RESET}"
  echo -e "${C_MENU}日誌檔案：${session_log}${C_RESET}"
  echo -e "${C_DIM}提示：需要 youtube_auth 目錄下的 client_secret.json / token.json${C_RESET}"
  echo

  screen -dmS "$session" bash -c "
    cd '$INSTALL_DIR'
    '$PYTHON_BIN' '$INSTALL_DIR/magic_autostream.py' \
      --source-url '$src_url' \
      --title '$title' \
      --offline-seconds '$offline_sec' \
      --probe-interval '$probe_interval' \
      --auth-dir '$AUTH_DIR' \
      >>'$session_log' 2>&1
  "

  echo -e "${C_MENU}自動轉播腳本已在後台運行。${C_RESET}"
  pause
}

#############################
# 2. 文件推流
#############################

menu_vod() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 2. 文件推流（播放本地 MP4 → Live）${C_RESET}"
  echo
  echo -e "請先把視頻放到：${C_MENU}${VOD_DIR}${C_RESET}"
  echo
  read -rp "輸入要直播的文件名（含副檔名，如 test.mp4）： " vod_file
  if [[ -z "$vod_file" ]]; then
    echo -e "${C_WARN}文件名不能為空。${C_RESET}"
    sleep 1
    return
  fi
  if [[ ! -f "$VOD_DIR/$vod_file" ]]; then
    echo -e "${C_ERR}找不到文件：$VOD_DIR/$vod_file${C_RESET}"
    pause
    return
  fi

  local rtmp_url stream_key
  read -rp "RTMP 前綴（預設：rtmp://a.rtmp.youtube.com/live2）： " rtmp_url
  rtmp_url="${rtmp_url:-rtmp://a.rtmp.youtube.com/live2}"
  stream_key=$(read_nonempty "請輸入 YouTube 直播碼（僅 key）： ")

  local session session_log script_file ts
  session=$(next_screen_name "ms_vod")
  ts=$(date +%m%d_%H%M%S)
  session_log="$LOG_DIR/${session}_${ts}.log"
  script_file="$RUN_DIR/${session}.sh"

  cat >"$script_file" <<EOF
#!/bin/bash
VOD_FILE="$VOD_DIR/$vod_file"
RTMP_URL="$rtmp_url"
STREAM_KEY="$stream_key"
LOG_FILE="$session_log"

echo "==== 文件推流啟動 ====" >>"\$LOG_FILE"
echo "文件: \$VOD_FILE" >>"\$LOG_FILE"
echo "目標: \$RTMP_URL/\$STREAM_KEY" >>"\$LOG_FILE"

ffmpeg -re -stream_loop -1 -i "\$VOD_FILE" \
  -c:v copy -c:a copy -f flv "\$RTMP_URL/\$STREAM_KEY" \
  >>"\$LOG_FILE" 2>&1

echo "[\$(date '+%F %T')] 文件推流已結束。" >>"\$LOG_FILE"
EOF

  chmod +x "$script_file"

  echo
  echo -e "${C_MENU}即將以 screen 啟動文件推流會話：${session}${C_RESET}"
  echo -e "${C_MENU}日誌檔案：${session_log}${C_RESET}"
  echo
  screen -dmS "$session" bash "$script_file"

  echo -e "${C_MENU}文件推流已啟動，可在『4. 推流進程管理』中查看。${C_RESET}"
  pause
}

#############################
# 3. 直播系統安裝
#############################

menu_install() {
  while :; do
    draw_header
    echo -e "${C_SUB}Magic Stream -> 3. 直播系統安裝${C_RESET}"
    echo
    echo -e "${C_MENU}1. 系統升級 & 更新 (apt update && apt upgrade)${C_RESET}"
    echo -e "${C_MENU}2. 安裝 / 修復 Python 環境（虛擬環境 + API 依賴）${C_RESET}"
    echo -e "${C_MENU}3. 安裝 ffmpeg & screen${C_RESET}"
    echo -e "${C_MENU}0. 返回主選單${C_RESET}"
    echo
    read -rp "請選擇： " ans
    case "$ans" in
      1)
        draw_header
        echo -e "${C_MENU}執行 apt update && apt upgrade -y ...${C_RESET}"
        apt update && apt upgrade -y
        pause
        ;;
      2)
        draw_header
        echo -e "${C_MENU}建立 / 修復 Python 虛擬環境：$PYTHON_BIN${C_RESET}"
        apt update
        apt install -y python3 python3-venv python3-pip
        if [[ ! -d "$INSTALL_DIR/venv" ]]; then
          python3 -m venv "$INSTALL_DIR/venv"
        fi
        "$PYTHON_BIN" -m pip install --upgrade pip
        "$PYTHON_BIN" -m pip install google-api-python-client google-auth google-auth-oauthlib google-auth-httplib2 requests
        echo -e "${C_MENU}Python 環境已就緒。${C_RESET}"
        pause
        ;;
      3)
        draw_header
        echo -e "${C_MENU}安裝 ffmpeg & screen ...${C_RESET}"
        apt update
        apt install -y ffmpeg screen
        echo -e "${C_MENU}ffmpeg / screen 安裝完成。${C_RESET}"
        pause
        ;;
      0) return ;;
      *) echo -e "${C_WARN}無效選項。${C_RESET}"; sleep 1 ;;
    esac
  done
}

#############################
# 4. 推流進程管理
#############################

menu_process() {
  while :; do
    draw_header
    echo -e "${C_SUB}Magic Stream -> 4. 推流進程管理${C_RESET}"
    echo
    echo -e "${C_MENU}1. 查看所有 screen 會話${C_RESET}"
    echo -e "${C_MENU}2. 查看 Magic Stream 推流狀態摘要${C_RESET}"
    echo -e "${C_MENU}3. 進入指定 screen 會話（查看推流詳情）${C_RESET}"
    echo -e "${C_MENU}4. 結束指定 screen 會話（等於結束該路直播）${C_RESET}"
    echo -e "${C_MENU}0. 返回主選單${C_RESET}"
    echo
    read -rp "請選擇： " ans
    case "$ans" in
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
  echo -e "${C_SUB}Magic Stream -> 4.1 所有 screen 會話${C_RESET}"
  echo
  screen -ls || true
  echo
  echo -e "${C_DIM}提示：Magic Stream 相關名稱一般為：ms_auto_xx / ms_manual_xx / ms_vod_xx${C_RESET}"
  pause
}

process_status() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 4.2 推流狀態摘要${CRESET}"
  echo

  local sessions
  sessions=$(screen -ls 2>/dev/null | grep -oE 'ms_(auto|manual|vod)_[0-9]+' || true)

  if [[ -z "$sessions" ]]; then
    echo -e "${C_WARN}當前沒有 Magic Stream 推流 screen 會話。${C_RESET}"
    pause
    return
  fi

  local idx=1
  for s in $sessions; do
    local latest_log
    latest_log=$(ls -1t "$LOG_DIR"/"${s}"_*.log 2>/dev/null | head -n1 || true)
    echo -e "[${idx}] 會話：${C_MENU}${s}${C_RESET}"
    if [[ -n "$latest_log" ]]; then
      local last_line
      last_line=$(tail -n1 "$latest_log")
      echo -e "     日誌：${latest_log}"
      echo -e "     最近：${C_DIM}${last_line}${C_RESET}"
    else
      echo -e "     尚未生成日誌。"
    fi
    echo
    idx=$((idx+1))
  done
  pause
}

process_attach() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 4.3 進入指定 screen 會話${C_RESET}"
  echo
  screen -ls || true
  echo
  read -rp "輸入要進入的 screen 名稱（如 ms_auto_01）： " name
  if [[ -z "$name" ]]; then
    echo -e "${C_WARN}名稱不能為空。${C_RESET}"
    sleep 1
    return
  fi
  echo -e "${C_MENU}提示：退出 screen 請用快捷鍵：Ctrl+A 然後再按 D（detach）。${C_RESET}"
  sleep 2
  screen -r "$name" || { echo -e "${C_ERR}無法附著到 screen：$name${C_RESET}"; sleep 2; }
}

process_kill() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 4.4 結束指定 screen 會話${C_RESET}"
  echo
  screen -ls || true
  echo
  read -rp "輸入要結束的 screen 名稱（如 ms_auto_01）： " name
  if [[ -z "$name" ]]; then
    echo -e "${C_WARN}名稱不能為空。${C_RESET}"
    sleep 1
    return
  fi
  read -rp "確認要結束 '${name}' ? (y/N): " yes
  if [[ "$yes" =~ ^[Yy]$ ]]; then
    screen -S "$name" -X quit || true
    echo -e "${C_MENU}已發送結束指令。${C_RESET}"
  else
    echo -e "${C_DIM}已取消。${C_RESET}"
  fi
  pause
}

#############################
# 5. 更新腳本
#############################

update_script() {
  draw_header
  echo -e "${C_SUB}Magic Stream -> 5. 從 GitHub 拉取最新版腳本${C_RESET}"
  echo
  echo -e "${C_MENU}從：${RAW_BASE}${C_RESET}"
  echo

  read -rp "確認更新 magic_stream.sh & magic_autostream.py ? (y/N): " yes
  if [[ ! "$yes" =~ ^[Yy]$ ]]; then
    echo -e "${C_DIM}已取消更新。${C_RESET}"
    sleep 1
    return
  fi

  curl -fsSL "$RAW_BASE/magic_stream.sh" -o "$INSTALL_DIR/magic_stream.sh"
  curl -fsSL "$RAW_BASE/magic_autostream.py" -o "$INSTALL_DIR/magic_autostream.py"
  chmod +x "$INSTALL_DIR/magic_stream.sh"
  echo -e "${C_MENU}腳本已更新到最新版本（若你剛才推的是 0.6.0，記得也更新倉庫）。${C_RESET}"
  pause
}

#############################
#  主選單
#############################

main_menu() {
  while :; do
    draw_header
    echo -e "${C_SUB}主選單${C_RESET}"
    echo
    echo -e "${C_MENU}1. 轉播推流  （含：手動 RTMP / 自動 YouTube API）${C_RESET}"
    echo -e "${C_MENU}2. 文件推流  （點播文件 → 直播）${C_RESET}"
    echo -e "${C_MENU}3. 直播系統安裝${C_RESET}"
    echo -e "${C_MENU}4. 推流進程管理${C_RESET}"
    echo -e "${C_MENU}5. 更新腳本（從 GitHub 拉取最新版）${C_RESET}"
    echo -e "${C_MENU}0. 退出腳本${C_RESET}"
    echo
    read -rp "請選擇： " ans
    case "$ans" in
      1) menu_restream ;;
      2) menu_vod ;;
      3) menu_install ;;
      4) menu_process ;;
      5) update_script ;;
      0)
        echo
        echo -e "${C_DIM}Bye~${C_RESET}"
        exit 0
        ;;
      *)
        echo -e "${C_WARN}無效選項。${C_RESET}"
        sleep 1
        ;;
    esac
  done
}

main_menu
