#!/bin/sh

# 启用错误退出
# set -e # 暂时禁用，以便可以检查命令的退出码

log_tailto() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - tailto.sh: $1" >> /tmp/AdGuardHome_init.log
}

# 检查参数数量
if [ "$#" -ne 2 ]; then
    log_tailto "Error: Invalid arguments. Usage: $0 <lines_to_keep> <target_file>"
    exit 1
fi

lines_to_keep="$1"
target_file="$2"

# 验证行数是否为正整数
case "$lines_to_keep" in
    ''|*[!0-9]*)
        log_tailto "Error: <lines_to_keep> ('$lines_to_keep') must be a positive integer."
        exit 1
        ;;
    *)
        if [ "$lines_to_keep" -le 0 ]; then
             log_tailto "Error: <lines_to_keep> ('$lines_to_keep') must be a positive integer."
             exit 1
        fi
        ;;
esac


# 检查目标文件是否存在且可写
if [ ! -f "$target_file" ]; then
    log_tailto "Warning: Target file '$target_file' does not exist. Nothing to do."
    exit 0 # Not necessarily an error if the log file hasn't been created yet
fi
if [ ! -w "$target_file" ]; then
    log_tailto "Error: Target file '$target_file' is not writable."
    exit 1
fi

# 创建安全的临时文件
tmp_file=$(mktemp)
if [ -z "$tmp_file" ] || [ ! -f "$tmp_file" ]; then
    log_tailto "Error: Failed to create temporary file."
    exit 1
fi

# 使用 tail 获取最后 N 行并写入临时文件
if ! tail -n "$lines_to_keep" "$target_file" > "$tmp_file"; then
     log_tailto "Error: tail command failed for '$target_file'."
     rm -f "$tmp_file" # 清理临时文件
     exit 1
fi

# 使用 mv 原子地替换原文件，这比 cat > 更安全
if ! mv "$tmp_file" "$target_file"; then
     log_tailto "Error: Failed to move temporary file to '$target_file'."
     # 尝试清理临时文件，即使 mv 失败
     rm -f "$tmp_file" 2>/dev/null || true
     exit 1
fi

log_tailto "Successfully truncated '$target_file' to last $lines_to_keep lines."
exit 0