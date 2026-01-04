local luci = require("luci")
local sys = require("luci.sys")
local util = require("luci.util")
local io = require("io")
local fs = require("nixio.fs")
local uci = require("luci.model.uci").cursor()
local http = require("luci.http") -- Added for redirect

local m, s, o, o1

-- Helper function for pcall results
local function check_pcall(ok, ...)
	if not ok then
		-- Log or handle error, e.g., print to stderr for debugging
		-- print(debug.traceback("pcall failed: " .. tostring(res)))
		return nil, ... -- Return nil and the error message/object
	end
	return true, ... -- Return true and results
end

-- Memoize function for caching results within a request
local memo = {}
local function memoize(key, func)
	if memo[key] == nil then
		memo[key] = func() or false -- Store false if function returns nil to avoid re-running
	end
	return memo[key] or nil -- Return nil if stored value was false
end

-- Get config values safely
local configpath = uci:get("AdGuardHome", "AdGuardHome", "configpath") or "/etc/AdGuardHome.yaml"
local binpath = uci:get("AdGuardHome", "AdGuardHome", "binpath") or "/usr/bin/AdGuardHome/AdGuardHome"
local httpport = uci:get("AdGuardHome", "AdGuardHome", "httpport") or "3000"

m = Map("AdGuardHome", "AdGuard Home")
m.description = translate("Free and open source, powerful network-wide ads & trackers blocking DNS server.")
m:section(SimpleSection).template = "AdGuardHome/AdGuardHome_status"

s = m:section(TypedSection, "AdGuardHome")
s.anonymous = true
s.addremove = false

---- enable
o = s:option(Flag, "enabled", translate("Enable"))
o.default = 0
o.optional = false

---- httpport
o = s:option(Value, "httpport", translate("Browser management port"))
o.placeholder = 3000
o.default = 3000
o.datatype = "port"
o.optional = false
o.description = translate("<input type=\"button\" style=\"width:210px;border-color:Teal; text-align:center;font-weight:bold;color:Green;\" value=\"AdGuardHome Web:" .. httpport .. "\" onclick=\"window.open('http://'+window.location.hostname+':'.." .. httpport .. "/')\"/>")

---- version and update status (with caching)
local function get_version_info()
	local binmtime_uci = uci:get("AdGuardHome", "AdGuardHome", "binmtime") or "0"
	local version_uci = uci:get("AdGuardHome", "AdGuardHome", "version")
	local status_text = ""
	local config_exists, _ = check_pcall(fs.access, configpath)
	local bin_exists, _ = check_pcall(fs.access, binpath)

	if not config_exists then
		status_text = status_text .. " " .. translate("no config")
	end

	if not bin_exists then
		status_text = status_text .. " " .. translate("no core")
	else
		local current_mtime_num
		local ok_stat, stat_info = check_pcall(fs.stat, binpath)
		if ok_stat and stat_info and stat_info.mtime then
			current_mtime_num = tonumber(stat_info.mtime)
		end

		if current_mtime_num and (not version_uci or tostring(current_mtime_num) ~= binmtime_uci) then
			-- mtime changed or version not cached, execute binary
			local ok_exec, exec_output = check_pcall(sys.exec, binpath .. " -c /dev/null --check-config 2>&1 | grep -m 1 -E 'v[0-9.]+' -o")
			local current_version = "core error"
			if ok_exec and exec_output and exec_output ~= "" then
				-- Remove trailing newline if present
				current_version = string.match(exec_output, "^(v[0-9.]+)") or "core error"
			end
			-- Update UCI cache
			uci:set("AdGuardHome", "AdGuardHome", "version", current_version)
			uci:set("AdGuardHome", "AdGuardHome", "binmtime", tostring(current_mtime_num))
			uci:commit("AdGuardHome")
			status_text = current_version .. status_text
		elseif version_uci then
			-- Use cached version
			status_text = version_uci .. status_text
		else
			-- Stat failed or version check failed previously
			status_text = (version_uci or "unknown") .. status_text
		end
	end
	return status_text, not config_exists
end

local version_status, show_fast_config = memoize("version_info", get_version_info)

