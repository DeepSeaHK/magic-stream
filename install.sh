#!/bin/bash
set -e

########################################
# Magic Stream 商業部署腳本 v1.6 (Auto-Fix)
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"
INSTALL_DIR="$HOME/magic_stream"
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"

echo "== Magic Stream 商業版安裝程序 v1.6 =="
echo "安裝目錄: $INSTALL_DIR"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 1. 基礎環境
if [ -z "$INSTALL_DIR" ]; then INSTALL_DIR="$HOME/magic_stream"; fi

echo "[1/6] 建立目錄結構..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/vod"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/youtube_auth"
cd "$INSTALL_DIR"

echo "[2/6] 安裝系統依賴..."
if command -v apt >/dev/null 2>&1; then
    $SUDO apt update -qq || true
    $SUDO apt install -y -qq curl ffmpeg python3 python3-pip python3-venv screen git unzip
else
    echo "非 Debian/Ubuntu 系統，請手動安裝依賴 (含 unzip)。"
fi

# 2. 下載核心組件
TS=$(date +%s)
echo "[3/6] 下載核心武器..."
curl -fsSL "$RAW_BASE/magic_stream.sh?t=$TS" -o magic_stream.sh
curl -fsSL "$RAW_BASE/magic_autostream.py?t=$TS" -o magic_autostream.py

echo "正在部署全平台運行庫..."
# === v1.6 核心修復：防止目錄嵌套 ===
# 先清理舊的運行庫文件夾 (防止衝突)
rm -rf pyarmor_runtime_000000
# 下載 zip
curl -fsSL "$RAW_BASE/runtime.zip?t=$TS" -o runtime.zip
# 直接解壓到當前目錄 (會自動生成 pyarmor_runtime_000000 文件夾)
unzip -o -q runtime.zip
rm runtime.zip
# ==================================

chmod +x magic_stream.sh magic_autostream.py

# 3. Python 環境
echo "[4/6] 配置 Python 環境..."
VENV_DIR="$INSTALL_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi

# 4. 依賴庫
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install --upgrade google-api-python-client google-auth-oauthlib google-auth-httplib2 requests -q

# 5. 快捷指令
echo "[5/6] 註冊全局命令 'ms'..."
echo "#!/bin/bash" | $SUDO tee "$BIN_PATH" >/dev/null
echo "cd \"$INSTALL_DIR\"" | $SUDO tee -a "$BIN_PATH" >/dev/null
echo "exec \"$INSTALL_DIR/magic_stream.sh\" \"\$@\"" | $SUDO tee -a "$BIN_PATH" >/dev/null
$SUDO chmod +x "$BIN_PATH"

# 6. 說明文件
echo "[6/6] 生成說明文檔..."
echo "請將 client_secret.json 和 token.json 上傳至此目錄以啟用自動 API 功能。" > "$INSTALL_DIR/youtube_auth/README.txt"

echo
echo "========================================"
echo -e "\033[32m 安裝完成！請使用授權碼激活。 \033[0m"
echo "========================================"
echo " 1. 輸入 'ms' 啟動菜單"
echo " 2. 選擇 '5. 功能授權' 獲取機器碼"
echo " 3. 聯繫管理員開通白名單"
echo "========================================"
