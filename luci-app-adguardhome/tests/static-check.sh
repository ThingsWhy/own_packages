#!/bin/sh
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

script_files="root/etc/init.d/AdGuardHome
root/usr/share/AdGuardHome/addhost.sh
root/usr/share/AdGuardHome/getsyslog.sh
root/usr/share/AdGuardHome/gfw2adg.sh
root/usr/share/AdGuardHome/gfwipset2adg.sh
root/usr/share/AdGuardHome/update_core.sh
root/usr/share/AdGuardHome/waitnet.sh
root/usr/share/AdGuardHome/watchconfig.sh"

echo "[1/9] Checking executable bits"
printf '%s\n' "$script_files" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    mode="$(git ls-files -s -- "$file" | awk '{print $1}')"
    [ "$mode" = "100755" ] || fail "$file has git mode ${mode:-missing}, expected 100755"
done

echo "[2/9] Checking BusyBox ash syntax and shebangs"
printf '%s\n' "$script_files" | while IFS= read -r file; do
    [ -f "$file" ] || fail "missing script: $file"
    first_line="$(sed -n '1p' "$file")"
    case "$first_line" in
        '#!/bin/sh'|'#!/bin/sh /etc/rc.common') ;;
        *) fail "$file uses unsupported shebang: $first_line" ;;
    esac
    busybox sh -n "$file"
done

echo "[3/9] Checking Lua syntax"
find luasrc -type f -name '*.lua' -print | while IFS= read -r file; do
    luac5.1 -p "$file"
done

echo "[4/9] Checking JSON syntax"
find root -type f -name '*.json' -print | while IFS= read -r file; do
    jq empty "$file"
done

echo "[5/9] Checking translation catalogs"
find po -type f -name '*.po' -print | while IFS= read -r file; do
    msgfmt --check -o /dev/null "$file"
done

echo "[6/9] Checking explicit first-run policy"
[ ! -e root/usr/share/AdGuardHome/AdGuardHome_template.yaml ] || fail "bundled AdGuard Home template must not be shipped"
if grep -R -n -E 'AdGuardHome_template\.yaml|gettemplateconfig|get_template_config|use_template|Fast config|Use template' \
    luasrc root README.md README.CN.md po; then
    fail "legacy template/fast-config coupling detected"
fi

echo "[7/9] Checking procd lifecycle policy"
init_script="root/etc/init.d/AdGuardHome"
grep -Fq 'procd_open_instance "main"' "$init_script" || fail "AdGuard Home main process must use a named procd instance"
grep -Fq 'procd_running "$CONFIGURATION" "main"' "$init_script" || fail "runtime status must come from procd"
grep -Fq 'procd_open_instance "redirect-monitor"' "$init_script" || fail "DNS redirect monitor instance is missing"
grep -Fq 'procd_set_param command "$@"' "$init_script" || fail "main command must be passed to procd as an argument array"
grep -Fq 'running main' root/usr/share/AdGuardHome/watchconfig.sh || fail "redirect monitor must check the main procd instance"
if grep -n -E 'pgrep.*\$binpath' "$init_script" luasrc/controller/AdGuardHome.lua; then
    fail "core runtime status must not use pgrep on the configured binary path"
fi
if awk '/^start_service\(\)/,/^reload_service\(\)/' "$init_script" | grep -n -E '^[[:space:]]*exit([[:space:]]|$)'; then
    fail "start_service must return to rc_procd instead of exiting the init script"
fi

echo "[8/9] Checking transactional updater policy"
updater="root/usr/share/AdGuardHome/update_core.sh"
grep -Fq 'acquire_lock()' "$updater" || fail "updater must use an atomic lock"
grep -Fq 'checksums.txt' "$updater" || fail "official archive checksum verification is missing"
grep -Fq 'rollback_core=' "$updater" || fail "transactional rollback path is missing"
grep -Fq 'recover_interrupted_transaction' "$updater" || fail "interrupted update recovery is missing"
grep -Fq -- '--check-config' "$updater" || fail "candidate config validation is missing"
grep -Fq 'LUCI_DEPENDS:=+curl' Makefile || fail "curl must be a package dependency rather than installed at runtime"
if grep -n -E '(^|[^[:alnum:]_])(opkg|apk)([[:space:]]|$)' "$updater"; then
    fail "updater must not invoke a runtime package manager"
fi
if grep -n -E -- '--no-check-certificate|(^|[[:space:]])-k([[:space:]]|$)' "$updater"; then
    fail "updater must not disable TLS certificate validation"
fi
if grep -n 'pgrep' "$updater"; then
    fail "updater concurrency must use its lock, not process-name matching"
fi
# Bash pattern replacement has the form ${name//pattern/replacement}; limit
# the check to // immediately after a variable name so POSIX defaults that
# contain URLs such as ${VAR:-https://...} are not false positives.
if grep -n -E '\$\{[A-Za-z_][A-Za-z0-9_]*//' "$updater"; then
    fail "bash-only parameter replacement detected in /bin/sh updater"
fi
if grep -n -E 'kill .*update_core|kill .*pgrep' luasrc/controller/AdGuardHome.lua; then
    fail "LuCI must not kill an in-flight updater transaction"
fi
if grep -n 'tar\.gz\\$' root/etc/config/AdGuardHome; then
    fail "default download links must not contain trailing backslashes"
fi

echo "[9/9] Running hardware-free lifecycle and updater tests"
sh tests/lifecycle-monitor-test.sh
busybox sh tests/updater-test.sh

echo "Static checks passed."