o = s:option(Button, "restart", translate("Update"))
o.inputtitle = translate("Update core version")
o.template = "AdGuardHome/AdGuardHome_check"
o.showfastconfig = show_fast_config
o.description = string.format(translate("core version:") .. "<strong><font id=\"updateversion\" color=\"green\">%s </font></strong>", version_status or "?")

---- Get DNS port from config safely
local function get_dns_port()
	local port_str = "?"
	local ok_access, _ = check_pcall(fs.access, configpath)
	if ok_access then
		-- Use pcall for sys.exec
		local ok_exec, output = check_pcall(sys.exec, "awk '/^dns:/ { in_dns=1 } /^[^[:space:]]/ { if (in_dns) exit } in_dns && /port:/ { gsub(/^[[:space:]]+port:[[:space:]]+/, \"\"); gsub(/[[:space:]]*,?$/, \"\"); print; exit }' " .. configpath)
		if ok_exec and output and output ~= "" then
			-- Remove potential trailing newline and parse as number
			local port_num = tonumber(string.match(output, "^%d+"))
			if port_num then
				port_str = tostring(port_num)
			end
		end
	end
	return port_str
end

local dns_port = memoize("dns_port", get_dns_port)

---- Redirect
o = s:option(ListValue, "redirect", dns_port .. translate("Redirect"), translate("AdGuardHome redirect mode"))
o.placeholder = "none"
o:value("none", translate("none"))
o:value("dnsmasq-upstream", translate("Run as dnsmasq upstream server"))
o:value("redirect", translate("Redirect 53 port to AdGuardHome"))
o:value("exchange", translate("Use port 53 replace dnsmasq"))
o.default = "none"
o.optional = true

---- bin path
o = s:option(Value, "binpath", translate("Bin Path"), translate("AdGuardHome Bin path if no bin will auto download"))
o.default = "/usr/bin/AdGuardHome/AdGuardHome"
o.datatype = "string"
o.optional = false
o.rmempty = false
o.validate = function(self, value)
	if value == "" then return nil, translate("Bin path cannot be empty.") end
	local ok, stat = check_pcall(fs.stat, value)
	if ok and stat and stat.type == "dir" then
		-- Try to remove if it's an empty dir? Or just error out? Error is safer.
		-- fs.rmdir(value) -- Risky
		return nil, translate("Error! Bin path cannot be a directory.")
	end
	-- No need to check for reg file, non-existent is okay (will be downloaded)
	return value
end

--- upx
o = s:option(ListValue, "upxflag", translate("use upx to compress bin after download"))
o:value("", translate("none"))
o:value("-1", translate("compress faster"))
o:value("-9", translate("compress better"))
o:value("--best", translate("compress best(can be slow for big files)"))
o:value("--brute", translate("try all available compression methods & filters [slow]"))
o:value("--ultra-brute", translate("try even more compression variants [very slow]"))
o.default = ""
o.description = translate("bin use less space,but may have compatibility issues")
o.rmempty = true

---- config path
o = s:option(Value, "configpath", translate("Config Path"), translate("AdGuardHome config path"))
o.default = "/etc/AdGuardHome.yaml"
o.datatype = "string"
o.optional = false
o.rmempty = false
o.validate = function(self, value)
	if value == "" then return nil, translate("Config path cannot be empty.") end
	local ok, stat = check_pcall(fs.stat, value)
	if ok and stat and stat.type == "dir" then
		return nil, translate("Error! Config path cannot be a directory.")
	end
	return value
end

---- work dir
o = s:option(Value, "workdir", translate("Work dir"), translate("AdGuardHome work dir include rules,audit log and database"))
o.default = "/usr/bin/AdGuardHome"
o.datatype = "string"
o.optional = false
o.rmempty = false
o.validate = function(self, value)
	if value == "" then return nil, translate("Work dir cannot be empty.") end
	local ok, stat = check_pcall(fs.stat, value)
	if ok and stat and stat.type == "reg" then
		return nil, translate("Error! Work dir cannot be a file.")
	end
	-- Remove trailing slash
	value = value:gsub("/$", "")
	return value
end

