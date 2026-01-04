#!/bin/bash
# Using bash for potential improvements like [[ ]]

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# 启用错误退出
set -e
# 使用陷阱确保清理
trap 'cleanup_exit 1' SIGINT SIGTERM SIGHUP

# --- 全局变量 ---
binpath=""
upxflag=""
downloader=""
latest_ver=""
now_ver=""
Arch="" # Architecture for download/upx
tmp_dir=""

# --- 函数定义 ---

log_update() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - update_core.sh: $1" # 直接输出到 stdout/stderr (重定向到日志文件)
}

# 统一退出处理
cleanup_exit() {
    local exit_code=${1:-1} # Default exit code is 1 (error)
    log_update "Exiting (code: $exit_code)..."
    rm -f /var/run/update_core 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
         touch /var/run/update_core_error 2>/dev/null || true
         log_update "Error flag set at /var/run/update_core_error"
    else
         rm -f /var/run/update_core_error 2>/dev/null || true
    fi
    # 清理临时目录
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
        log_update "Cleaning up temporary directory: $tmp_dir"
        rm -rf "$tmp_dir"
    fi
    exit "$exit_code"
}

# 检查命令是否存在
check_command() {
    command -v "$1" >/dev/null 2>&1 || { log_update "Error: command '$1' not found."; cleanup_exit 1; }
}


check_if_already_running() {
    sleep 1 # Wait briefly in case multiple instances started simultaneously
    # Use pgrep -f to match the script name more reliably
    local running_pids
    running_pids=$(pgrep -f "/usr/share/AdGuardHome/update_core.sh")
    local current_pid=$$
    local count=0
    for pid in $running_pids; do
        [ "$pid" != "$current_pid" ] && count=$((count + 1))
    done

    if [ "$count" -gt 0 ]; then
        log_update "Another update task is already running (PIDs: $(echo "$running_pids" | grep -v "$current_pid")). Exiting."
        cleanup_exit 2 # Use different exit code for "already running"
    fi
     log_update "No other update tasks found running."
}

check_downloader() {
    if command -v curl >/dev/null 2>&1; then
        downloader="curl -fsSL --retry 2 --connect-timeout 20 -o" # -fsSL for silent fail, follow redirects
        log_update "Using curl as downloader."
        return 0
    elif command -v wget-ssl >/dev/null 2>&1; then
        downloader="wget-ssl --no-check-certificate -t 2 -T 20 -qO" # -q for quiet, O for output file
        log_update "Using wget-ssl as downloader."
        return 0
    elif command -v wget >/dev/null 2>&1; then
         downloader="wget --no-check-certificate -t 2 -T 20 -qO" # Try standard wget
         log_update "Using wget as downloader."
         return 0
    else
        log_update "Error: No suitable downloader (curl, wget-ssl, wget) found."
        # Attempt to install curl as a last resort? This requires opkg and might fail.
        # log_update "Attempting to install curl via opkg..."
        # if opkg update && opkg install curl; then
        #     log_update "curl installed successfully."
        #     check_downloader # Retry check
        #     return $?
        # else
        #     log_update "Failed to install curl."
        #     return 1
        # fi
        return 1
    fi
}

get_architecture() {
    local arch_raw arch_final
    # Use uname -m as primary source, fallback to opkg info
    if command -v uname >/dev/null 2>&1; then
        arch_raw=$(uname -m)
        log_update "System architecture (uname -m): $arch_raw"
    else
        log_update "uname not found, trying opkg info kernel..."
        arch_raw=$(opkg info kernel | grep Architecture | awk -F '[ _]' '{print $2}')
        log_update "System architecture (opkg info kernel): $arch_raw"
    fi


    case "$arch_raw" in
        i386 | i686)          arch_final="386" ;;
        x86_64 | amd64)       arch_final="amd64" ;;
        mipsel | mipsle)      arch_final="mipsle" ;; # AGH uses mipsle
        mips64el | mips64le)  arch_final="mipsle" ; log_update "Warning: mips64el mapped to $arch_final, may have issues." ;;
        mips)                 arch_final="mips" ;;
        mips64)               arch_final="mips" ; log_update "Warning: mips64 mapped to $arch_final, may have issues." ;;
        armv5*|armv6*|armv7*) arch_final="arm" ;; # Basic ARM detection, might need v6/v7 specifics? AGH uses armvX
        aarch64 | arm64)      arch_final="arm64" ;;
        # Add other architectures if needed (ppc, etc.) - check AGH release names
        *) log_update "Error: Unsupported architecture '$arch_raw'"; return 1 ;;
    esac
    Arch="$arch_final" # Set global Arch variable
    log_update "Mapped architecture for AdGuardHome: $Arch"
    return 0
}


