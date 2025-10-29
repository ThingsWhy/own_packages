local m, s, o
local fs = require("nixio.fs")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local http = require("luci.http")
local io = require("io")
local table = require("table")
local string = require("string")
local luci = require("luci") -- For dispatcher URL

-- Helper function for pcall results
local function check_pcall(ok, ...)
	if not ok then
		-- print(debug.traceback("pcall failed: " .. tostring(res)))
		return nil, ...
	end
	return true, ...
end

-- Function to generate template config safely
function gen_template_config()
	local d = ""
	-- Use pcall for io.lines
	local ok_lines, lines_iter = check_pcall(io.lines, "/tmp/resolv.conf.auto")
	if ok_lines then
		for cnt in lines_iter do
			local b = string.match(cnt, "^[^#]*nameserver%s+([^%s]+)$")
			if b ~= nil then
				d = d .. "  - " .. b .. "\n"
			end
		end
	else
		-- Handle error reading resolv.conf.auto if necessary
		d = "  # Error reading /tmp/resolv.conf.auto\n"
	end

	local tbl = {}
	-- Use pcall for io.open
	local ok_open, f, err_open = check_pcall(io.open, "/usr/share/AdGuardHome/AdGuardHome_template.yaml", "r")
	if not ok_open then
		return "-- Error opening template file: " .. tostring(err_open) .. " --"
	end

	while true do
		-- Use pcall for f:read
		local ok_read, a = check_pcall(f.read, f, "*l")
		if not ok_read or a == nil then
			break
		end

		if a == "#bootstrap_dns" or a == "#upstream_dns" then
			a = d -- Substitute collected DNS servers
		end
		table.insert(tbl, a)
	end
	-- Use pcall for f:close
	check_pcall(f.close, f)

	return table.concat(tbl, "\n")
end

m = Map("AdGuardHome")
local configpath = uci:get("AdGuardHome", "AdGuardHome", "configpath")
local binpath = uci:get("AdGuardHome", "AdGuardHome", "binpath")

s = m:section(TypedSection, "AdGuardHome")
s.anonymous = true
s.addremove = false

--- config
o = s:option(TextValue, "escconf")
o.rows = 66
o.wrap = "off"
o.rmempty = true
o.cfgvalue = function(self, section)
	-- Read temporary file first if it exists
	local ok_tmp, content_tmp = check_pcall(fs.readfile, "/tmp/AdGuardHometmpconfig.yaml")
	if ok_tmp and content_tmp then return content_tmp end

	-- Read actual config file
	local ok_cfg, content_cfg = check_pcall(fs.readfile, configpath)
	if ok_cfg and content_cfg then return content_cfg end

	-- Fallback to template
	return gen_template_config()
end
o.validate = function(self, value)
	-- Write to temporary file first
	local tmp_config = "/tmp/AdGuardHometmpconfig.yaml"
	local ok_write, err_write = check_pcall(fs.writefile, tmp_config, value:gsub("\r\n", "\n"))
	if not ok_write then
		return nil, translate("Error writing temporary config file:") .. " " .. tostring(err_write)
	end

	-- Check if binary exists before trying to validate
	local bin_exists, _ = check_pcall(fs.access, binpath)
	if not bin_exists then
		-- If binary doesn't exist, skip validation but allow saving
		m.message = (m.message or "") .. "\n" .. translate("WARNING!!! no bin found, config validation skipped.")
		return value
	end

	-- Validate using the binary
	local cmd = string.format("%s -c %s --check-config", util.shellquote(binpath), util.shellquote(tmp_config))
	local ok_call, ret = check_pcall(sys.call, cmd .. " > /tmp/AdGuardHometest.log 2>&1")

	if ok_call and ret == 0 then
		-- Validation successful
		-- Clean up log file?
		pcall(fs.remove, "/tmp/AdGuardHometest.log")
		return value
	else
		-- Validation failed, read the error log
		local ok_read, err_log = check_pcall(fs.readfile, "/tmp/AdGuardHometest.log")
		local err_msg = translate("Config validation failed.")
		if ok_read and err_log then
			err_msg = err_msg .. "\n" .. translate("Error details:") .. "\n" .. err_log
		elseif not ok_call then
			 err_msg = err_msg .. "\n" .. translate("Error executing validation command:") .. " " .. tostring(ret)
		else
			err_msg = err_msg .. "\n" .. translate("Exit code:") .. " " .. tostring(ret) .. ". " .. translate("Check /tmp/AdGuardHometest.log for details.")
		end
		-- Keep the temporary file for editing, return nil to prevent saving invalid config
		return nil, err_msg
		-- The original redirect logic is removed, error is shown in LuCI instead.
		-- luci.http.redirect(luci.dispatcher.build_url("admin","services","AdGuardHome","manual"))
		-- return nil
	end
end
o.write = function(self, section, value)
	-- Move the validated temporary file to the actual config path
	local ok_move, err_move = check_pcall(fs.move, "/tmp/AdGuardHometmpconfig.yaml", configpath)
	if not ok_move then
		m.message = (m.message or "") .. "\n" .. translate("Error saving config file:") .. " " .. tostring(err_move)
	else
		-- Clean up error log on successful save
		pcall(fs.remove, "/tmp/AdGuardHometest.log")
	end
end
o.remove = function(self, section, value)
	-- Safely overwrite with empty content
	local ok_write, err_write = check_pcall(fs.writefile, configpath, "")
	if not ok_write then
		m.message = (m.message or "") .. "\n" .. translate("Error clearing config file:") .. " " .. tostring(err_write)
	end
end

--- js and reload button
o = s:option(DummyValue, "")
o.anonymous = true
o.template = "AdGuardHome/yamleditor"

-- Check binary existence safely
local bin_exists_check, _ = check_pcall(fs.access, binpath)
if not bin_exists_check then
	o.description = translate("WARNING!!! no bin found apply config will not be test")
end

--- Display validation error log if temporary config file exists (meaning validation failed)
local tmp_config_exists, _ = check_pcall(fs.access, "/tmp/AdGuardHometmpconfig.yaml")
if tmp_config_exists then
	local ok_log_read, log_content = check_pcall(fs.readfile, "/tmp/AdGuardHometest.log")
	if ok_log_read and log_content and log_content ~= "" then
		o = s:option(TextValue, "")
		o.readonly = true
		o.rows = 5
		o.rmempty = true
		o.name = "" -- No label
		o.cfgvalue = function(self, section)
			return log_content
		end
	end
end

-- on_commit logic with pcall for safety
function m.on_commit(map)
	local ucitracktest = uci:get("AdGuardHome", "AdGuardHome", "ucitracktest")
	if ucitracktest == "1" then
		return
	elseif ucitracktest == "0" then
		check_pcall(io.popen, "/etc/init.d/AdGuardHome reload &")
	else
		-- Original logic to interact with ucitracktest flag
		check_pcall(fs.writefile, "/var/run/AdGlucitest", "")
	end
end

return m