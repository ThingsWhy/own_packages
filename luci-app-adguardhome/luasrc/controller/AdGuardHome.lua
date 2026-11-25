module("luci.controller.AdGuardHome",package.seeall)
local fs=require"nixio.fs"
local http=require"luci.http"
local uci=require"luci.model.uci".cursor()

local function updater_running()
	local raw=fs.readfile("/var/run/AdGuardHome-update.lock/pid") or ""
	local pid=tonumber(raw:match("(%d+)"))
	if not pid then
		return false
	end
	local cmdline=fs.readfile("/proc/"..pid.."/cmdline") or ""
	return cmdline:find("update_core.sh",1,true) ~= nil
end

function index()
entry({"admin", "services", "AdGuardHome"},alias("admin", "services", "AdGuardHome", "base"),_("AdGuard Home"), 10).dependent = true
entry({"admin","services","AdGuardHome","base"},cbi("AdGuardHome/base"),_("Plugin Settings"),1).leaf = true
entry({"admin","services","AdGuardHome","log"},form("AdGuardHome/log"),_("Log"),2).leaf = true
entry({"admin","services","AdGuardHome","manual"},cbi("AdGuardHome/manual"),_("Manual Config"),3).leaf = true
entry({"admin","services","AdGuardHome","status"},call("act_status")).leaf=true
entry({"admin", "services", "AdGuardHome", "check"}, call("check_update"))
entry({"admin", "services", "AdGuardHome", "doupdate"}, call("do_update"))
entry({"admin", "services", "AdGuardHome", "getlog"}, call("get_log"))
entry({"admin", "services", "AdGuardHome", "dodellog"}, call("do_dellog"))
entry({"admin", "services", "AdGuardHome", "reloadconfig"}, call("reload_config"))
end 
function reload_config()
	fs.remove("/tmp/AdGuardHometmpconfig.yaml")
	http.prepare_content("application/json")
	http.write("{}")
end
function act_status()
	local e={}
	local binpath=uci:get("AdGuardHome","AdGuardHome","binpath") or "/usr/bin/AdGuardHome/AdGuardHome"
	local configpath=uci:get("AdGuardHome","AdGuardHome","configpath") or "/etc/AdGuardHome.yaml"
	local config_size=fs.stat(configpath,"size") or 0
	e.core=fs.access(binpath) and true or false
	e.initialized=config_size > 0
	e.running=e.core and luci.sys.call("/etc/init.d/AdGuardHome running main >/dev/null 2>&1")==0 or false
	e.redirect=(fs.readfile("/var/run/AdG_redir")=="1")
	http.prepare_content("application/json")
	http.write_json(e)
end
function do_update()
	local arg
	if luci.http.formvalue("force") == "1" then
		arg="force"
	else
		arg=""
	end
	-- The updater owns concurrency through an atomic lock. Never kill an
	-- in-flight transaction from the LuCI request path.
	if not updater_running() then
		local cmd="/usr/share/AdGuardHome/update_core.sh"
		if arg=="force" then
			cmd=cmd.." force"
		end
		luci.sys.exec(cmd.." >/tmp/AdGuardHome_update.log 2>&1 &")
	end
	http.prepare_content("application/json")
	http.write("{}")
end
function get_log()
	http.prepare_content("application/json")
	local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
	if (logfile==nil) then
		http.write_json({ pos = 0, content = "" })
		return
	elseif (logfile=="syslog") then
		if not fs.access("/var/run/AdG_syslog") then
			luci.sys.exec("(/usr/share/AdGuardHome/getsyslog.sh &); sleep 1;")
		end
		logfile="/tmp/AdGuardHome.log"
		fs.writefile("/var/run/AdG_syslog","1")
	elseif not fs.access(logfile) then
		http.write_json({ pos = 0, content = "" })
		return
	end
	-- support client-managed position via ?pos=
	local pos = tonumber(luci.http.formvalue("pos")) or 0
	local f = io.open(logfile, "r")
	local content = ""
	local newpos = pos
	if f then
		f:seek("set", pos)
		content = f:read(1048576) or ""
		newpos = f:seek()
		f:close()
	end
	http.write_json({ pos = newpos, content = content })
end
function do_dellog()
	local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
	fs.writefile(logfile,"")
	http.prepare_content("application/json")
	http.write("{}")
end
function check_update()
	-- Now supports client-managed position: accepts `pos` param and returns JSON
	local pos = tonumber(luci.http.formvalue("pos")) or 0
	local fpath = "/tmp/AdGuardHome_update.log"
	local content = ""
	local newpos = pos
	if fs.access(fpath) then
		local f = io.open(fpath, "r")
		if f then
			f:seek("set", pos)
			content = f:read(1048576) or ""
			newpos = f:seek()
			f:close()
		end
	end

	local running = updater_running()
	local status
	if running then
		status = "running"
	elseif fs.access("/var/run/AdG_update_error") then
		status = "failed"
	else
		status = "succeeded"
	end

	http.prepare_content("application/json")
	http.write_json({ pos = newpos, content = content, status = status })
end