check_latest_version() {
    local force_update=0
    [ "$1" = "force" ] && force_update=1

    if ! check_downloader; then cleanup_exit 1; fi
    if ! get_architecture; then cleanup_exit 1; fi

    log_update "Checking latest AdGuardHome version from GitHub API..."
    # Use downloader variable, handle potential errors
    local api_url="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
    local api_output latest_ver_raw
    api_output=$(eval "$downloader" - "$api_url" 2>/dev/null) # Use '-' for stdout
    if [ $? -ne 0 ] || [ -z "$api_output" ]; then
         log_update "Error fetching latest version info from $api_url. Please check network or API status."
         cleanup_exit 1
    fi
    latest_ver_raw=$(echo "$api_output" | grep -oE '"tag_name":\s*"v[0-9.]+"' | grep -oE 'v[0-9.]+')

    if [ -z "$latest_ver_raw" ]; then
        log_update "Failed to parse latest version from GitHub API response."
        cleanup_exit 1
    fi
    latest_ver="$latest_ver_raw"
    log_update "Latest version found: ${latest_ver}"

    # Get current version
    if [ -f "$binpath" ]; then
        # Ensure the binary is executable
        chmod +x "$binpath" 2>/dev/null || true
        # Run check-config, capture output carefully
        local version_output
        # shellcheck disable=SC2001 # Sed is simpler here than parameter expansion
        version_output=$("$binpath" --version 2>&1 | sed -n 's/AdGuard Home, version \(v[0-9.]\+\).*/\1/p')
        # Fallback to check-config method if --version failed
        if [ -z "$version_output" ]; then
             version_output=$("$binpath" -c /dev/null --check-config 2>&1 | grep -m 1 -oE 'v[0-9.]+')
        fi

        if [ -n "$version_output" ]; then
            now_ver="$version_output"
            log_update "Current local version: ${now_ver}"
        else
            log_update "Warning: Could not determine local version from binary '$binpath'."
            now_ver="unknown" # Set to unknown if version check fails
             force_update=1 # Force update if current version is unknown
        fi
    else
        log_update "Local binary not found at '$binpath'. Update required."
        now_ver="none"
         force_update=1 # Force update if binary doesn't exist
    fi


    # Compare versions
    if [ "$force_update" -eq 1 ] || [ "${latest_ver}" != "${now_ver}" ]; then
        log_update "Update required (Force: $force_update, Latest: ${latest_ver}, Current: ${now_ver})."
        doupdate_core
    else
        log_update "Local version (${now_ver}) is up-to-date (${latest_ver})."
        # Check if UPX compression is needed even if version is current
        check_and_apply_upx # Call separate function for UPX logic
        cleanup_exit 0 # Exit successfully
    fi
}

