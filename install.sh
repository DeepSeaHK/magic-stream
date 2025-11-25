#!/bin/bash
set -e

########################################
# GitHub 倉庫配置
########################################
RAW_BASE="https://raw.githubusercontent.com/DeepSeaHK/magic-stream/main"

# 安裝目錄
INSTALL_DIR="$HOME/magic_stream"

# 命令名稱
BIN_CMD_NAME="ms"
BIN_PATH="/usr/local/bin/$BIN_CMD_NAME"
########################################

echo "== Magic Stream 安裝器 (v0.7.3) =="
echo "安裝目錄: $INSTALL_DIR"
echo "命令名稱: $BIN_CMD_NAME"
echo

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/vod" "$INSTALL_DIR/logs" "$INSTALL_DIR/youtube_auth"

cd "$INSTALL_DIR"

# 1. 確保有 curl
if ! command -v curl >/dev/null 2>&1; then
  echo "未找到 curl，正在安裝..."
  if command -v apt >/dev/null 2>&1; then
    $SUDO apt update || true
    $SUDO apt install -y curl
  else
    echo "系統沒有 apt，請手動安裝 curl 後重試。"
    exit 1
  fi
fi

# 2. 下載腳本
echo "下載核心腳本..."
curl -fsSL "$RAW_BASE/magic_stream.sh" -o magic_stream.sh
curl -fsSL "$RAW_BASE/magic_autostream.py" -o magic_autostream.py

# 🔴 新增：手动下载 PyArmor 运行库文件
# 注意：必须确保你在 GitHub 上上传了 pyarmor_runtime_000000 文件夹
RUNTIME_DIR="pyarmor_runtime_000000"
mkdir -p "$RUNTIME_DIR"
echo "下載運行庫..."
curl -fsSL "$RAW_BASE/$RUNTIME_DIR/__init__.py" -o "$RUNTIME_DIR/__init__.py"
curl -fsSL "$RAW_BASE/$RUNTIME_DIR/pyarmor_runtime.so" -o "$RUNTIME_DIR/pyarmor_runtime.so"

chmod +x magic_stream.sh
chmod +x magic_autostream.py

# 3. 安裝系統級依賴
echo
echo "安裝系統依賴 (ffmpeg, python3, pip, screen)..."
if command -v apt >/dev/null 2>&1; then
  $SUDO apt update || true
  $SUDO apt install -y ffmpeg python3 python3-pip python3-venv screen
else
  echo "非 Debian/Ubuntu 系統，請確保已安裝 ffmpeg / python3 / pip / screen。"
fi

# 4. 建立 venv 並安裝 Python 依賴
VENV_DIR="$INSTALL_DIR/venv"
VENV_PIP="$VENV_DIR/bin/pip"

echo
echo "設定 Python 虛擬環境..."

if command -v python3 >/dev/null 2>&1; then
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    python3 -m venv "$VENV_DIR" || echo "建立 venv 失敗。"
  fi

  if [ -x "$VENV_PIP" ]; then
    echo "正在安裝 Python 庫 (含 requests)..."
    "$VENV_PIP" install --upgrade pip
    # 🔴 关键修改：在这里加入了 requests
    "$VENV_PIP" install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib requests
  else
    echo "未找到 pip，請稍後手動修復。"
  fi
else
  echo "未找到 python3。"
fi

# 5. 生成說明文件
cat > "$INSTALL_DIR/youtube_auth/README.txt" <<EOF
【重要說明】
由於 Google 安全策略限制，無法在 VPS 上直接生成 Token。

請按照以下步驟操作：
1. 在你的「本地電腦」(Windows/Mac) 上運行一次腳本進行授權。
2. 生成 client_secret.json 和 token.json。
3. 將這兩個文件上傳到本目錄：
   $INSTALL_DIR/youtube_auth
EOF

# 6. 建立快捷指令
echo
echo "建立快捷命令：$BIN_CMD_NAME"
if command -v "$BIN_CMD_NAME" >/dev/null 2>&1; then
  echo "注意：覆蓋已存在的命令。"
fi

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
echo " 輸入 '$BIN_CMD_NAME' 即可啟動菜單。"
echo "========================================"
