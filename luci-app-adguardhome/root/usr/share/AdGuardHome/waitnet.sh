#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

count=0
while :; do
	if ping -c 1 -W 1 -q www.baidu.com >/dev/null 2>&1; then
		/etc/init.d/AdGuardHome force_reload
		break
	fi
	if ping -c 1 -W 1 -q 202.108.22.5 >/dev/null 2>&1; then
		/etc/init.d/AdGuardHome force_reload
		break
	fi

	sleep 5

	if ping -c 1 -W 1 -q www.google.com >/dev/null 2>&1; then
		/etc/init.d/AdGuardHome force_reload
		break
	fi
	if ping -c 1 -W 1 -q 8.8.8.8 >/dev/null 2>&1; then
		/etc/init.d/AdGuardHome force_reload
		break
	fi

	sleep 5
	count=$((count + 1))
	if [ "$count" -gt 18 ]; then
		/etc/init.d/AdGuardHome force_reload
		break
	fi
done

exit 0