check_and_apply_upx() {
     # Only proceed if upxflag is set
    [ -z "$upxflag" ] && return 0

    log_update "Checking if UPX compression is needed/possible..."
    if ! command -v upx >/dev/null 2>&1; then
         log_update "UPX command not found. Attempting to download..."
         if ! download_upx; then
              log_update "Failed to download UPX. Skipping compression."
              return 1
         fi
         # Assume download_upx places upx in $tmp_dir/upx_install/upx
         local upx_cmd="$tmp_dir/upx_install/upx"
         if [ ! -x "$upx_cmd" ]; then
              log_update "UPX downloaded but not found or not executable. Skipping compression."
              return 1
         fi
    else
         local upx_cmd="upx"
         log_update "UPX command found in PATH."
    fi

    local filesize
    filesize=$(stat -c%s "$binpath" 2>/dev/null || wc -c < "$binpath" 2>/dev/null) || filesize=0

    # Define a threshold (e.g., > 8MB) below which we assume it might already be compressed enough
    # Or, more reliably, try to check if it's *already* UPX compressed (difficult without running upx -t)
    # Let's use the simple size threshold for now
    if [ "$filesize" -lt 8000000 ]; then
        log_update "Binary size ($filesize bytes) is below threshold. Assuming already compressed or small. Skipping UPX."
        return 0
    fi

    log_update "Binary size ($filesize bytes) is above threshold. Attempting UPX compression (Flag: $upxflag)..."
    log_update "This may take a long time..."

    local compressed_bin_path="${tmp_dir}/AdGuardHome_compressed"

    # Run UPX
    if "$upx_cmd" "$upxflag" "$binpath" -o "$compressed_bin_path"; then
         log_update "UPX compression successful."
         local compressed_size
         compressed_size=$(stat -c%s "$compressed_bin_path")
         log_update "Original size: $filesize, Compressed size: $compressed_size"

         log_update "Replacing binary with compressed version..."
         # Stop service before replacing binary
         if ! /etc/init.d/AdGuardHome stop nobackup; then log_update "Warning: Failed to stop AdGuardHome before replacing binary."; fi
         # Replace binary
         if mv -f "$compressed_bin_path" "$binpath"; then
              chmod +x "$binpath"
              log_update "Binary replaced successfully."
         else
              log_update "Error: Failed to replace binary with compressed version."
              # Try to start service with old binary?
         fi
         # Start service again
         if ! /etc/init.d/AdGuardHome start; then log_update "Error: Failed to start AdGuardHome after UPX compression."; fi
    else
         log_update "Error: UPX compression failed."
         rm -f "$compressed_bin_path" 2>/dev/null || true # Clean up failed output
    fi

    # Clean up downloaded UPX if applicable
    [ "$upx_cmd" != "upx" ] && rm -rf "$tmp_dir/upx_install" 2>/dev/null || true

}


download_upx() {
    log_update "Downloading UPX..."
    # Reuse get_architecture if not already called
    [ -z "$Arch" ] && ! get_architecture && return 1

    local upx_arch="$Arch" # Map internal Arch to UPX arch names if needed
    case "$Arch" in
       "386")    upx_arch="i386" ;;
       "mipsle") upx_arch="mipsel" ;;
       # Add other mappings if AGH arch names differ from UPX release names
    esac

    local upx_api_url="https://api.github.com/repos/upx/upx/releases/latest"
    local upx_api_output upx_latest_ver upx_download_url

    log_update "Fetching latest UPX version..."
    upx_api_output=$(eval "$downloader" - "$upx_api_url" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$upx_api_output" ]; then
        log_update "Error fetching UPX release info."
        return 1
    fi
    upx_latest_ver=$(echo "$upx_api_output" | grep -oE '"tag_name":\s*"v[0-9.]+"' | grep -oE '[0-9.]+')
    if [ -z "$upx_latest_ver" ]; then
        log_update "Failed to parse UPX version."
        return 1
    fi
    log_update "Latest UPX version: v$upx_latest_ver"

    # Construct download URL (assuming standard naming convention)
    local upx_filename="upx-${upx_latest_ver}-${upx_arch}_linux.tar.xz"
    upx_download_url="https://github.com/upx/upx/releases/download/v${upx_latest_ver}/${upx_filename}"
    local upx_archive_path="${tmp_dir}/${upx_filename}"
    local upx_extract_path="${tmp_dir}/upx_install"

    log_update "Downloading UPX from: $upx_download_url"
    if ! eval "$downloader" "\"$upx_archive_path\"" "\"$upx_download_url\""; then
         log_update "Error downloading UPX."
         return 1
    fi
    log_update "UPX downloaded successfully."

    # Extract UPX
    check_command xz
    check_command tar
    log_update "Extracting UPX..."
    mkdir -p "$upx_extract_path" || { log_update "Error creating UPX extract directory."; return 1; }
    # Use xz -d -c to decompress to stdout, pipe to tar
    if xz -d -c "$upx_archive_path" | tar -xf - -C "$upx_extract_path" --strip-components=1; then
         # --strip-components=1 assumes archive contains a single top-level dir like upx-3.96-amd64_linux/
         log_update "UPX extracted successfully."
         rm -f "$upx_archive_path" # Clean up archive
         # Check if upx executable exists
         if [ -f "$upx_extract_path/upx" ]; then
             chmod +x "$upx_extract_path/upx"
             log_update "UPX executable found at $upx_extract_path/upx"
             return 0
         else
             log_update "Error: UPX executable not found after extraction."
             return 1
         fi
    else
         log_update "Error extracting UPX archive."
         rm -f "$upx_archive_path" 2>/dev/null || true # Clean up archive
         return 1
    fi
}

