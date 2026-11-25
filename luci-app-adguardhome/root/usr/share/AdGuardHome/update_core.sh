#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

SERVICE="${ADGUARDHOME_SERVICE:-/etc/init.d/AdGuardHome}"
UPDATE_ROOT="${ADGUARDHOME_UPDATE_ROOT:-/tmp/AdGuardHomeupdate}"
LOCK_DIR="${ADGUARDHOME_UPDATE_LOCK:-/var/run/AdGuardHome-update.lock}"
ERROR_MARKER="${ADGUARDHOME_UPDATE_ERROR:-/var/run/AdG_update_error}"
RELEASE_API="${ADGUARDHOME_RELEASE_API:-https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest}"
RELEASE_BASE="${ADGUARDHOME_RELEASE_BASE:-https://github.com/AdguardTeam/AdGuardHome/releases/download}"
START_WAIT="${ADGUARDHOME_START_WAIT:-15}"

LOCK_HELD=0
latest_ver=""
Arch=""
binpath=""
configpath=""
upxflag=""
downloadlinks=""
enabled="0"

log() {
    printf '%s\n' "$*"
}

uci_get() {
    uci -q get "AdGuardHome.AdGuardHome.$1" 2>/dev/null
}

cleanup_update_root() {
    [ -n "$UPDATE_ROOT" ] && rm -rf "$UPDATE_ROOT" >/dev/null 2>&1
}

release_lock() {
    if [ "$LOCK_HELD" = "1" ]; then
        rm -f "$LOCK_DIR/pid" >/dev/null 2>&1
        rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
        LOCK_HELD=0
    fi
}

finish() {
    code="$1"
    [ "$code" = "0" ] || touch "$ERROR_MARKER" 2>/dev/null
    cleanup_update_root
    release_lock
    exit "$code"
}

on_signal() {
    log "Update interrupted."
    finish 1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        # mkdir is the ownership operation; the PID is only diagnostic.
        LOCK_HELD=1
        if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
            release_lock
            log "Failed to publish the core update lock owner."
            return 1
        fi
        return 0
    fi

    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$lock_pid" ]; then
        log "A core update task is already running or the update lock is stale (pid $lock_pid)."
    else
        log "A core update task is already running or the update lock is being initialized."
    fi
    log "If no updater is running, verify that and remove $LOCK_DIR before retrying."
    return 1
}

