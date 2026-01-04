module("luci.controller.AdGuardHome", package.seeall)

local fs = require("nixio.fs")
local http = require("luci.http")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local io = require("io")
local table = require("table")
local string = require("string")
local util = require("luci.util")

-- Helper function for pcall results
local function check_pcall(ok, ...)
	if not ok then
		return nil, ...
	end
	return true, ...
end

function index()
	entry({"admin", "services", "AdGuardHome"}, alias("admin", "services", "AdGuardHome", "base"), _("AdGuard Home"), 10).dependent = true
	entry({"admin", "services", "AdGuardHome", "base"}, cbi("AdGuardHome/base"), _("Base Setting"), 1).leaf = true
	entry({"admin", "services", "AdGuardHome", "log"}, form("AdGuardHome/log"), _("Log"), 2).leaf = true
	entry({"admin", "services", "AdGuardHome", "manual"}, cbi("AdGuardHome/manual"), _("Manual Config"), 3).leaf = true
	entry({"admin", "services", "AdGuardHome", "status"}, call("act_status")).leaf = true
	entry({"admin", "services", "AdGuardHome", "check"}, call("check_update"))
	entry({"admin", "services", "AdGuardHome", "doupdate"}, call("do_update"))
	entry({"admin", "services", "AdGuardHome", "getlog"}, call("get_log"))
	entry({"admin", "services", "AdGuardHome", "dodellog"}, call("do_dellog"))
	entry({"admin", "services", "AdGuardHome", "reloadconfig"}, call("reload_config"))
	entry({"admin", "services", "AdGuardHome", "gettemplateconfig"}, call("get_template_config"))
end

function get_template_config()
	local ok, template_content = check_pcall(loadfile("/usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua"))
	if ok and template_content and template_content().gen_template_config then
		local ok_gen, content = check_pcall(template_content().gen_template_config)
		if ok_gen then
			http.prepare_content("text/plain; charset=utf-8")
			http.write(content or "-- Error generating template --")
		else
			http.prepare_content("text/plain; charset=utf-8")
			http.write("-- Error executing gen_template_config: " .. tostring(content) .. " --")
		end
	else
		http.prepare_content("text/plain; charset=utf-8")
		http.write("-- Error loading or finding gen_template_config function --")
	end
end

function reload_config()
	local ok, err = check_pcall(fs.remove, "/tmp/AdGuardHometmpconfig.yaml")
	http.prepare_content("application/json")
	-- 修复：返回空 JSON 对象 '{}' 而非空字符串，防止前端 JSON.parse 失败
	http.write('{}')
end

function act_status()
	local e = {}
	local binpath = uci:get("AdGuardHome", "AdGuardHome", "binpath") or "/usr/bin/AdGuardHome/AdGuardHome"
	local cmd = string.format("pgrep -f ^%s", util.shellquote(binpath))
	local ok_call, ret = check_pcall(sys.call, cmd .. " >/dev/null")
	e.running = (ok_call and ret == 0)

	local ok_read, redirect_status = check_pcall(fs.readfile, "/var/run/AdGredir")
	e.redirect = (ok_read and redirect_status == "1")

	http.prepare_content("application/json")
	http.write_json(e)
end

function do_update()
	check_pcall(fs.writefile, "/var/run/lucilogpos", "0")

	http.prepare_content("application/json")
	-- 修复：返回空 JSON 对象 '{}'
	http.write('{}')

	local arg = ""
	if http.formvalue("force") == "1" then
		arg = "force"
	end

	local update_script = "/usr/share/AdGuardHome/update_core.sh"
	local log_file = "/tmp/AdGuardHome_update.log"
	local cmd = string.format("sh %s %s > %s 2>&1",
		util.shellquote(update_script),
		util.shellquote(arg),
		util.shellquote(log_file)
	)

	local ok_access_run, _ = check_pcall(fs.access, "/var/run/update_core")
	if ok_access_run then
		if arg == "force" then
			local kill_cmd = string.format("pkill -f %s", util.shellquote(update_script))
			check_pcall(sys.call, kill_cmd .. " ; " .. cmd .. " &")
		end
	else
		check_pcall(sys.exec_background, cmd)
	end
end

