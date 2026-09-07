#!/bin/sh
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MONITOR="$ROOT/root/usr/share/AdGuardHome/watchconfig.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

TEST_LOG="$TMP/service.log"
TEST_STATE="$TMP/service.state"
CONFIG="$TMP/AdGuardHome.yaml"
REDIR_MARKER="$TMP/AdG_redir"
STOP_MARKER="$TMP/AdG_stopping"
FAKE_SERVICE="$TMP/AdGuardHome-service"
export TEST_LOG TEST_STATE ADGUARDHOME_REDIR_MARKER="$REDIR_MARKER"

cat > "$FAKE_SERVICE" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
case "$1" in
    running)
        [ "${2:-}" = "main" ] || exit 1
        [ "$(cat "$TEST_STATE" 2>/dev/null)" = "running" ]
        ;;
    do_redirect)
        printf '%s' "${2:-0}" > "$ADGUARDHOME_REDIR_MARKER"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 755 "$FAKE_SERVICE"

run_monitor() {
    timeout_value="$1"
    set +e
    timeout "$timeout_value" env \
        ADGUARDHOME_SERVICE="$FAKE_SERVICE" \
        ADGUARDHOME_CONFIGPATH="$CONFIG" \
        ADGUARDHOME_REDIR_MARKER="$REDIR_MARKER" \
        ADGUARDHOME_STOP_MARKER="$STOP_MARKER" \
        ADGUARDHOME_MONITOR_INITIAL_DELAY=0 \
        ADGUARDHOME_MONITOR_CONFIG_INTERVAL=0 \
        ADGUARDHOME_MONITOR_HEALTH_INTERVAL=0 \
        ADGUARDHOME_MONITOR_FAIL_LIMIT=2 \
        sh "$MONITOR"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || fail "monitor exited with unexpected status $rc"
    return "$rc"
}

reset_case() {
    : > "$TEST_LOG"
    rm -f "$CONFIG" "$STOP_MARKER"
    printf '0' > "$REDIR_MARKER"
    printf 'running' > "$TEST_STATE"
}

echo "[lifecycle 1/4] Uninitialized config never takes over DNS"
reset_case
run_monitor 0.2s || true
if grep -Fq 'do_redirect 1' "$TEST_LOG"; then
    fail "redirect was enabled without a non-empty config"
fi
[ "$(cat "$REDIR_MARKER")" = "0" ] || fail "redirect marker changed during uninitialized state"

echo "[lifecycle 2/4] Healthy main instance enables DNS takeover"
reset_case
printf 'dns:\n  port: 5335\n' > "$CONFIG"
run_monitor 0.2s || true
grep -Fq 'running main' "$TEST_LOG" || fail "monitor did not query the named main instance"
grep -Fq 'do_redirect 1' "$TEST_LOG" || fail "healthy initialized service did not enable redirect"
[ "$(cat "$REDIR_MARKER")" = "1" ] || fail "redirect marker was not enabled"

echo "[lifecycle 3/4] Sustained main failure removes DNS takeover"
reset_case
printf 'dns:\n  port: 5335\n' > "$CONFIG"
printf 'down' > "$TEST_STATE"
printf '1' > "$REDIR_MARKER"
run_monitor 1s || true
grep -Fq 'do_redirect 0' "$TEST_LOG" || fail "sustained failure did not disable redirect"
[ "$(cat "$REDIR_MARKER")" = "0" ] || fail "redirect marker remained enabled after failure"

echo "[lifecycle 4/4] Service stop marker prevents redirect races"
reset_case
printf 'dns:\n  port: 5335\n' > "$CONFIG"
touch "$STOP_MARKER"
run_monitor 1s || true
[ ! -s "$TEST_LOG" ] || fail "monitor called service operations while stop marker was present"

echo "Lifecycle monitor tests passed."