doupdate_core() {
    log_update "Starting core update process..."
    # Ensure architecture is determined
    [ -z "$Arch" ] && ! get_architecture && cleanup_exit 1

    # Prepare temporary download directory
    # Handled by tmp_dir creation in main

    local download_successful=0
    local download_target=""
    local final_bin_source="" # Path to the extracted/downloaded binary

    # Read download links and try each one
    local links_file="/usr/share/AdGuardHome/links.txt"
    if [ ! -f "$links_file" ]; then
        log_update "Error: Download links file not found at '$links_file'."
        cleanup_exit 1
    fi

    log_update "Reading download links from '$links_file'..."
    # Use process substitution and handle comments/empty lines
    while IFS= read -r link || [ -n "$link" ]; do
         # Skip comments and empty lines
         case "$link" in
             \#* | "") continue ;;
         esac

         # Substitute variables in the link (Arch, latest_ver)
         # Using eval is risky, consider safer alternatives if possible (e.g., sed)
         # Sticking with eval for now as per original script's potential intent
         local eval_link
         eval eval_link=\"$link\" # Need eval twice potentially if link contains ${latest_ver} etc.

         local filename="${eval_link##*/}"
         download_target="${tmp_dir}/${filename}"

         log_update "Attempting download from: $eval_link"
         if eval "$downloader" "\"$download_target\"" "\"$eval_link\""; then
             log_update "Download successful: $filename"
             download_successful=1
             break # Exit loop on first successful download
         else
             log_update "Download failed from: $eval_link. Trying next link..."
             rm -f "$download_target" 2>/dev/null || true # Clean up failed download
         fi
    done < <(grep -v -E '^\s*#|^\s*$' "$links_file") # Read file skipping comments/blanks

    if [ "$download_successful" -eq 0 ]; then
        log_update "Error: All download links failed."
        cleanup_exit 1
    fi

    # Extract if necessary (tar.gz)
    log_update "Processing downloaded file: $download_target"
    if [[ "$download_target" == *.tar.gz ]]; then
        check_command tar
        log_update "Extracting tar.gz archive..."
        local extract_dir="${tmp_dir}/extract"
        mkdir -p "$extract_dir" || { log_update "Error creating extract directory."; cleanup_exit 1; }
        # Extract, assuming structure AdGuardHome/AdGuardHome inside
        if tar -zxf "$download_target" -C "$extract_dir"; then
             # Try finding the binary, accommodate different structures potentially
             final_bin_source=$(find "$extract_dir" -name AdGuardHome -type f -executable -print -quit)
             if [ -z "$final_bin_source" ] || [ ! -f "$final_bin_source" ]; then
                  log_update "Error: AdGuardHome binary not found after extraction from tar.gz."
                  cleanup_exit 1
             fi
             log_update "Binary extracted to: $final_bin_source"
        else
             log_update "Error extracting tar.gz archive."
             cleanup_exit 1
        fi
    elif [[ "$download_target" == *.zip ]]; then # Add zip support if needed
         log_update "Error: ZIP archives not currently supported."
         cleanup_exit 1
    else
        # Assume it's the binary itself
        log_update "Assuming downloaded file is the binary."
        final_bin_source="$download_target"
    fi

    # Make executable
    chmod +x "$final_bin_source" || { log_update "Error setting executable permission."; cleanup_exit 1; }
    log_update "Binary permissions set."

    # Apply UPX if requested
    if [ -n "$upxflag" ]; then
        log_update "Applying UPX compression (Flag: $upxflag)..."
        log_update "This may take a long time..."
        local upx_cmd="upx"
        if ! command -v upx >/dev/null 2>&1; then
             log_update "UPX not found, attempting download..."
              if download_upx; then
                   upx_cmd="$tmp_dir/upx_install/upx"
              else
                   log_update "UPX download failed, skipping compression."
                   upx_cmd="" # Prevent UPX attempt
              fi
        fi

        if [ -n "$upx_cmd" ] && [ -x "$upx_cmd" ]; then
             if "$upx_cmd" "$upxflag" "$final_bin_source"; then
                 log_update "UPX compression successful."
             else
                 log_update "Warning: UPX compression failed. Using uncompressed binary."
             fi
             # Clean up downloaded UPX if applicable
            [ "$upx_cmd" != "upx" ] && rm -rf "$tmp_dir/upx_install" 2>/dev/null || true
        fi
    fi


    # Replace the old binary
    log_update "Replacing old binary with the new version..."
    if ! /etc/init.d/AdGuardHome stop nobackup; then log_update "Warning: Failed to stop AdGuardHome before replacing binary."; fi

    # Use mv -f to replace
    if mv -f "$final_bin_source" "$binpath"; then
        log_update "Binary replaced successfully."
    else
        log_update "Error: Failed to move new binary to '$binpath'."
        log_update "Check permissions and available space."
        # Try to restart the old service? Or just exit?
        /etc/init.d/AdGuardHome start || log_update "Error restarting AdGuardHome after failed update."
        cleanup_exit 1
    fi

    # Start the service with the new binary
    log_update "Starting AdGuardHome with the new binary..."
    if ! /etc/init.d/AdGuardHome start; then
        log_update "Error: Failed to start AdGuardHome after update."
        # Optionally try to restore a backup if available? Complex.
        cleanup_exit 1
    fi

    # Clean up temporary directory (done by trap)
    log_update "Update process completed successfully."
    log_update "Current version is now: ${latest_ver}"
    cleanup_exit 0
}