function get_log()
	local logfile_uci = uci:get("AdGuardHome", "AdGuardHome", "logfile")
	local logfile_path = nil
	local is_syslog = false

	if not logfile_uci or logfile_uci == "" then
		http.prepare_content("text/plain; charset=utf-8")
		http.write("AdGuardHome log file path is not configured.\n")
		return
	elseif logfile_uci == "syslog" then
		is_syslog = true
		logfile_path = "/tmp/AdGuardHometmp.log"
		local watchdog_file = "/var/run/AdGuardHomesyslog"
		local pid_file = "/var/run/AdGuardHome_getsyslog.pid"
		local syslog_script = "/usr/share/AdGuardHome/getsyslog.sh"

		local pid = nil
		local ok_read_pid, pid_content = check_pcall(fs.readfile, pid_file)
		if ok_read_pid and pid_content then pid = tonumber(pid_content) end

		local process_running = false
		if pid then
			local ok_call, ret = check_pcall(sys.call, "kill -0 " .. pid .. " >/dev/null 2>&1")
			process_running = (ok_call and ret == 0)
		end

		if not process_running then
			check_pcall(sys.exec_background, string.format("(%s &)", util.shellquote(syslog_script)))
			sys.exec("sleep 1")
		end
		check_pcall(fs.writefile, watchdog_file, "1")
	else
		logfile_path = logfile_uci
	end

	local ok_access, _ = check_pcall(fs.access, logfile_path)
	if not ok_access then
		http.prepare_content("text/plain; charset=utf-8")
		if is_syslog then
			http.write("-- Waiting for syslog data... --\n")
		else
			http.write("-- Log file not found: " .. logfile_path .. " --\n")
		end
		return
	end

	http.prepare_content("text/plain; charset=utf-8")
	local fdp = 0
	local ok_reload, _ = check_pcall(fs.access, "/var/run/lucilogreload")
	if ok_reload then
		check_pcall(fs.remove, "/var/run/lucilogreload")
	else
		local ok_readpos, pos_content = check_pcall(fs.readfile, "/var/run/lucilogpos")
		if ok_readpos and pos_content then fdp = tonumber(pos_content) or 0 end
	end

	local content = ""
	local ok_open, f, err_open = check_pcall(io.open, logfile_path, "r")
	if ok_open then
		local ok_seek1, seek_res1 = check_pcall(f.seek, f, "set", fdp)
		if ok_seek1 then
			local ok_read, read_content = check_pcall(f.read, f, 2048000)
			if ok_read then content = read_content or "" end

			local ok_seek2, current_pos = check_pcall(f.seek, f)
			if ok_seek2 and current_pos then
				check_pcall(fs.writefile, "/var/run/lucilogpos", tostring(current_pos))
			end
		end
		check_pcall(f.close, f)
		http.write(content)
	else
		http.write("-- Error opening log file: " .. tostring(err_open) .. " --\n")
		check_pcall(fs.writefile, "/var/run/lucilogpos", "0")
	end
end

function do_dellog()
	local logfile = uci:get("AdGuardHome", "AdGuardHome", "logfile")
	if logfile and logfile ~= "" and logfile ~= "syslog" then
		check_pcall(fs.writefile, logfile, "")
	elseif logfile == "syslog" then
		check_pcall(fs.writefile, "/tmp/AdGuardHometmp.log", "")
		check_pcall(fs.writefile, "/var/run/lucilogpos", "0")
	end
	http.prepare_content("application/json")
	-- 修复：返回空 JSON 对象 '{}'
	http.write('{}')
end

function check_update()
	http.prepare_content("text/plain; charset=utf-8")
	local log_path = "/tmp/AdGuardHome_update.log"
	local content = ""
	local fdp = 0

	local ok_readpos, pos_content = check_pcall(fs.readfile, "/var/run/lucilogpos")
	if ok_readpos and pos_content then fdp = tonumber(pos_content) or 0 end

	local ok_open, f, err_open = check_pcall(io.open, log_path, "r")
	if ok_open then
		local ok_seek1, _ = check_pcall(f.seek, f, "set", fdp)
		if ok_seek1 then
			local ok_read, read_content = check_pcall(f.read, f, 2048000)
			if ok_read then content = read_content or "" end

			local ok_seek2, current_pos = check_pcall(f.seek, f)
			if ok_seek2 and current_pos then
				check_pcall(fs.writefile, "/var/run/lucilogpos", tostring(current_pos))
			end
		end
		check_pcall(f.close, f)
	end

	local ok_access_run, _ = check_pcall(fs.access, "/var/run/update_core")
	if ok_access_run then
		http.write(content)
	else
		http.write(content .. "\0")
	end
end
