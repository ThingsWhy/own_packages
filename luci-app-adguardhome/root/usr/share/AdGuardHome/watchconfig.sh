#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

SERVICE="${ADGUARDHOME_SERVICE:-/etc/init.d/AdGuardHome}"
REDIR_MARKER="${ADGUARDHOME_REDIR_MARKER:-/var/run/AdG_redir}"
STOP_MARKER="${ADGUARDHOME_STOP_MARKER:-/var/run/AdG_stopping}"
INITIAL_DELAY="${ADGUARDHOME_MONITOR_INITIAL_DELAY:-2}"
CONFIG_INTERVAL="${ADGUARDHOME_MONITOR_CONFIG_INTERVAL:-5}"
HEALTH_INTERVAL="${ADGUARDHOME_MONITOR_HEALTH_INTERVAL:-10}"
FAIL_LIMIT="${ADGUARDHOME_MONITOR_FAIL_LIMIT:-4}"

if [ -n "${ADGUARDHOME_CONFIGPATH:-}" ]; then
	configpath="$ADGUARDHOME_CONFIGPATH"
else
	configpath="$(uci -q get AdGuardHome.AdGuardHome.configpath)"
	[ -n "$configpath" ] || configpath="/etc/AdGuardHome.yaml"
fi

fail_count=0
sleep "$INITIAL_DELAY"

while :; do
	# stop_service creates this marker before touching DNS state.  Exiting here
	# prevents the monitor from re-enabling redirection while procd is stopping.
	[ -e "$STOP_MARKER" ] && exit 0

	# A missing or empty config is a legitimate first-run state.  Never
	# redirect DNS until AdGuard Home has produced a real configuration.
	if [ ! -s "$configpath" ]; then
		if [ "$(cat "$REDIR_MARKER" 2>/dev/null)" = "1" ]; then
			"$SERVICE" do_redirect 0 >/dev/null 2>&1
		fi
		fail_count=0
		sleep "$CONFIG_INTERVAL"
		continue
	fi

	if "$SERVICE" running main >/dev/null 2>&1; then
		fail_count=0
		if [ "$(cat "$REDIR_MARKER" 2>/dev/null)" != "1" ]; then
			"$SERVICE" do_redirect 1 >/dev/null 2>&1
		fi
		sleep "$HEALTH_INTERVAL"
		continue
	fi

	# procd may be in the middle of a respawn cycle.  Give it several
	# opportunities to recover before falling back to the system DNS path.
	fail_count=$((fail_count + 1))
	if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
		logger -t AdGuardHome "main instance unavailable; disabling DNS redirection"
		"$SERVICE" do_redirect 0 >/dev/null 2>&1
		exit 0
	fi

	sleep "$HEALTH_INTERVAL"
done
