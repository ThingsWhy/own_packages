#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# 启用错误退出
set -e
# 清理陷阱
trap 'cleanup_exit 1' SIGINT SIGTERM SIGHUP

# --- 全局变量 ---
configpath=""
gfwupstream=""
downloader=""
tmp_gfwlist=""
tmp_adglist=""
tmp_sedscript=""

# --- 函数 ---

log_gfw() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - gfw2adg.sh: $1" >> /tmp/AdGuardHome_init.log
}

cleanup_exit() {
    local exit_code=${1:-1}
    log_gfw "Exiting (code: $exit_code)..."
    rm -f "$tmp_gfwlist" "$tmp_adglist" "$tmp_sedscript" 2>/dev/null || true
    exit "$exit_code"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || { log_gfw "Error: command '$1' not found."; cleanup_exit 1; }
}

check_downloader() {
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL --retry 2 --connect-timeout 20 -o"
        log_gfw "Using curl."
        return 0
    elif command -v wget-ssl >/dev/null 2>&1; then
        downloader="wget-ssl --no-check-certificate -t 2 -T 20 -qO"
        log_gfw "Using wget-ssl."
        return 0
     elif command -v wget >/dev/null 2>&1; then
         downloader="wget --no-check-certificate -t 2 -T 20 -qO"
         log_gfw "Using wget."
         return 0
    else
        log_gfw "Error: No suitable downloader (curl, wget-ssl, wget) found."
        return 1
    fi
}

checkmd5() {
    local target_list="$1" # Pass the file containing the new list
    local noreload_flag="$2"
    local new_md5 old_md5

    if [ ! -f "$target_list" ]; then
       log_gfw "Warning: md5 check target '$target_list' not found."
       return 1
    fi

    # Calculate new md5
    new_md5=$(md5sum "$target_list" | awk '{print $1}')

    # Get old md5 from UCI
    old_md5=$(uci -q get AdGuardHome.AdGuardHome.gfwlistmd5)

    if [ "$new_md5" != "$old_md5" ]; then
        log_gfw "GFW list changed (MD5: $new_md5). Updating UCI and reloading AdGuardHome."
        uci set AdGuardHome.AdGuardHome.gfwlistmd5="$new_md5"
        uci commit AdGuardHome
        if [ "$noreload_flag" = "noreload" ]; then
             log_gfw "Reload skipped due to 'noreload' flag."
        else
            log_gfw "Reloading AdGuardHome..."
             if ! /etc/init.d/AdGuardHome reload; then log_gfw "Error reloading AdGuardHome."; fi
        fi
    else
        log_gfw "GFW list unchanged (MD5: $new_md5). No reload needed."
    fi
}

# --- 主逻辑 ---

# 获取配置
configpath=$(uci -q get AdGuardHome.AdGuardHome.configpath)
gfwupstream=$(uci -q get AdGuardHome.AdGuardHome.gfwupstream) || gfwupstream="tcp://208.67.220.220:5353" # Default

if [ -z "$configpath" ]; then
    log_gfw "Error: configpath not set in UCI."
    cleanup_exit 1
fi

# 处理删除操作
if [ "$1" = "del" ]; then
    if [ ! -f "$configpath" ]; then
         log_gfw "Config file '$configpath' not found. Nothing to delete."
         cleanup_exit 0 # Exit normally if nothing to do
    fi
    log_gfw "Deleting GFW list entries from '$configpath'..."
    # 使用 sed 删除标记之间的行
    if sed -i '/#programaddstart_gfw/,/#programaddend_gfw/d' "$configpath"; then
        log_gfw "GFW list entries removed."
        # Update md5 in UCI to empty or a special value to indicate removal? Let's clear it.
        uci delete AdGuardHome.AdGuardHome.gfwlistmd5 2>/dev/null || true
        uci commit AdGuardHome
        # Trigger reload? Yes, if rules were removed.
        if [ "$2" != "noreload" ]; then
            log_gfw "Reloading AdGuardHome after deleting GFW list..."
            if ! /etc/init.d/AdGuardHome reload; then log_gfw "Error reloading AdGuardHome."; fi
        fi
        cleanup_exit 0
    else
         log_gfw "Error running sed to delete entries."
         cleanup_exit 1
    fi
fi

# 检查配置文件是否存在
if [ ! -f "$configpath" ]; then
    log_gfw "Error: Config file '$configpath' not found. Please create a config first."
    cleanup_exit 1
fi

# 创建临时文件
tmp_gfwlist=$(mktemp) || { log_gfw "Error creating temp file for gfwlist."; cleanup_exit 1; }
tmp_adglist=$(mktemp) || { log_gfw "Error creating temp file for adglist."; cleanup_exit 1; }
tmp_sedscript=$(mktemp) || { log_gfw "Error creating temp file for sed script."; cleanup_exit 1; }