download_to() {
    dest="$1"
    url="$2"
    tmp="${dest}.part.$$"
    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 20 --max-time 300 \
            -A "luci-app-adguardhome" -o "$tmp" "$url" || {
            rm -f "$tmp"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -T 20 -O "$tmp" "$url" || {
            rm -f "$tmp"
            return 1
        }
    else
        log "Error: neither curl nor wget is available."
        return 1
    fi

    [ -s "$tmp" ] || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$dest"
}

load_config() {
    binpath="$(uci_get binpath)"
    [ -n "$binpath" ] || binpath="/tmp/AdGuardHome/AdGuardHome"
    configpath="$(uci_get configpath)"
    [ -n "$configpath" ] || configpath="/etc/AdGuardHome.yaml"
    upxflag="$(uci_get upxflag)"
    downloadlinks="$(uci_get downloadlinks)"
    enabled="$(uci_get enabled)"
    [ -n "$enabled" ] || enabled="0"

    case "$binpath" in
        /*/*) ;;
        *)
            log "Error: core binary path must be absolute: $binpath"
            return 1
            ;;
    esac

    mkdir -p "${binpath%/*}" || {
        log "Error: cannot create core directory ${binpath%/*}"
        return 1
    }
}

detect_arch() {
    configured_arch="$1"
    if [ -n "$configured_arch" ]; then
        case "$configured_arch" in
            386|amd64|armv5|armv6|armv7|arm64|mips_softfloat|mipsle_softfloat|mips64_softfloat|mips64le_softfloat|ppc64le|riscv64)
                Arch="$configured_arch"
                return 0
                ;;
            *)
                log "Error: unsupported configured architecture '$configured_arch'."
                return 1
                ;;
        esac
    fi

    um="${ADGUARDHOME_UNAME_M:-$(uname -m)}"
    openwrt_arch="${ADGUARDHOME_OPENWRT_ARCH:-$(awk -F= '/^OPENWRT_ARCH=/{gsub(/"/,"",$2); split($2,a,"_"); print a[1]}' /etc/os-release 2>/dev/null)}"

    case "$um" in
        i386|i486|i586|i686) Arch="386" ;;
        x86_64|amd64) Arch="amd64" ;;
        aarch64|arm64) Arch="arm64" ;;
        armv5*) Arch="armv5" ;;
        armv6*) Arch="armv6" ;;
        armv7*|armv8l) Arch="armv7" ;;
        mips*)
            case "$openwrt_arch" in
                mips64el) Arch="mips64le_softfloat" ;;
                mips64) Arch="mips64_softfloat" ;;
                mipsel) Arch="mipsle_softfloat" ;;
                mips) Arch="mips_softfloat" ;;
                *)
                    log "Error: unknown OpenWrt MIPS flavour '$openwrt_arch'."
                    return 1
                    ;;
            esac
            ;;
        ppc64le|powerpc64le|ppc*) Arch="ppc64le" ;;
        riscv|riscv64) Arch="riscv64" ;;
        *)
            log "Error: CPU architecture '$um' is not supported."
            return 1
            ;;
    esac
}

normalize_version() {
    case "$1" in
        v*) printf '%s\n' "$1" ;;
        *) printf 'v%s\n' "$1" ;;
    esac
}

get_version() {
    version="$("$1" --version 2>/dev/null | grep -m 1 -oE 'v?[0-9]+([.][0-9A-Za-z]+)+([-+._][0-9A-Za-z.-]+)?' | head -n 1)"
    [ -n "$version" ] || return 1
    normalize_version "$version"
}

render_link() {
    printf '%s\n' "$1" | sed \
        -e "s|\${latest_ver}|$latest_ver|g" \
        -e "s|\${Arch}|$Arch|g"
}

fetch_latest_version() {
    mkdir -p "$UPDATE_ROOT" || return 1
    release_json="$UPDATE_ROOT/adguard-release.json"
    log "Checking latest AdGuard Home release..."
    download_to "$release_json" "$RELEASE_API" || {
        log "Error: failed to query the AdGuard Home release API."
        return 1
    }

    latest_ver="$(tr ',' '\n' < "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    case "$latest_ver" in
        ''|*[!A-Za-z0-9._-]*)
            log "Error: invalid latest release tag '$latest_ver'."
            return 1
            ;;
        v[0-9]*) ;;
        *)
            log "Error: unexpected AdGuard Home release tag '$latest_ver'."
            return 1
            ;;
    esac
}

sha256_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return
    fi
    return 1
}

fetch_official_checksums() {
    checksum_file="$UPDATE_ROOT/checksums.txt"
    checksum_url="$RELEASE_BASE/$latest_ver/checksums.txt"
    if download_to "$checksum_file" "$checksum_url"; then
        return 0
    fi
    rm -f "$checksum_file"
    return 1
}

verify_official_archive() {
    archive="$1"
    asset_name="$2"
    checksum_file="$UPDATE_ROOT/checksums.txt"

    [ "$asset_name" = "AdGuardHome_linux_${Arch}.tar.gz" ] || return 2
    [ -s "$checksum_file" ] || {
        log "Error: official checksum list is unavailable for $asset_name."
        return 1
    }
    expected_hash="$(awk -v name="$asset_name" '$2 == name || $2 == "*" name {print $1; exit}' "$checksum_file")"
    [ -n "$expected_hash" ] || {
        log "Error: no checksum entry found for $asset_name."
        return 1
    }
    actual_hash="$(sha256_file "$archive")" || {
        log "Error: SHA-256 support is required to verify the official core archive."
        return 1
    }
    if [ "$actual_hash" != "$expected_hash" ]; then
        log "Error: SHA-256 mismatch for $asset_name."
        return 1
    fi

    log "SHA-256 verified for $asset_name."
    return 0
}

safe_extract_archive() {
    archive="$1"
    stage="$2"
    listing="$UPDATE_ROOT/archive.list"

    tar -tzf "$archive" > "$listing" 2>/dev/null || {
        log "Error: downloaded archive is not a valid tar.gz file."
        return 1
    }
    if grep -E '(^/|(^|/)\.\.(/|$))' "$listing" >/dev/null 2>&1; then
        log "Error: downloaded archive contains unsafe paths."
        return 1
    fi

    rm -rf "$stage"
    mkdir -p "$stage" || return 1
    tar -xzf "$archive" -C "$stage" >/dev/null 2>&1 || {
        log "Error: failed to extract downloaded archive."
        return 1
    }

    if [ -f "$stage/AdGuardHome/AdGuardHome" ]; then
        CANDIDATE="$stage/AdGuardHome/AdGuardHome"
    elif [ -f "$stage/AdGuardHome" ]; then
        CANDIDATE="$stage/AdGuardHome"
    else
        log "Error: AdGuardHome executable is missing from the archive."
        return 1
    fi
}

validate_candidate() {
    candidate="$1"
    expected_version="$2"
    chmod 0755 "$candidate" || return 1

    candidate_version="$(get_version "$candidate")" || {
        log "Error: downloaded core cannot report a valid version."
        return 1
    }
    if [ "$candidate_version" != "$expected_version" ]; then
        log "Error: downloaded core version $candidate_version does not match expected $expected_version."
        return 1
    fi

    if [ -s "$configpath" ]; then
        if ! "$candidate" -c "$configpath" --check-config >/dev/null 2>&1; then
            log "Error: downloaded core rejects the current AdGuard Home configuration."
            return 1
        fi
    fi

    log "Candidate core validated: $candidate_version."
}

compress_candidate() {
    candidate="$1"
    [ -n "$upxflag" ] || return 0

    if ! command -v upx >/dev/null 2>&1; then
        log "Warning: UPX options are configured but no verified local upx executable is installed; skipping compression."
        return 0
    fi

    log "Compressing candidate core with the local UPX executable..."
    # Intentional word splitting: upxflag is a list of UPX options, not shell code.
    upx $upxflag "$candidate" >/dev/null 2>&1 || {
        log "Error: UPX compression failed."
        return 1
    }
    validate_candidate "$candidate" "$latest_ver"
}

download_candidate() {
    stage="$UPDATE_ROOT/stage"
    archive="$UPDATE_ROOT/core.download"
    links_file="$UPDATE_ROOT/downloadlinks"
    CANDIDATE=""

    printf '%s\n' "$downloadlinks" > "$links_file"
    fetch_official_checksums || log "Warning: official checksum list could not be downloaded."

    while IFS= read -r raw_link || [ -n "$raw_link" ]; do
        link="$(printf '%s\n' "$raw_link" | sed -e 's/[[:space:]]*\\$//' -e 's/[[:space:]]*$//')"
        case "$link" in
            ''|\#*) continue ;;
        esac

        link="$(render_link "$link")"
        asset_name="${link##*/}"
        asset_name="${asset_name%%\?*}"
        rm -f "$archive"
        rm -rf "$stage"

        log "Trying to download from: $link"
        if ! download_to "$archive" "$link"; then
            log "Download failed; trying the next link."
            continue
        fi

        verify_official_archive "$archive" "$asset_name"
        verify_status="$?"
        if [ "$verify_status" = "1" ]; then
            rm -f "$archive"
            continue
        elif [ "$verify_status" = "2" ]; then
            log "Warning: custom asset '$asset_name' has no official archive checksum; validating the executable instead."
        fi

        case "$asset_name" in
            *.tar.gz|*.tgz)
                safe_extract_archive "$archive" "$stage" || continue
                ;;
            *)
                mkdir -p "$stage" || return 1
                CANDIDATE="$stage/AdGuardHome"
                cp "$archive" "$CANDIDATE" || continue
                ;;
        esac

        validate_candidate "$CANDIDATE" "$latest_ver" || {
            CANDIDATE=""
            continue
        }
        compress_candidate "$CANDIDATE" || {
            CANDIDATE=""
            continue
        }
        return 0
    done < "$links_file"

    log "Error: all configured core download links failed validation."
    return 1
}

