#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
set -e

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - addhost: $1" >> /tmp/AdGuardHome_init.log
}

local hosts_file="/etc/hosts"
local tmp_hosts="/tmp/ipv6_hosts.tmp"

if [ "$1" = "del" ]; then
    log "Deleting IPv6 hosts..."
    sed -i '/#programaddstart_ipv6host/,/#programaddend_ipv6host/d' "$hosts_file"
    exit 0
fi

# 生成 hosts 列表
echo "#programaddstart_ipv6host" > "$tmp_hosts"
ip -6 neighbor show | grep -vE "^fe80|FAILED|INCOMPLETE" | awk '{print $1, $5}' | while read -r ip mac; do
    local hostname
    hostname=$(awk -v m="$mac" '$2 == m {print $4}' /tmp/dhcp.leases | tail -n1)
    if [ -n "$hostname" ] && [ "$hostname" != "*" ]; then
        echo "$ip $hostname" >> "$tmp_hosts"
    fi
done
echo "#programaddend_ipv6host" >> "$tmp_hosts"

sed -i '/#programaddstart_ipv6host/,/#programaddend_ipv6host/d' "$hosts_file"
cat "$tmp_hosts" >> "$hosts_file"
rm -f "$tmp_hosts"

if [ "$2" != "noreload" ]; then
    /etc/init.d/AdGuardHome reload
fi