# 下载 GFWList
log_gfw "Downloading GFWList..."
if ! check_downloader; then cleanup_exit 1; fi
local gfwlist_url="https://cdn.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt" # Or use alternative URLs
if ! eval "$downloader" - "$gfwlist_url" | base64 -d > "$tmp_gfwlist"; then
    log_gfw "Error: Failed to download or decode GFWList from $gfwlist_url."
    cleanup_exit 1
fi
log_gfw "GFWList downloaded successfully."

# 处理 GFWList 并生成 AdGuardHome 格式
log_gfw "Processing GFWList for AdGuardHome..."
# 添加更详细的注释到 awk 脚本
if ! awk -v upst="$gfwupstream" '
# awk script to convert gfwlist to AdGuardHome upstream rules
BEGIN {
    # Skip the first line (comment)
    getline;
    print "  #programaddstart_gfw"; # Add start marker
    print "  # Auto-generated rules by gfw2adg.sh";
}
{
    # Ignore comments in gfwlist
    if (substr($0, 1, 1) == "!") next;

    # Default: domain is in GFW list (needs proxy/specific upstream)
    is_whitelist = 0;

    # Handle @@ whitelist identifier
    if (substr($0, 1, 2) == "@@") {
        $0 = substr($0, 3);
        is_whitelist = 1;
    }

    # Remove protocol prefix (e.g., ||, |http://)
    if (substr($0, 1, 2) == "||") {
        $0 = substr($0, 3);
    } else if (substr($0, 1, 1) == "|") {
        $0 = substr($0, 2);
    }
    # Remove path part after /
    split($0, domain_parts, "/");
    $0 = domain_parts[1];

    # Remove leading * or . if present
    sub(/^\*+/, "", $0);
    sub(/^\.+/, "", $0);

    # Skip if domain is empty, contains invalid chars, or is an IP address
    if ($0 == "" || index($0, "%") || index($0, ":")) next;
    if ($0 ~ /^[0-9.]+$/) next; # Skip pure IP addresses

    # Basic check for a valid domain part
    if (index($0, ".") == 0) next;

    # Deduplication (awk handles this implicitly with the finl check)
    if ($0 == finl) next;
    finl = $0; # Remember last processed domain

    # Format for AdGuardHome YAML
    # Whitelist entries map to '#' (ignore/default upstream)
    # GFWlist entries map to the specified upstream 'upst'
    if (is_whitelist == 1) {
        printf("  - \"[/%s/]#\"\n", $0);
    } else {
        printf("  - \"[/%s/]%s\"\n", $0, upst);
    }
}
END {
    print "  #programaddend_gfw"; # Add end marker
}' "$tmp_gfwlist" > "$tmp_adglist"; then
    log_gfw "Error processing GFWList with awk."
    cleanup_exit 1
fi

# 检查生成的文件是否有内容 (除了标记)
if [ "$(grep -cvE '^$|#programadd(start|end)_gfw|# Auto-generated' "$tmp_adglist")" -eq 0 ]; then
     log_gfw "Warning: Processed GFW list is empty (only markers found). Check downloaded gfwlist.txt."
     # Decide if this is an error or just proceed with empty list
     # Let's proceed, it will effectively remove old rules
fi


# 检查 MD5 并更新配置文件
# Check MD5 against the generated list *before* modifying the config
if checkmd5 "$tmp_adglist" "$2"; then # If checkmd5 returns 0 (no changes) or 'noreload' is set

    # Determine where to insert/replace based on 'upstream_dns:' existence
    local insert_point="/upstream_dns:/"
    if ! grep -q "$insert_point" "$configpath"; then
        insert_point="1i" # Insert at the beginning if upstream_dns not found
        log_gfw "'upstream_dns:' not found, preparing to insert at beginning."
    fi

    # Create sed script for atomic replacement/insertion
    {
        # 1. Delete old block
        echo '/#programaddstart_gfw/,/#programaddend_gfw/d'
        # 2. Read the new block content after the insert point
        echo "$insert_point r $tmp_adglist"
    } > "$tmp_sedscript"

    log_gfw "Updating AdGuardHome config file '$configpath'..."
    # Apply sed script
    if sed -i -f "$tmp_sedscript" "$configpath"; then
        log_gfw "Config file updated successfully."
    else
        log_gfw "Error updating config file with sed."
        cleanup_exit 1
    fi
else
     log_gfw "MD5 check indicates GFW list did not change or reload is pending. Config file not modified by sed."
fi


# 清理并退出
cleanup_exit 0