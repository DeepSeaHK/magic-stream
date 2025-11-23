#!/bin/bash
set -e

########################################
# 這行已幫你改成自己的 GitHub 倉庫：
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 安裝目錄（預設：當前用戶的 home）
INSTALL_DIR="$HOME/magic_stream"

# 你想用的命令名：以後在終端輸入這個單詞
BIN_CMD_NAME="mc"
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
    $SUDO apt update
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
  $SUDO apt update
  $SUDO apt install -y ffmpeg python3 python3-pip screen
else
  echo "非 Debian/Ubuntu 系統，請自行安裝 ffmpeg / python3 / pip / screen。"
fi

echo
echo "安裝 YouTube API 相關 Python 套件..."
pip3 install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib

# 提示放置憑證的說明
if [ ! -f "$INSTALL_DIR/youtube_auth/README.txt" ]; then
  cat > "$INSTALL_DIR/youtube_auth/README.txt" <<EOF
請將 YouTube 的 OAuth 憑證放在本目錄下：
  $INSTALL_DIR/youtube_auth

文件名必須是：
  client_secret.json
  token.json
EOF
fi

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
echo " Magic Stream 安裝完成！"
echo
echo " 目錄：$INSTALL_DIR"
echo " 快捷命令：$BIN_CMD_NAME"
echo
echo " 下一步："
echo "   1) 把 YouTube 的 client_secret.json 和 token.json 放到："
echo "        $INSTALL_DIR/youtube_auth"
echo "   2) 之後只要在終端輸入："
echo "        $BIN_CMD_NAME"
echo "      就能呼出 Magic Stream 菜單。"
echo "========================================"