---- log file
o = s:option(Value, "logfile", translate("Runtime log file"), translate("AdGuardHome runtime Log file if 'syslog': write to system log;if empty no log"))
o.datatype = "string"
o.rmempty = true
o.validate = function(self, value)
	if value == nil or value == "" or value == "syslog" then return value end -- Allow empty or syslog
	local ok, stat = check_pcall(fs.stat, value)
	if ok and stat and stat.type == "dir" then
		return nil, translate("Error! Log file cannot be a directory.")
	end
	return value
end

---- debug
o = s:option(Flag, "verbose", translate("Verbose log"))
o.default = 0
o.optional = true

---- gfwlist status (check markers in config)
local function check_gfw_status()
	local status = translate("Not added")
	local ok_access, _ = check_pcall(fs.access, configpath)
	if ok_access then
		-- Use pcall for sys.call
		local ok_call, ret = check_pcall(sys.call, "grep -q -m 1 '#programaddstart_gfw' " .. configpath)
		if ok_call and ret == 0 then
			status = translate("Added")
		end
	end
	return status
end

local gfw_status = memoize("gfw_status", check_gfw_status)

o = s:option(Button, "gfwdel", translate("Del gfwlist"), gfw_status)
o.optional = true
o.inputtitle = translate("Del")
o.write = function()
	local ok, res = check_pcall(sys.exec, "sh /usr/share/AdGuardHome/gfw2adg.sh del 2>&1")
	if not ok then m.message = translate("Error deleting GFW list:") .. " " .. tostring(res) end
	http.redirect(luci.dispatcher.build_url("admin", "services", "AdGuardHome"))
end

o = s:option(Button, "gfwadd", translate("Add gfwlist"), gfw_status)
o.optional = true
o.inputtitle = translate("Add")
o.write = function()
	local ok, res = check_pcall(sys.exec, "sh /usr/share/AdGuardHome/gfw2adg.sh 2>&1")
	if not ok then m.message = translate("Error adding GFW list:") .. " " .. tostring(res) end
	http.redirect(luci.dispatcher.build_url("admin", "services", "AdGuardHome"))
end

o = s:option(Value, "gfwupstream", translate("Gfwlist upstream dns server"), translate("Gfwlist domain upstream dns service") .. " (" .. gfw_status .. ")")
o.default = "tcp://208.67.220.220:5353"
o.datatype = "string"
o.optional = true

---- chpass
o = s:option(Value, "hashpass", translate("Change browser management password"), translate("Press load culculate model and culculate finally save/apply"))
o.default = ""
o.datatype = "string"
o.template = "AdGuardHome/AdGuardHome_chpass"
o.optional = true

---- upgrade protect
o = s:option(MultiValue, "upprotect", translate("Keep files when system upgrade"))
o:value("$binpath", translate("core bin"))
o:value("$configpath", translate("config file"))
o:value("$logfile", translate("log file"))
o:value("$workdir/data/sessions.db", translate("sessions.db"))
o:value("$workdir/data/stats.db", translate("stats.db"))
o:value("$workdir/data/querylog.json", translate("querylog.json"))
o:value("$workdir/data/filters", translate("filters"))
o.widget = "checkbox"
o.default = nil
o.optional = true

---- wait net on boot
o = s:option(Flag, "waitonboot", translate("On boot when network ok restart"))
o.default = 1
o.optional = true

---- backup workdir on shutdown
local workdir_current = uci:get("AdGuardHome", "AdGuardHome", "workdir") or "/usr/bin/AdGuardHome"
o = s:option(MultiValue, "backupfile", translate("Backup workdir files when shutdown"))
o1 = s:option(Value, "backupwdpath", translate("Backup workdir path"))
local name

o:value("filters", "filters")
o:value("stats.db", "stats.db")
o:value("querylog.json", "querylog.json")
o:value("sessions.db", "sessions.db")
o1:depends("backupfile", "filters")
o1:depends("backupfile", "stats.db")
o1:depends("backupfile", "querylog.json")
o1:depends("backupfile", "sessions.db")

