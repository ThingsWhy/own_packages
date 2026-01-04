module("luci.controller.AdGuardHome", package.seeall)

local http = require "luci.http"
local agh = require "luci.model.adguardhome"
local fs = require "nixio.fs"

function index()
	entry({"admin", "services", "AdGuardHome"}, alias("admin", "services", "AdGuardHome", "base"), _("AdGuard Home"), 10).dependent = true
	entry({"admin", "services", "AdGuardHome", "base"}, cbi("AdGuardHome/base"), _("Base Setting"), 1).leaf = true
	entry({"admin", "services", "AdGuardHome", "log"}, form("AdGuardHome/log"), _("Log"), 2).leaf = true
	entry({"admin", "services", "AdGuardHome", "manual"}, cbi("AdGuardHome/manual"), _("Manual Config"), 3).leaf = true
	
	-- API Endpoints
	entry({"admin", "services", "AdGuardHome", "status"}, call("act_status")).leaf = true
	entry({"admin", "services", "AdGuardHome", "check_update"}, call("act_check_update"))
	entry({"admin", "services", "AdGuardHome", "do_update"}, call("act_do_update"))
	entry({"admin", "services", "AdGuardHome", "poll_log"}, call("act_poll_update_log"))
	entry({"admin", "services", "AdGuardHome", "get_log"}, call("act_get_log"))
	entry({"admin", "services", "AdGuardHome", "truncate_log"}, call("act_truncate_log"))
	entry({"admin", "services", "AdGuardHome", "template"}, call("act_get_template"))
end

function act_status()
	local running = (luci.sys.call("pgrep -f " .. agh.get_bin_path() .. " >/dev/null") == 0)
	local redir = (fs.readfile("/var/run/AdGredir") == "1")
	local version = agh.get_current_version()
	
	http.prepare_content("application/json")
	http.write_json({
		running = running,
		redirect = redir,
		version = version
	})
end

-- 检查更新 (前端点击"检查更新"时调用)
function act_check_update()
	local update_info, err = agh.check_update()
	local current_ver = agh.get_current_version()
	
	http.prepare_content("application/json")
	if not update_info then
		http.write_json({ error = err })
	else
		http.write_json({
			current = current_ver,
			latest = update_info.version,
			updatable = (update_info.version ~= current_ver)
		})
	end
end

-- 执行更新 (前端点击"更新"时调用)
function act_do_update()
	local force = (http.formvalue("force") == "1")
	
	-- 重置更新日志
	fs.writefile("/tmp/AdGuardHome_update.log", "Starting update process...\n")
	fs.writefile("/var/run/lucilogpos", "0")
	
	-- 获取架构
	local arch = agh.get_arch()
	local update_info, err = agh.check_update()
	
	if not update_info and not force then
		http.write_json({ error = "Check failed: " .. (err or "unknown") })
		return
	end
	
	local target_version = update_info and update_info.version or "latest"
	-- 构造下载链接 (使用 ghproxy 或直接链接)
	local url = string.format("https://github.com/AdguardTeam/AdGuardHome/releases/download/%s/AdGuardHome_linux_%s.tar.gz", target_version, arch)
	-- 可选：使用 ghproxy
	-- url = "https://mirror.ghproxy.com/" .. url
	
	agh.do_update(url, target_version, force)
	
	http.prepare_content("application/json")
	http.write_json({ status = "started" })
end

-- 轮询更新日志
function act_poll_update_log()
	local log_path = "/tmp/AdGuardHome_update.log"
	local pos = tonumber(http.formvalue("pos")) or 0
	
	if not fs.access(log_path) then
		http.write("")
		return
	end
	
	local f = io.open(log_path, "r")
	if f then
		f:seek("set", pos)
		local content = f:read("*a")
		local new_pos = f:seek()
		f:close()
		
		http.prepare_content("application/json")
		http.write_json({
			log = content,
			pos = new_pos,
			done = (content:match("Update failed") or content:match("Update completed")) and true or false
		})
	else
		http.write("")
	end
end

-- 获取运行日志
function act_get_log()
	local pos = tonumber(http.formvalue("pos")) or 0
	local content, new_pos = agh.get_log_data(pos)
	
	http.prepare_content("application/json")
	http.write_json({
		log = content,
		pos = new_pos
	})
end

-- 清空日志
function act_truncate_log()
	local logfile = agh.get_config("AdGuardHome", "logfile")
	if logfile and logfile ~= "syslog" and fs.access(logfile) then
		fs.writefile(logfile, "")
	end
	http.prepare_content("application/json")
	http.write_json({ status = "ok" })
end

-- 获取配置模板
function act_get_template()
	local tmpl_path = "/usr/share/AdGuardHome/AdGuardHome_template.yaml"
	local content = fs.readfile(tmpl_path) or ""
	
	-- 简单的 resolv.conf 注入
	local resolv = fs.readfile("/tmp/resolv.conf.auto") or ""
	local dns_list = ""
	for ip in resolv:gmatch("nameserver%s+([%w:%.]+)") do
		dns_list = dns_list .. "  - " .. ip .. "\n"
	end
	
	if dns_list ~= "" then
		content = content:gsub("#bootstrap_dns", dns_list):gsub("#upstream_dns", dns_list)
	end
	
	http.prepare_content("text/plain")
	http.write(content)
end