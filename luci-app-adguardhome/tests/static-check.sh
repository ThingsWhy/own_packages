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

echo "[1/8] Checking executable bits"
printf '%s\n' "$script_files" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    mode="$(git ls-files -s -- "$file" | awk '{print $1}')"
    [ "$mode" = "100755" ] || fail "$file has git mode ${mode:-missing}, expected 100755"
done

echo "[2/8] Checking BusyBox ash syntax and shebangs"
printf '%s\n' "$script_files" | while IFS= read -r file; do
    [ -f "$file" ] || fail "missing script: $file"
    first_line="$(sed -n '1p' "$file")"
    case "$first_line" in
        '#!/bin/sh'|'#!/bin/sh /etc/rc.common') ;;
        *) fail "$file uses unsupported shebang: $first_line" ;;
    esac
    busybox sh -n "$file"
done

echo "[3/8] Checking Lua syntax"
find luasrc -type f -name '*.lua' -print | while IFS= read -r file; do
    luac5.1 -p "$file"
done

echo "[4/8] Checking JSON syntax"
find root -type f -name '*.json' -print | while IFS= read -r file; do
    jq empty "$file"
done

echo "[5/8] Checking translation catalogs"
find po -type f -name '*.po' -print | while IFS= read -r file; do
    msgfmt --check -o /dev/null "$file"
done

echo "[6/8] Checking explicit first-run policy"
[ ! -e root/usr/share/AdGuardHome/AdGuardHome_template.yaml ] || fail "bundled AdGuard Home template must not be shipped"
if grep -R -n -E 'AdGuardHome_template\.yaml|gettemplateconfig|get_template_config|use_template|Fast config|Use template' \
    luasrc root README.md README.CN.md po; then
    fail "legacy template/fast-config coupling detected"
fi

echo "[7/8] Checking procd lifecycle policy"
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

echo "[8/8] Running hardware-free lifecycle monitor tests"
sh tests/lifecycle-monitor-test.sh

echo "Static checks passed."
