#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
set -e

# 清理函数
cleanup_exit() {
    local exit_code=${1:-1}
    rm -f /var/run/update_core
    if [ "$exit_code" -ne 0 ]; then
         touch /var/run/update_core_error
    else
         rm -f /var/run/update_core_error
    fi
    [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
    exit "$exit_code"
}
trap 'cleanup_exit 1' INT TERM HUP

# 全局变量
binpath=""
upxflag=""
downloader=""
latest_ver=""
now_ver=""
Arch=""
tmp_dir=$(mktemp -d)

log_update() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - update_core.sh: $1"
}

check_downloader() {
    # 既然确认有 curl，直接使用 curl
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL --retry 2 --connect-timeout 20 -o"
        log_update "Using curl."
    else
        # 即使只有 libcurl 没有 curl 二进制，这里也是个保险
        if command -v wget >/dev/null 2>&1; then
             downloader="wget -t 2 -T 20 -qO"
             log_update "Using wget (curl not found)."
        else
             log_update "Error: curl or wget not found."
             cleanup_exit 1
        fi
    fi
}

get_architecture() {
    local arch_raw
    if command -v uname >/dev/null 2>&1; then
        arch_raw=$(uname -m)
    else
        arch_raw=$(opkg info kernel | grep Architecture | awk '{print $2}')
    fi

    case "$arch_raw" in
        i386|i686) Arch="386" ;;
        x86_64|amd64) Arch="amd64" ;;
        mips*|mipsel*) Arch="mipsle" ;; 
        armv5*|armv6*|armv7*) Arch="arm" ;;
        aarch64|arm64) Arch="arm64" ;;
        *) log_update "Unknown architecture: $arch_raw"; return 1 ;;
    esac
    log_update "Detected Architecture: $Arch"
}

doupdate_core() {
    local links_file="/usr/share/AdGuardHome/links.txt"
    [ ! -f "$links_file" ] && cleanup_exit 1

    local download_ok=0
    local target_file=""
    
    while read -r link; do
        case "$link" in
            \#*|"") continue ;;
        esac
        
        link=$(echo "$link" | sed "s/\${latest_ver}/${latest_ver}/g; s/\${Arch}/${Arch}/g")
        local filename="${link##*/}"
        target_file="${tmp_dir}/${filename}"
        
        log_update "Downloading $link ..."
        if eval "$downloader" "\"$target_file\"" "\"$link\""; then
            log_update "Download success."
            
            if echo "$filename" | grep -q ".tar.gz$"; then
                tar -zxf "$target_file" -C "$tmp_dir"
                local bin_found=$(find "$tmp_dir" -name AdGuardHome -type f | head -n1)
                if [ -n "$bin_found" ]; then
                    mv "$bin_found" "$binpath"
                    chmod +x "$binpath"
                    download_ok=1
                    break
                fi
            else
                mv "$target_file" "$binpath"
                chmod +x "$binpath"
                download_ok=1
                break
            fi
        fi
    done < "$links_file"

    if [ "$download_ok" -eq 1 ] && [ -x "$binpath" ]; then
        if "$binpath" --check-config -c /dev/null >/dev/null 2>&1; then
             log_update "Update finished successfully."
             /etc/init.d/AdGuardHome restart
             cleanup_exit 0
        else
             log_update "Downloaded binary seems invalid."
             cleanup_exit 1
        fi
    else
        log_update "All downloads failed."
        cleanup_exit 1
    fi
}

check_latest_version() {
    local force_update="$1"
    local api_url="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
    local json_output
    
    json_output=$(eval "$downloader" - "$api_url" 2>/dev/null)
    
    if [ -z "$json_output" ]; then
        log_update "Failed to check latest version."
        cleanup_exit 1
    fi

    latest_ver=$(echo "$json_output" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"v\([^"]*\)".*/v\1/')
    
    if [ -z "$latest_ver" ]; then
        log_update "Failed to parse version."
        cleanup_exit 1
    fi
    log_update "Latest version: $latest_ver"

    if [ -x "$binpath" ]; then
        now_ver=$("$binpath" --version 2>&1 | grep -o "v[0-9.]*" | head -n1)
        [ -z "$now_ver" ] && now_ver="unknown"
        log_update "Current version: $now_ver"
    else
        now_ver="none"
        log_update "No local binary found."
        force_update="force"
    fi

    if [ "$force_update" = "force" ] || [ "$latest_ver" != "$now_ver" ]; then
        log_update "Update required."
        doupdate_core
    else
        log_update "Up to date."
        cleanup_exit 0
    fi
}

main() {
    touch /var/run/update_core
    
    local config_binpath
    config_binpath=$(uci -q get AdGuardHome.AdGuardHome.binpath)
    binpath=${config_binpath:-"/usr/bin/AdGuardHome/AdGuardHome"}
    
    mkdir -p "$(dirname "$binpath")"
    
    check_downloader
    get_architecture
    check_latest_version "$1"
}

main "$@"