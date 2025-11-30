#!/bin/bash
set -e

########################################
# Magic Stream 商業部署腳本 v1.2 (Commercial)
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"
INSTALL_DIR="$HOME/magic_stream"
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"

echo "== Magic Stream 商業版安裝程序 =="
echo "安裝目錄: $INSTALL_DIR"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 1. 基礎環境
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/vod" "$INSTALL_DIR/logs" "$INSTALL_DIR/youtube_auth"
cd "$INSTALL_DIR"

if command -v apt >/dev/null 2>&1; then
    $SUDO apt update -qq || true
    $SUDO apt install -y -qq curl ffmpeg python3 python3-pip python3-venv screen git
else
    echo "非 Debian/Ubuntu 系統，請手動安裝 curl/ffmpeg/python3/screen。"
fi

# 2. 下載核心組件 (帶時間戳防緩存)
TS=$(date +%s)
echo "正在下載核心組件..."
curl -fsSL "$RAW_BASE/magic_stream.sh?t=$TS" -o magic_stream.sh
curl -fsSL "$RAW_BASE/magic_autostream.py?t=$TS" -o magic_autostream.py

# === 🔴 商業版關鍵：下載加密運行庫 ===
RUNTIME_DIR="pyarmor_runtime_000000"
mkdir -p "$RUNTIME_DIR"
echo "正在下載運行環境庫..."
# 下載 __init__.py
curl -fsSL "$RAW_BASE/$RUNTIME_DIR/__init__.py?t=$TS" -o "$RUNTIME_DIR/__init__.py"
# 下載核心 .so 文件 (Linux 專用)
curl -fsSL "$RAW_BASE/$RUNTIME_DIR/pyarmor_runtime.so?t=$TS" -o "$RUNTIME_DIR/pyarmor_runtime.so"
# ======================================

chmod +x magic_stream.sh magic_autostream.py

# 3. Python 環境
echo "配置 Python 環境..."
VENV_DIR="$INSTALL_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi

# 4. 依賴庫
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install --upgrade google-api-python-client google-auth-oauthlib google-auth-httplib2 requests -q

# 5. 快捷指令
$SUDO tee "$BIN_PATH" >/dev/null <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
exec "$INSTALL_DIR/magic_stream.sh" "\$@"
EOF
$SUDO chmod +x "$BIN_PATH"

# 6. 說明文件
cat > "$INSTALL_DIR/youtube_auth/README.txt" <<EOF
請將 client_secret.json 和 token.json 上傳至此目錄以啟用自動 API 功能。
EOF

echo
echo "========================================"
echo -e "\033[32m 安裝完成！請使用授權碼激活。 \033[0m"
echo "========================================"
echo " 1. 輸入 'ms' 啟動菜單"
echo " 2. 選擇 '5. 功能授權' 獲取機器碼"
echo " 3. 聯繫管理員開通白名單"
echo "========================================"