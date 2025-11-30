#!/bin/bash
set -e

########################################
# Magic Stream 一鍵部署腳本 v1.0 (Final)
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"
INSTALL_DIR="$HOME/magic_stream"
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"

echo "== Magic Stream 帝國部署系統啟動 =="
echo "目標目錄: $INSTALL_DIR"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 1. 基礎環境準備
echo "[1/5] 準備目錄與依賴..."
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/vod" "$INSTALL_DIR/logs" "$INSTALL_DIR/youtube_auth"
cd "$INSTALL_DIR"

if command -v apt >/dev/null 2>&1; then
    $SUDO apt update -qq || true
    $SUDO apt install -y -qq curl ffmpeg python3 python3-pip python3-venv screen git
else
    echo "非 Debian/Ubuntu 系統，請確認已安裝 curl/ffmpeg/python3/screen。"
fi

# 2. 下載核心武器
echo "[2/5] 下載核心腳本..."
# 加时间戳防止缓存
TS=$(date +%s)
curl -fsSL "$RAW_BASE/magic_stream.sh?t=$TS" -o magic_stream.sh
curl -fsSL "$RAW_BASE/magic_autostream.py?t=$TS" -o magic_autostream.py

chmod +x magic_stream.sh magic_autostream.py

# 3. 構建 Python 虛擬環境 (核反應堆)
echo "[3/5] 部署 Python 運行環境..."
VENV_DIR="$INSTALL_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

# 4. 強制安裝 Python 依賴庫
echo "[4/5] 安裝 API 依賴庫..."
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install --upgrade google-api-python-client google-auth-oauthlib google-auth-httplib2 requests -q

# 5. 建立快捷指令
echo "[5/5] 註冊全局命令 'ms'..."
$SUDO tee "$BIN_PATH" >/dev/null <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
exec "$INSTALL_DIR/magic_stream.sh" "\$@"
EOF
$SUDO chmod +x "$BIN_PATH"

# 6. 生成說明書
cat > "$INSTALL_DIR/youtube_auth/README.txt" <<EOF
請將 client_secret.json 和 token.json 上傳至此目錄以啟用自動 API 功能。
EOF

echo
echo "========================================"
echo -e "\033[32m 部署完成！帝國節點已就緒。 \033[0m"
echo "========================================"
echo " 請直接輸入 'ms' 啟動控制台。"
echo "========================================"