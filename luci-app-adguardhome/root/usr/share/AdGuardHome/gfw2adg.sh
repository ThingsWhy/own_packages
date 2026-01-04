#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
set -e

# 临时文件
tmp_gfw="/tmp/gfwlist_raw.txt"
tmp_gfw_b64="/tmp/gfwlist_raw.b64"
tmp_adg="/tmp/gfwlist_adg.yaml"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - gfw2adg: $1" >> /tmp/AdGuardHome_init.log
}

cleanup() {
    rm -f "$tmp_gfw" "$tmp_gfw_b64" "$tmp_adg"
}
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || { log "curl found."; exit 1; }

local configpath gfwupstream
configpath=$(uci -q get AdGuardHome.AdGuardHome.configpath)
gfwupstream=$(uci -q get AdGuardHome.AdGuardHome.gfwupstream)
gfwupstream=${gfwupstream:-"tcp://208.67.220.220:5353"}

if [ -z "$configpath" ] || [ ! -f "$configpath" ]; then
    log "Config path invalid."
    exit 1
fi

if [ "$1" = "del" ]; then
    log "Deleting GFWList..."
    sed -i '/#programaddstart_gfw/,/#programaddend_gfw/d' "$configpath"
    uci delete AdGuardHome.AdGuardHome.gfwlistmd5 2>/dev/null || true
    uci commit AdGuardHome
    /etc/init.d/AdGuardHome reload
    exit 0
fi

log "Downloading GFWList..."
local url="https://cdn.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt"

# 优化：分步下载，确保下载成功后再解码
if curl -fsSL "$url" -o "$tmp_gfw_b64"; then
    # 尝试解码，忽略垃圾字符
    base64 -d "$tmp_gfw_b64" > "$tmp_gfw" 2>/dev/null || true
else
    log "Download failed."
    exit 1
fi

if [ ! -s "$tmp_gfw" ]; then
    log "Decoded content empty or invalid."
    exit 1
fi

log "Processing list..."
echo "  #programaddstart_gfw" > "$tmp_adg"
awk -v up="$gfwupstream" '
!/^!/ && !/^\[/ {
    rule = $0
    if (rule ~ /^@@/) {
        rule = substr(rule, 3)
        printf "  - \"[/%s/]#\"\n", rule
    } else {
        if (rule ~ /^\|\|/) rule = substr(rule, 3)
        else if (rule ~ /^\|/) rule = substr(rule, 2)
        printf "  - \"[/%s/]%s\"\n", rule, up
    }
}' "$tmp_gfw" >> "$tmp_adg"
echo "  #programaddend_gfw" >> "$tmp_adg"

local new_md5 old_md5
new_md5=$(md5sum "$tmp_adg" | awk '{print $1}')
old_md5=$(uci -q get AdGuardHome.AdGuardHome.gfwlistmd5)

if [ "$new_md5" != "$old_md5" ]; then
    log "Updating config..."
    sed -i '/#programaddstart_gfw/,/#programaddend_gfw/d' "$configpath"
    
    if grep -q "upstream_dns:" "$configpath"; then
        sed -i "/upstream_dns:/r $tmp_adg" "$configpath"
    else
        cat "$tmp_adg" >> "$configpath"
    fi
    
    uci set AdGuardHome.AdGuardHome.gfwlistmd5="$new_md5"
    uci commit AdGuardHome
    /etc/init.d/AdGuardHome reload
    log "Update done."
else
    log "No change."
fi