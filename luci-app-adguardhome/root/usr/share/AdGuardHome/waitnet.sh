#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
MAX_ATTEMPTS=18 # Maximum number of check cycles (approx 3 minutes based on original logic)
SLEEP_INTERVAL=5 # Seconds between checks

log_waitnet() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - waitnet.sh: $1" >> /tmp/AdGuardHome_init.log # Log to the same file as init.d
}

check_connectivity() {
    # Try pinging multiple reliable targets
    # Use timeout -W 1 (1 second) and count -c 1
    ping -c 1 -W 1 -q www.baidu.com >/dev/null 2>&1 && return 0
    ping -c 1 -W 1 -q 202.108.22.5 >/dev/null 2>&1 && return 0 # A Chinese DNS server IP
    # Add potentially more geographically diverse targets if needed
    ping -c 1 -W 1 -q www.google.com >/dev/null 2>&1 && return 0
    ping -c 1 -W 1 -q 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

count=0
log_waitnet "Starting network check loop (max attempts: $MAX_ATTEMPTS)..."

while [ "$count" -lt "$MAX_ATTEMPTS" ]; do
    if check_connectivity; then
        log_waitnet "Network is up. Triggering AdGuardHome force_reload."
        # Use full path and check command existence just in case
        if command -v /etc/init.d/AdGuardHome >/dev/null 2>&1; then
             /etc/init.d/AdGuardHome force_reload || log_waitnet "Error during force_reload."
             exit 0 # Success
        else
             log_waitnet "Error: /etc/init.d/AdGuardHome not found!"
             exit 1 # Failure
        fi
    fi

    count=$((count + 1))
    log_waitnet "Network check failed (attempt $count/$MAX_ATTEMPTS). Waiting ${SLEEP_INTERVAL}s..."
    sleep "$SLEEP_INTERVAL"
done

log_waitnet "Max attempts reached. Network might still be down. Triggering force_reload anyway."
# Trigger reload even if timeout reached, as per original logic
if command -v /etc/init.d/AdGuardHome >/dev/null 2>&1; then
    /etc/init.d/AdGuardHome force_reload || log_waitnet "Error during force_reload after timeout."
    exit 0 # Exiting normally after timeout reload attempt
else
    log_waitnet "Error: /etc/init.d/AdGuardHome not found after timeout!"
    exit 1 # Failure
fi

# The original script had "return 0", but exit is more appropriate for standalone scripts called by procd.