recover_interrupted_transaction() {
    rollback_core="${binpath}.rollback"
    [ -f "$rollback_core" ] || return 0

    log "Recovering an interrupted core update from $rollback_core."
    should_start=0
    service_should_start && should_start=1

    trap '' HUP INT TERM
    "$SERVICE" stop nobackup >/dev/null 2>&1 || true
    rm -f "$binpath"
    if ! mv "$rollback_core" "$binpath"; then
        trap on_signal HUP INT TERM
        log "Error: failed to restore the rollback core."
        return 1
    fi
    chmod 0755 "$binpath" >/dev/null 2>&1 || true
    [ "$should_start" = "1" ] && "$SERVICE" start >/dev/null 2>&1 || true
    trap on_signal HUP INT TERM
    return 0
}

service_should_start() {
    if "$SERVICE" running main >/dev/null 2>&1; then
        return 0
    fi
    [ "$enabled" = "1" ]
}

wait_for_service() {
    count=0
    stable=0
    while [ "$count" -lt "$START_WAIT" ]; do
        if "$SERVICE" running main >/dev/null 2>&1; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

install_candidate() {
    candidate="$1"
    new_core="${binpath}.new.$$"
    rollback_core="${binpath}.rollback"
    had_old=0
    should_start=0

    service_should_start && should_start=1
    [ -f "$binpath" ] && had_old=1

    rm -f "$new_core"
    cp "$candidate" "$new_core" || {
        log "Error: failed to stage the new core beside $binpath."
        return 1
    }
    chmod 0755 "$new_core" || {
        rm -f "$new_core"
        return 1
    }
    validate_candidate "$new_core" "$latest_ver" || {
        rm -f "$new_core"
        return 1
    }

    log "Installing validated core transactionally..."
    # Ignore termination signals only during the short commit/rollback window.
    trap '' HUP INT TERM
    "$SERVICE" stop nobackup >/dev/null 2>&1 || true

    rm -f "$rollback_core"
    if [ "$had_old" = "1" ]; then
        if ! mv "$binpath" "$rollback_core"; then
            log "Error: failed to preserve the current core for rollback."
            rm -f "$new_core"
            [ "$should_start" = "1" ] && "$SERVICE" start >/dev/null 2>&1
            trap on_signal HUP INT TERM
            return 1
        fi
    fi

    if ! mv "$new_core" "$binpath"; then
        log "Error: failed to activate the staged core; restoring the previous core."
        [ "$had_old" = "1" ] && mv "$rollback_core" "$binpath"
        [ "$should_start" = "1" ] && "$SERVICE" start >/dev/null 2>&1
        trap on_signal HUP INT TERM
        return 1
    fi

    if [ "$should_start" = "1" ]; then
        "$SERVICE" start >/dev/null 2>&1 || true
        if ! wait_for_service; then
            log "Error: new core did not become healthy; attempting rollback."
            "$SERVICE" stop nobackup >/dev/null 2>&1 || true
            if [ "$had_old" = "1" ] && [ -f "$rollback_core" ]; then
                rm -f "$binpath"
                if mv "$rollback_core" "$binpath"; then
                    "$SERVICE" start >/dev/null 2>&1 || true
                    if wait_for_service; then
                        log "Rollback completed; previous core is running."
                    else
                        log "Warning: previous core was restored but did not become healthy."
                    fi
                else
                    log "Error: failed to restore the previous core."
                fi
            else
                log "No previous core is available for rollback; leaving the validated new binary installed with DNS takeover disabled."
            fi
            trap on_signal HUP INT TERM
            return 1
        fi
    fi

    rm -f "$rollback_core"
    trap on_signal HUP INT TERM
    return 0
}

check_and_update() {
    configured_arch="$(uci_get arch)"
    detect_arch "$configured_arch" || return 1
    fetch_latest_version || return 1

    local_ver=""
    if [ -x "$binpath" ]; then
        local_ver="$(get_version "$binpath" 2>/dev/null)"
    fi
    log "Local version: ${local_ver:-not installed}. Latest version: $latest_ver."

    if [ "$local_ver" = "$latest_ver" ] && [ "$1" != "force" ]; then
        log "You're already using the latest version."
        return 0
    fi

    [ -n "$downloadlinks" ] || {
        log "Error: no core download links are configured."
        return 1
    }

    log "Updating AdGuard Home core for architecture $Arch..."
    download_candidate || return 1
    install_candidate "$CANDIDATE" || return 1
    log "Core updated successfully. New version: $latest_ver."
    return 0
}

main() {
    mode="$1"
    case "$mode" in
        ''|force) ;;
        *)
            log "Usage: $0 [force]"
            exit 2
            ;;
    esac

    acquire_lock || exit 2
    trap on_signal HUP INT TERM
    rm -f "$ERROR_MARKER" 2>/dev/null
    cleanup_update_root
    mkdir -p "$UPDATE_ROOT" || {
        log "Error: failed to create update workspace $UPDATE_ROOT."
        finish 1
    }

    load_config || finish 1
    recover_interrupted_transaction || finish 1
    if check_and_update "$mode"; then
        finish 0
    fi
    finish 1
}

if [ "${ADGUARDHOME_UPDATER_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

main "${1:-}"
