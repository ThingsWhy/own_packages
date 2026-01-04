#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# 启用错误退出
set -e
# 清理陷阱
trap 'cleanup_exit 1' SIGINT SIGTERM SIGHUP

# --- 全局变量 ---
hosts_file="/etc/hosts"
leases_file="/tmp/dhcp.leases"
tmp_host_entries=""
start_marker="#programaddstart_ipv6host" # More specific marker
end_marker="#programaddend_ipv6host"

# --- 函数 ---

log_addhost() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - addhost.sh: $1" >> /tmp/AdGuardHome_init.log
}

cleanup_exit() {
    local exit_code=${1:-1}
    log_addhost "Exiting (code: $exit_code)..."
    rm -f "$tmp_host_entries" 2>/dev/null || true
    exit "$exit_code"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || { log_addhost "Error: command '$1' not found."; cleanup_exit 1; }
}

# 检查 /etc/hosts 是否变化并触发 reload (如果需要)
check_hosts_md5() {
    local noreload_flag="$1"
    local current_md5 old_md5

    check_command md5sum
    check_command uci

    current_md5=$(md5sum "$hosts_file" | awk '{print $1}')
    old_md5=$(uci -q get AdGuardHome.AdGuardHome.hostsmd5)

    if [ "$current_md5" != "$old_md5" ]; then
        log_addhost "Hosts file '$hosts_file' changed (MD5: $current_md5). Updating UCI."
        uci set AdGuardHome.AdGuardHome.hostsmd5="$current_md5"
        uci commit AdGuardHome
        if [ "$noreload_flag" = "noreload" ]; then
            log_addhost "Reload skipped due to 'noreload' flag."
        else
            log_addhost "Reloading AdGuardHome due to hosts file change..."
            if ! /etc/init.d/AdGuardHome reload; then log_addhost "Error reloading AdGuardHome."; fi
        fi
    else
        log_addhost "Hosts file '$hosts_file' unchanged (MD5: $current_md5)."
    fi
}

# --- 主逻辑 ---

# 检查基本命令
check_command awk
check_command ip
check_command grep
check_command sed
check_command uci


# 处理删除操作
if [ "$1" = "del" ]; then
    if [ ! -f "$hosts_file" ]; then
         log_addhost "Hosts file '$hosts_file' not found. Nothing to delete."
         cleanup_exit 0
    fi
    log_addhost "Deleting auto-added IPv6 host entries from '$hosts_file'..."
    # 使用 sed 删除标记之间的行
    if sed -i "/${start_marker}/,/${end_marker}/d" "$hosts_file"; then
        log_addhost "Entries removed."
        check_hosts_md5 "$2" # Check md5 and reload if needed
        cleanup_exit 0
    else
        log_addhost "Error running sed to delete entries."
        cleanup_exit 1
    fi
fi

# 创建临时文件
tmp_host_entries=$(mktemp) || { log_addhost "Error creating temp file."; cleanup_exit 1; }

# 生成 IPv6 主机条目
log_addhost "Generating IPv6 host entries..."
if [ ! -f "$leases_file" ]; then
    log_addhost "Warning: Leases file '$leases_file' not found. Cannot map MAC to hostname."
    # Generate empty block instead of failing?
    echo "$start_marker" > "$tmp_host_entries"
    echo "# Leases file not found" >> "$tmp_host_entries"
    echo "$end_marker" >> "$tmp_host_entries"
else
    # 使用 awk 处理 leases 和 ip neighbor show
    # shellcheck disable=SC2016 # AWK variables are correct here
    if ! awk '
        # AWK script to generate hosts entries from DHCP leases and IPv6 neighbors
        BEGIN {
            print "'"$start_marker"'"; # Add start marker
            # Read leases file first to build MAC -> Hostname map
            while ((getline < "'"$leases_file"'") > 0) {
                # Lease format: timestamp MAC IP Hostname ClientID
                # Store MAC ($2) -> Hostname ($4) mapping if hostname exists and is not '*'
                if ($4 != "" && $4 != "*") {
                    mac_to_host[$2] = $4;
                }
            }
            close("'"$leases_file"'"); # Close the file

            # Now process IPv6 neighbors
            # Filter out link-local (fe80::) addresses and specific states
            cmd = "ip -6 neighbor show | grep -v -E '\''(^fe80| FAILED| INCOMPLETE| PROBE)'\''";
            while ((cmd | getline) > 0) {
                # Neighbor format: ipv6 dev device lladdr MAC state
                ipv6 = $1;
                mac = $5; # Assuming lladdr is the 5th field

                # Check if we have a hostname for this MAC address
                if (mac in mac_to_host) {
                    hostname = mac_to_host[mac];
                    # Print in hosts file format: IP Hostname
                    printf("%-40s %s\n", ipv6, hostname); # Align output
                }
            }
            close(cmd); # Close the pipe
            print "'"$end_marker"'"; # Add end marker
        }' > "$tmp_host_entries"; then
        log_addhost "Error generating host entries with awk."
        cleanup_exit 1
    fi
fi

log_addhost "Generated entries:"
cat "$tmp_host_entries" # Log generated entries (optional)


# 更新 /etc/hosts 文件
log_addhost "Updating '$hosts_file'..."

# 检查标记是否存在
if grep -q "$start_marker" "$hosts_file"; then
    log_addhost "Found existing markers. Replacing block..."
    # 创建 sed 脚本来替换块
    local tmp_sed_script
    tmp_sed_script=$(mktemp) || { log_addhost "Error creating sed script temp file."; cleanup_exit 1; }
    {
        # Delete existing block
        echo "/${start_marker}/,/${end_marker}/d"
        # Append the new block at the end (or specific location if needed)
        # Using $a (append after last line) for simplicity
        echo "$ r $tmp_host_entries"
    } > "$tmp_sed_script"

    if ! sed -i -f "$tmp_sed_script" "$hosts_file"; then
        log_addhost "Error updating hosts file with sed using markers."
        rm -f "$tmp_sed_script"
        cleanup_exit 1
    fi
     rm -f "$tmp_sed_script"
else
    log_addhost "Markers not found. Appending new block to '$hosts_file'..."
    # Markers not found, append the whole block
    cat "$tmp_host_entries" >> "$hosts_file"
fi

log_addhost "Hosts file updated."

# 检查 MD5 并可能触发 reload
check_hosts_md5 "$2"

# 清理并退出
cleanup_exit 0