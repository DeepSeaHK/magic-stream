#!/bin/bash
set -e

########################################
# 已幫你改成自己的 GitHub 倉庫：
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 安裝目錄（預設：當前用戶的 home）
INSTALL_DIR="$HOME/magic_stream"

# 之後在終端輸入的命令名
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"
########################################

echo "== Magic Stream 安裝器 =="
echo "安裝目錄: $INSTALL_DIR"
echo "命令名稱: $BIN_CMD_NAME"
echo

# 判斷是否使用 sudo
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# 建目錄
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/vod" "$INSTALL_DIR/logs" "$INSTALL_DIR/youtube_auth"

cd "$INSTALL_DIR"

# 確保有 curl
if ! command -v curl >/dev/null 2>&1; then
  echo "未找到 curl，正在安裝..."
  if command -v apt >/dev/null 2>&1; then
    # 加上 || true 防止 apt update 報錯導致腳本退出
    $SUDO apt update || true
    $SUDO apt install -y curl
  else
    echo "系統沒有 apt，請手動安裝 curl 後重試。"
    exit 1
  fi
fi

echo "下載主菜單腳本 magic_stream.sh..."
curl -fsSL "$RAW_BASE/magic_stream.sh" -o magic_stream.sh

echo "下載自動推流腳本 magic_autostream.py..."
curl -fsSL "$RAW_BASE/magic_autostream.py" -o magic_autostream.py

chmod +x magic_stream.sh
chmod +x magic_autostream.py

echo
echo "安裝系統依賴 (ffmpeg, python3, pip, screen)..."
if command -v apt >/dev/null 2>&1; then
  $SUDO apt update || true
  $SUDO apt install -y ffmpeg python3 python3-pip python3-venv screen
else
  echo "非 Debian/Ubuntu 系統，請自行安裝 ffmpeg / python3 / pip / screen / python3-venv。"
fi

# ===== 建立專用 venv 並安裝 YouTube API 依賴 =====
VENV_DIR="$INSTALL_DIR/venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

echo
echo "建立 Python 虛擬環境（venv）並安裝 YouTube API 套件..."

if command -v python3 >/dev/null 2>&1; then
  if [ ! -x "$VENV_PYTHON" ]; then
    echo "建立虛擬環境: $VENV_DIR"
    python3 -m venv "$VENV_DIR" || echo "建立 venv 失敗，稍後可在菜單裡再次安裝。"
  else
    echo "已存在 venv：$VENV_DIR"
  fi

  if [ -x "$VENV_PIP" ]; then
    "$VENV_PIP" install --upgrade pip
    "$VENV_PIP" install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib || \
      echo "安裝 YouTube API 依賴失敗，可稍後從菜單『3-4 安裝 YouTube API 依賴』重試。"
  else
    echo "未找到 venv 的 pip，請稍後在菜單中重新安裝依賴。"
  fi
else
  echo "未找到 python3，請稍後在菜單中先安裝 Python 環境。"
fi

# 提示放置憑證的說明（已更新為新策略說明）
cat > "$INSTALL_DIR/youtube_auth/README.txt" <<EOF
【重要說明】
由於 Google 安全策略限制，無法在 VPS 上直接生成 Token。

請按照以下步驟操作：
1. 在你的「本地電腦」(Windows/Mac) 上運行一次腳本進行授權。
2. 生成 client_secret.json 和 token.json。
3. 將這兩個文件上傳到本目錄：
   $INSTALL_DIR/youtube_auth

文件清單必須包含：
  client_secret.json
  token.json
EOF

echo
echo "建立快捷命令：$BIN_CMD_NAME"

# 如果已有同名命令，提醒一下
if command -v "$BIN_CMD_NAME" >/dev/null 2>&1; then
  echo "注意：系統中已存在命令 '$BIN_CMD_NAME'，將被 Magic Stream 覆蓋。"
fi

# 在 /usr/local/bin 下建立啟動腳本
$SUDO tee "$BIN_PATH" >/dev/null <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
exec "$INSTALL_DIR/magic_stream.sh" "\$@"
EOF

$SUDO chmod +x "$BIN_PATH"

echo
echo "========================================"
echo -e "\033[32m Magic Stream 安裝完成！ \033[0m"
echo "========================================"
echo
echo " 安裝路徑：$INSTALL_DIR"
echo " 快捷指令：$BIN_CMD_NAME"
echo
echo "【關鍵下一步】"
echo " 1. 請在本地電腦生成 token.json"
echo " 2. 請將 client_secret.json 和 token.json 上傳到："
echo -e "    \033[33m$INSTALL_DIR/youtube_auth\033[0m"
echo
echo " 完成上傳後，在終端輸入 '$BIN_CMD_NAME' 即可使用。"
echo "========================================"
