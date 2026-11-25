#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
UPDATER="${UPDATER:-$ROOT/../root/usr/share/AdGuardHome/update_core.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

ADGUARDHOME_UPDATER_LIB=1 . "$UPDATER"

echo "[updater 1/7] architecture mapping"
ADGUARDHOME_UNAME_M=x86_64
ADGUARDHOME_OPENWRT_ARCH=
detect_arch ""
assert_eq "$Arch" "amd64"
ADGUARDHOME_UNAME_M=aarch64
detect_arch ""
assert_eq "$Arch" "arm64"
ADGUARDHOME_UNAME_M=armv7l
detect_arch ""
assert_eq "$Arch" "armv7"
ADGUARDHOME_UNAME_M=mips
ADGUARDHOME_OPENWRT_ARCH=mipsel
detect_arch ""
assert_eq "$Arch" "mipsle_softfloat"
ADGUARDHOME_UNAME_M=riscv64
ADGUARDHOME_OPENWRT_ARCH=
detect_arch ""
assert_eq "$Arch" "riscv64"

echo "[updater 2/7] POSIX download-link rendering"
latest_ver="v0.107.79"
Arch="arm64"
rendered="$(render_link 'https://example.invalid/${latest_ver}/AdGuardHome_linux_${Arch}.tar.gz')"
assert_eq "$rendered" "https://example.invalid/v0.107.79/AdGuardHome_linux_arm64.tar.gz"
trimmed="$(printf '%s\n' 'https://example.invalid/file.tar.gz\' | sed -e 's/[[:space:]]*\\$//' -e 's/[[:space:]]*$//')"
assert_eq "$trimmed" "https://example.invalid/file.tar.gz"

echo "[updater 3/7] official SHA-256 verification"
UPDATE_ROOT="$TMP/checksum"
mkdir -p "$UPDATE_ROOT"
Arch="amd64"
printf 'archive-data' > "$UPDATE_ROOT/core.download"
hash="$(sha256sum "$UPDATE_ROOT/core.download" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "AdGuardHome_linux_amd64.tar.gz" > "$UPDATE_ROOT/checksums.txt"
verify_official_archive "$UPDATE_ROOT/core.download" "AdGuardHome_linux_amd64.tar.gz" >/dev/null || fail "valid checksum rejected"
printf '%064d  %s\n' 0 "AdGuardHome_linux_amd64.tar.gz" > "$UPDATE_ROOT/checksums.txt"
if verify_official_archive "$UPDATE_ROOT/core.download" "AdGuardHome_linux_amd64.tar.gz" >/dev/null 2>&1; then
    fail "checksum mismatch was accepted"
fi

echo "[updater 4/7] atomic update succeeds"
make_core() {
    path="$1"
    ver="$2"
    cat > "$path" <<CORE
#!/bin/sh
case "\$1" in
    --version) echo "AdGuard Home, version $ver"; exit 0 ;;
    -c) [ "\$3" = "--check-config" ] && exit 0 ;;
esac
exit 0
CORE
    chmod +x "$path"
}

BIN="$TMP/bin/AdGuardHome"
CANDIDATE_TEST="$TMP/candidate"
RUNNING="$TMP/running"
FAIL_NEW="$TMP/fail-new"
mkdir -p "${BIN%/*}"
make_core "$BIN" "v1.0.0"
make_core "$CANDIDATE_TEST" "v2.0.0"

SERVICE="$TMP/service"
cat > "$SERVICE" <<SERVICE_EOF
#!/bin/sh
case "\$1" in
    running)
        [ -f "$RUNNING" ]
        ;;
    stop)
        rm -f "$RUNNING"
        ;;
    start)
        ver="\$("$BIN" --version 2>/dev/null)"
        if [ -f "$FAIL_NEW" ] && echo "\$ver" | grep -q 'v2.0.0'; then
            rm -f "$RUNNING"
            exit 1
        fi
        touch "$RUNNING"
        ;;
esac
SERVICE_EOF
chmod +x "$SERVICE"

binpath="$BIN"
configpath="$TMP/no-config.yaml"
enabled=1
latest_ver="v2.0.0"
START_WAIT=3
install_candidate "$CANDIDATE_TEST" >/dev/null || fail "transactional install failed"
assert_eq "$(get_version "$BIN")" "v2.0.0"
[ ! -e "${BIN}.rollback" ] || fail "rollback file left after successful update"
[ -f "$RUNNING" ] || fail "service not running after successful update"

echo "[updater 5/7] failed start rolls back old core"
rm -f "$RUNNING"
make_core "$BIN" "v1.0.0"
touch "$FAIL_NEW"
make_core "$CANDIDATE_TEST" "v2.0.0"
if install_candidate "$CANDIDATE_TEST" >/dev/null 2>&1; then
    fail "failed new core start did not report failure"
fi
assert_eq "$(get_version "$BIN")" "v1.0.0"
[ -f "$RUNNING" ] || fail "previous core was not restarted after rollback"
[ ! -e "${BIN}.rollback" ] || fail "rollback file left after rollback"

echo "[updater 6/7] interrupted transaction recovery"
rm -f "$RUNNING"
make_core "$BIN" "v2.0.0"
make_core "${BIN}.rollback" "v1.0.0"
rm -f "$FAIL_NEW"
touch "$RUNNING"
recover_interrupted_transaction >/dev/null || fail "interrupted transaction recovery failed"
assert_eq "$(get_version "$BIN")" "v1.0.0"
[ ! -e "${BIN}.rollback" ] || fail "rollback file remains after recovery"
[ -f "$RUNNING" ] || fail "restored core was not restarted"

echo "[updater 7/7] atomic updater lock and stale-lock handling"
LOCK_DIR="$TMP/update.lock"
LOCK_HELD=0
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
if acquire_lock >/dev/null 2>&1; then
    fail "concurrent updater lock was accepted"
fi
printf '%s\n' "999999" > "$LOCK_DIR/pid"
if acquire_lock >/dev/null 2>&1; then
    fail "stale updater lock was automatically reclaimed"
fi
rm -f "$LOCK_DIR/pid"
rmdir "$LOCK_DIR" || fail "stale updater lock was not manually removable"

acquire_lock >/dev/null || fail "updater lock could not be acquired"
[ "$(cat "$LOCK_DIR/pid")" = "$$" ] || fail "lock owner was not recorded"
release_lock
[ ! -e "$LOCK_DIR" ] || fail "updater lock was not released by its owner"

echo "Updater tests passed."
