module("luci.model.adguardhome", package.seeall)

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local json = require "luci.jsonc"
local util = require "luci.util"

-- 常量定义
local CONFIG_FILE = "/etc/config/AdGuardHome"
local DEFAULT_BIN_PATH = "/usr/bin/AdGuardHome/AdGuardHome"
local UPDATE_LOG_PATH = "/tmp/AdGuardHome_update.log"

-- 获取配置项辅助函数
function get_config(section, option, default)
	return uci:get("AdGuardHome", section, option) or default
end

-- 获取 AdGuardHome 二进制路径
function get_bin_path()
	return get_config("AdGuardHome", "binpath", DEFAULT_BIN_PATH)
end

-- 获取 AdGuardHome 配置文件路径
function get_yaml_path()
	return get_config("AdGuardHome", "configpath", "/etc/AdGuardHome.yaml")
end

-- 简单高效的 YAML 值读取 (只读)
-- 替代了 cumbersome 的 awk/sed 脚本
function yaml_get_value(key)
	local yaml_path = get_yaml_path()
	if not fs.access(yaml_path) then return nil end
	
	-- 将 key (e.g. "dns.port") 拆分为部分
	local parts = util.split(key, ".")
	local current_indent = -1
	local target_depth = #parts
	local current_depth = 0
	
	local f = io.open(yaml_path, "r")
	if not f then return nil end

	local val = nil
	for line in f:lines() do
		-- 跳过注释和空行
		if not line:match("^%s*#") and not line:match("^%s*$") then
			local indent = #(line:match("^(%s*)") or "")
			local k, v = line:match("^%s*([%w_%-]+):%s*(.*)")
			
			if k then
				-- 简单的层级推断：如果缩进比上一行大，深度+1；小则减
				-- 这里简化处理：假设标准 YAML 格式 (2空格缩进)
				local depth = math.floor(indent / 2) + 1
				
				if depth == current_depth + 1 then
					if k == parts[depth] then
						current_depth = depth
						if current_depth == target_depth then
							val = util.trim(v)
							break
						end
					end
				elseif depth <= current_depth then
					-- 回退到对应深度
					current_depth = depth
					if k == parts[depth] then
						if current_depth == target_depth then
							val = util.trim(v)
							break
						end
					else
						-- 路径不匹配，重置
						if depth == 1 and k ~= parts[1] then current_depth = 0 end
					end
				end
			end
		end
	end
	f:close()
	return val
end

-- 获取当前运行版本
function get_current_version()
	local binpath = get_bin_path()
	if not fs.access(binpath) then return "0.0.0" end
	
	-- 缓存机制：检查 mtime，如果没变则使用缓存
	local mtime = fs.stat(binpath, "mtime")
	local cached_mtime = get_config("AdGuardHome", "binmtime")
	local cached_version = get_config("AdGuardHome", "version")
	
	if tostring(mtime) == cached_mtime and cached_version then
		return cached_version
	end

	-- 执行二进制获取版本
	-- 限制输出长度防止卡死
	local cmd = string.format("%s --version 2>/dev/null", binpath)
	local output = sys.exec(cmd)
	local ver = output:match("version ([v0-9%.]+)") or "unknown"
	
	-- 更新缓存
	if ver ~= "unknown" then
		uci:set("AdGuardHome", "AdGuardHome", "version", ver)
		uci:set("AdGuardHome", "AdGuardHome", "binmtime", tostring(mtime))
		uci:save("AdGuardHome")
		uci:commit("AdGuardHome")
	end
	
	return ver
end

-- 获取系统架构映射
function get_arch()
	local arch = sys.exec("uname -m"):gsub("\n", "")
	local map = {
		x86_64 = "amd64",
		i386 = "386",
		i686 = "386",
		aarch64 = "arm64",
		armv7l = "armv7",
		armv6l = "armv6",
		mips = "mips",
		mipsel = "mipsle",
		mips64 = "mips64",
		mips64el = "mips64le"
	}
	-- 针对软路由常见架构的模糊匹配
	if arch:match("^armv7") then return "armv7" end
	if arch:match("^armv6") then return "armv6" end
	if arch:match("^armv5") then return "armv5" end
	
	return map[arch] or arch
end

-- 检查更新 (Lua 实现，替代 Shell)
function check_update()
	local api_url = "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
	local content
	
	-- 优先使用 wget-ssl 或 uclient-fetch (如果支持 HTTPS)
	-- 为了兼容性，使用 exec 获取 JSON
	if fs.access("/usr/bin/wget-ssl") or fs.access("/usr/bin/wget") then
		content = sys.exec("wget -qO- --no-check-certificate " .. api_url)
	elseif fs.access("/bin/uclient-fetch") then
		content = sys.exec("uclient-fetch -q -O - --no-check-certificate " .. api_url)
	else
		return nil, "No downloader found"
	end

	if not content or content == "" then
		return nil, "Network error or API rate limit"
	end

	local json_data = json.parse(content)
	if not json_data or not json_data.tag_name then
		return nil, "Invalid JSON response"
	end

	return {
		version = json_data.tag_name,
		body = json_data.body,
		prerelease = json_data.prerelease
	}
end

-- 启动更新过程
function do_update(url, version, force)
	local script = "/usr/share/AdGuardHome/update_core.sh"
	local binpath = get_bin_path()
	local upxflag = get_config("AdGuardHome", "upxflag", "")
	
	-- 构造参数
	local args = string.format("'%s' '%s' '%s' '%s'", 
		url or "", 
		version or "", 
		binpath,
		upxflag
	)
	
	-- 异步执行，日志输出到 UPDATE_LOG_PATH
	sys.exec(string.format("/bin/sh %s %s > %s 2>&1 &", script, args, UPDATE_LOG_PATH))
end

-- 读取日志 (支持 syslog 和 文件)
function get_log_data(pos)
	local logfile = get_config("AdGuardHome", "logfile")
	local limit = 2048000 -- 2MB limit
	pos = tonumber(pos) or 0
	
	if logfile == "syslog" then
		-- 使用 logread 读取
		-- 注意：logread 不支持 seek，所以对于 syslog 我们通常只返回最后的 N 行
		-- 或者如果实现了 watchdog 临时文件模式 (Phase 1 废弃了 getsyslog.sh)，这里直接读系统日志
		-- 简单起见，返回最近的 500 行 AdGuardHome 日志
		return sys.exec("logread -e AdGuardHome | tail -n 500"), 0
	elseif logfile and logfile ~= "" and fs.access(logfile) then
		local f = io.open(logfile, "r")
		if not f then return "Error opening log file", 0 end
		
		local flen = f:seek("end")
		if pos > flen then pos = 0 end -- Log rotated
		
		f:seek("set", pos)
		local data = f:read(limit)
		local new_pos = f:seek()
		f:close()
		return data or "", new_pos
	else
		return "", 0
	end
end