-- Safely list files in workdir/data
local ok_glob, files = check_pcall(fs.glob, workdir_current .. "/data/*")
if ok_glob and files then
	for _, fullpath in ipairs(files) do
		local name_base = fs.basename(fullpath)
		if name_base ~= "filters" and name_base ~= "stats.db" and name_base ~= "querylog.json" and name_base ~= "sessions.db" then
			o:value(name_base, name_base)
			o1:depends("backupfile", name_base)
		end
	end
end

o.widget = "checkbox"
o.default = nil
o.optional = false -- Changed from true in original, assuming backup path dependency makes it effectively required if backupfile has value
o.description = translate("Will be restore when workdir/data is empty")

---- backup workdir path
o1.default = "/usr/bin/AdGuardHome" -- Default backup path
o1.datatype = "string"
o1.optional = false
o1.validate = function(self, value)
	if value == "" then return nil, translate("Backup path cannot be empty.") end
	local ok, stat = check_pcall(fs.stat, value)
	if ok and stat and stat.type == "reg" then
		return nil, translate("Error! Backup path cannot be a file.")
	end
	-- Remove trailing slash
	value = value:gsub("/$", "")
	return value
end

---- Crontab
o = s:option(MultiValue, "crontab", translate("Crontab task"), translate("Please change time and args in crontab"))
o:value("autoupdate", translate("Auto update core"))
o:value("cutquerylog", translate("Auto tail querylog"))
o:value("cutruntimelog", translate("Auto tail runtime log"))
o:value("autohost", translate("Auto update ipv6 hosts and restart adh"))
o:value("autogfw", translate("Auto update gfwlist and restart adh"))
o.widget = "checkbox"
o.default = nil
o.optional = true

---- downloadpath
o = s:option(TextValue, "downloadlinks", translate("Download links for update"))
o.optional = false
o.rows = 4
o.wrap = "soft"
o.cfgvalue = function(self, section)
	local ok, content = check_pcall(fs.readfile, "/usr/share/AdGuardHome/links.txt")
	return (ok and content) or "-- Error reading links file --"
end
o.write = function(self, section, value)
	local ok, err = check_pcall(fs.writefile, "/usr/share/AdGuardHome/links.txt", value:gsub("\r\n", "\n"))
	if not ok then m.message = (m.message or "") .. "\n" .. translate("Error writing download links:") .. " " .. tostring(err) end
end

-- Clear log position indicator on page load
check_pcall(fs.writefile, "/var/run/lucilogpos", "0")

-- Simplified on_commit logic with error handling
function m.on_commit(map)
	-- This complex logic involving ucitracktest and /var/run/AdGlucitest
	-- seems to be a workaround for how LuCI handles service reloads/restarts
	-- after UCI commits, possibly to prevent multiple reloads.
	-- It's kept here for compatibility but could potentially be simplified
	-- if the underlying LuCI behavior is better understood or changed.
	local ok_dis, _ = check_pcall(fs.access, "/var/run/AdGserverdis")
	if ok_dis then
		check_pcall(io.popen, "/etc/init.d/AdGuardHome reload &")
		return
	end

	local ucitracktest = uci:get("AdGuardHome", "AdGuardHome", "ucitracktest")

	if ucitracktest == "1" then
		return -- Skip reload
	elseif ucitracktest == "0" then
		check_pcall(io.popen, "/etc/init.d/AdGuardHome reload &") -- Force reload
	else
		-- The toggle logic using /var/run/AdGlucitest
		local ok_test, _ = check_pcall(fs.access, "/var/run/AdGlucitest")
		if ok_test then
			-- File exists, means second commit/apply cycle? Force reload and reset flag.
			uci:set("AdGuardHome", "AdGuardHome", "ucitracktest", "0")
			check_pcall(io.popen, "/etc/init.d/AdGuardHome reload &")
		else
			-- File doesn't exist, first commit/apply? Write file and toggle flag.
			check_pcall(fs.writefile, "/var/run/AdGlucitest", "")
			if ucitracktest == "2" then
				uci:set("AdGuardHome", "AdGuardHome", "ucitracktest", "1")
			else
				uci:set("AdGuardHome", "AdGuardHome", "ucitracktest", "2")
			end
		end
		uci:commit("AdGuardHome")
	end
end

return m