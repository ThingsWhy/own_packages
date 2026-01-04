#!/bin/sh

# 参数: url [version] [binpath] [upxflag]
DOWNLOAD_URL="$1"
VERSION="$2"
BIN_PATH="$3"
UPX_FLAG="$4"

[ -z "$BIN_PATH" ] && BIN_PATH="/usr/bin/AdGuardHome/AdGuardHome"
TMP_DIR="/tmp/agh_update"
LOG_FILE="/tmp/AdGuardHome_update.log"

log() {
	echo "[$(date '+%H:%M:%S')] $1"
	echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Starting update..."
mkdir -p "$TMP_DIR"

# 1. 确定下载地址 (如果未提供，尝试自动探测 - Boot Fallback)
if [ -z "$DOWNLOAD_URL" ]; then
    log "No URL provided, auto-detecting..."
    # 简化的自动探测，仅用于 init.d 自动修复
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) AGH_ARCH="amd64" ;;
        aarch64) AGH_ARCH="arm64" ;;
        armv7*) AGH_ARCH="armv7" ;;
        *) AGH_ARCH="$ARCH" ;;
    esac
    DOWNLOAD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${AGH_ARCH}.tar.gz"
fi

# 2. 下载
TARGET_FILE="$TMP_DIR/agh.tar.gz"
log "Downloading from: $DOWNLOAD_URL"

if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q --no-check-certificate -O "$TARGET_FILE" "$DOWNLOAD_URL" >> "$LOG_FILE" 2>&1
elif command -v wget >/dev/null 2>&1; then
    wget -q --no-check-certificate -O "$TARGET_FILE" "$DOWNLOAD_URL" >> "$LOG_FILE" 2>&1
else
    log "Error: No downloader found (uclient-fetch or wget required)."
    exit 1
fi

if [ ! -s "$TARGET_FILE" ]; then
    log "Error: Download failed or file empty."
    exit 1
fi

# 3. 解压
log "Extracting..."
tar -xzf "$TARGET_FILE" -C "$TMP_DIR" >> "$LOG_FILE" 2>&1
NEW_BIN=$(find "$TMP_DIR" -name AdGuardHome -type f | head -n 1)

if [ ! -f "$NEW_BIN" ]; then
    log "Error: Binary not found in archive."
    exit 1
fi

chmod +x "$NEW_BIN"

# 4. UPX 压缩 (可选)
if [ -n "$UPX_FLAG" ]; then
    if command -v upx >/dev/null 2>&1; then
        log "Applying UPX compression ($UPX_FLAG)..."
        upx $UPX_FLAG "$NEW_BIN" >> "$LOG_FILE" 2>&1
    else
        log "Warning: UPX requested but not found. Skipping."
    fi
fi

# 5. 替换与重启
log "Replacing binary..."
# 停止服务以释放文件句柄
/etc/init.d/AdGuardHome stop >/dev/null 2>&1

mv "$NEW_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

log "Restarting service..."
/etc/init.d/AdGuardHome start >/dev/null 2>&1

log "Update completed successfully."
exit 0