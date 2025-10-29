#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# 启用错误退出
# set -e # Disable set -e because we need to handle process termination explicitly

# --- 全局变量 ---
pidfile="/var/run/AdGuardHome_getsyslog.pid"
tmp_log="/tmp/AdGuardHometmp.log" # Keep original name for compatibility? Or use mktemp? Let's keep it.
watchdog_file="/var/run/AdGuardHomesyslog" # Watchdog file checked by controller
bg_pid=""

# --- 函数 ---
log_syslog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - getsyslog.sh: $1" >> /tmp/AdGuardHome_init.log
}

cleanup() {
    log_syslog "Cleaning up..."
    # Kill background logread process if running
    if [ -n "$bg_pid" ] && kill -0 "$bg_pid" 2>/dev/null; then
        log_syslog "Killing background logread process (PID: $bg_pid)..."
        kill "$bg_pid" 2>/dev/null || true
    fi
    # Remove temp log and pid file
    rm -f "$tmp_log" "$pidfile" "$watchdog_file" 2>/dev/null || true
    log_syslog "Cleanup complete."
    exit 0
}

# --- 主逻辑 ---

# 设置清理陷阱
trap cleanup INT TERM QUIT EXIT

# 检查 logread 是否可用
command -v logread >/dev/null 2>&1 || { log_syslog "Error: logread command not found."; exit 1; }

# 检查是否已有实例在运行
if [ -f "$pidfile" ]; then
    old_pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log_syslog "Another instance is already running (PID: $old_pid). Exiting."
        exit 0 # Exit gracefully if already running
    else
        log_syslog "Found stale PID file '$pidfile'. Removing."
        rm -f "$pidfile"
    fi
fi

# 写入当前 PID
echo "$$" > "$pidfile" || { log_syslog "Error writing PID to '$pidfile'."; exit 1; }

# 获取 AdGuardHome 相关日志的初始快照
log_syslog "Getting initial syslog snapshot for AdGuardHome..."
# -e: pattern, -t: timestamp prefix (useful?)
# Use timeout? logread might hang if syslog is huge? Let's skip timeout for now.
logread -e AdGuardHome > "$tmp_log" || { log_syslog "Error getting initial logread snapshot."; rm -f "$pidfile"; exit 1; }
log_syslog "Initial snapshot written to '$tmp_log'."

# 启动后台 logread -f 进程，将输出追加到临时日志文件
log_syslog "Starting background logread -f..."
logread -e AdGuardHome -f >> "$tmp_log" &
bg_pid=$!

# 检查后台进程是否成功启动
sleep 1 # Give it a moment
if ! kill -0 "$bg_pid" 2>/dev/null; then
    log_syslog "Error: Background logread process failed to start."
    rm -f "$tmp_log" "$pidfile"
    exit 1
fi
log_syslog "Background logread started (PID: $bg_pid)."


# 创建 watchdog 文件，初始值为 1 (表示活跃)
echo "1" > "$watchdog_file" || { log_syslog "Error creating watchdog file '$watchdog_file'."; kill "$bg_pid" 2>/dev/null; rm -f "$pidfile" "$tmp_log"; exit 1; }

# Watchdog 循环
log_syslog "Starting watchdog loop..."
while true; do
    sleep 12 # Check interval

    # 检查 watchdog 文件是否存在以及内容
    if [ ! -f "$watchdog_file" ]; then
        log_syslog "Watchdog file '$watchdog_file' removed. Exiting."
        break # Exit loop, cleanup trap will handle killing bg_pid
    fi

    local watchdog_val
    watchdog_val=$(cat "$watchdog_file" 2>/dev/null)

    if [ "$watchdog_val" = "0" ]; then
         # Controller likely wants us to exit
         log_syslog "Watchdog value is 0. Exiting."
         break # Exit loop, cleanup trap handles killing bg_pid
    else
         # Controller hasn't reset it, reset it now to 0
         # log_syslog "Resetting watchdog value to 0." # Maybe too verbose
         echo "0" > "$watchdog_file" || log_syslog "Error writing 0 to watchdog file."
    fi

    # 额外检查：后台进程是否还在运行？
    if ! kill -0 "$bg_pid" 2>/dev/null; then
        log_syslog "Error: Background logread process (PID: $bg_pid) died unexpectedly. Exiting."
        # Ensure cleanup happens even if trap doesn't fire correctly
        rm -f "$pidfile" "$watchdog_file" "$tmp_log" 2>/dev/null || true
        exit 1
    fi
done

# Cleanup will be called by the trap upon exiting the loop or receiving a signal