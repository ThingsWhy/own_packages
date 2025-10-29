#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# 启用错误退出
set -e

# --- 全局变量 ---
configpath=""
max_wait_seconds=180 # Wait for a maximum of 3 minutes
sleep_interval=10   # Check every 10 seconds

# --- 函数 ---
log_watch() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - watchconfig.sh: $1" >> /tmp/AdGuardHome_init.log
}

# --- 主逻辑 ---

log_watch "Starting script to watch for config file..."

# 获取配置路径
configpath=$(uci -q get AdGuardHome.AdGuardHome.configpath)
if [ -z "$configpath" ]; then
    log_watch "Error: configpath not set in UCI. Cannot watch file."
    exit 1
fi
log_watch "Watching for config file: '$configpath'"

elapsed_time=0
while [ "$elapsed_time" -lt "$max_wait_seconds" ]; do
    if [ -f "$configpath" ]; then
        log_watch "Config file '$configpath' found."
        log_watch "Enabling redirect rules via init script..."
        # Call do_redirect function from the init script
        if /etc/init.d/AdGuardHome do_redirect 1; then
            log_watch "Redirect rules enabled successfully."
            exit 0 # Success
        else
            log_watch "Error enabling redirect rules via init script."
            exit 1 # Failure
        fi
    fi

    # File not found yet, wait
    sleep "$sleep_interval"
    elapsed_time=$((elapsed_time + sleep_interval))
    # log_watch "Config file not found yet. Waited ${elapsed_time}s..." # Verbose logging
done

log_watch "Timeout reached (${max_wait_seconds}s). Config file '$configpath' not found."
exit 1 # Exit with error after timeout

# Original script had 'return 0', but exit is better for procd management