# --- Main Execution ---

main() {
    log_update "Update script started."
    touch /var/run/update_core 2>/dev/null || true # Signal script is running

    # Create temporary directory
    tmp_dir=$(mktemp -d) || { log_update "Error creating temporary directory."; exit 1; }
     log_update "Temporary directory created: $tmp_dir"

    # Get binpath from UCI
    binpath=$(uci -q get AdGuardHome.AdGuardHome.binpath)
    if [ -z "$binpath" ]; then
        log_update "binpath not set in UCI, using default /usr/bin/AdGuardHome and saving to UCI."
        binpath="/usr/bin/AdGuardHome"
        uci set AdGuardHome.AdGuardHome.binpath="$binpath"
        uci commit AdGuardHome
    fi
     log_update "Target binary path: $binpath"

    # Get UPX flag
    upxflag=$(uci -q get AdGuardHome.AdGuardHome.upxflag) || upxflag=""
     log_update "UPX flag: ${upxflag:-<not set>}"

    # Ensure parent directory for binary exists
    mkdir -p "$(dirname "$binpath")" || { log_update "Error creating directory for binary: $(dirname "$binpath")"; cleanup_exit 1; }

    check_if_already_running
    check_latest_version "$1" # Pass "force" argument if provided
}

# Call main function with command line arguments
main "$@"

# Cleanup will be handled by the trap