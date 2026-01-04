local agh = require "luci.model.adguardhome"
local fs = require "nixio.fs"

local m, s, o

m = Map("AdGuardHome", translate("AdGuard Home"))
m.description = translate("Free and open source, powerful network-wide ads & trackers blocking DNS server.")
m:section(SimpleSection).template = "AdGuardHome/AdGuardHome_status"

s = m:section(TypedSection, "AdGuardHome")
s.anonymous = true
s.addremove = false

---- Enabled
o = s:option(Flag, "enabled", translate("Enable"))
o.default = 0

---- HTTP Port
local httpport = agh.get_config("AdGuardHome", "httpport", "3000")
o = s:option(Value, "httpport", translate("Browser management port"))
o.default = 3000
o.datatype = "port"
o.description = translate("Click to open: ") .. string.format("<a href=\"http://%s:%s\" target=\"_blank\">http://%s:%s</a>", 
	luci.http.getenv("SERVER_NAME"), httpport, luci.http.getenv("SERVER_NAME"), httpport)

---- Version Info
local version = agh.get_current_version()
local config_status = fs.access(agh.get_yaml_path()) and "" or translate("(No Config)")
local bin_status = fs.access(agh.get_bin_path()) and "" or translate("(No Core)")

o = s:option(Button, "check_update", translate("Update"))
o.inputtitle = translate("Check Update")
o.template = "AdGuardHome/AdGuardHome_check" -- 我们将在 Phase 3 优化这个 View
o.description = string.format("%s: <b>%s</b> %s %s", translate("Core Version"), version, config_status, bin_status)

---- Redirect Mode
local yaml_port = agh.yaml_get_value("dns.port") or "?"
o = s:option(ListValue, "redirect", translate("Redirect Mode"))
o.description = translate("AdGuardHome DNS Port in Config: ") .. yaml_port
o:value("none", translate("None"))
o:value("dnsmasq-upstream", translate("As Dnsmasq Upstream"))
o:value("redirect", translate("Redirect (Firewall)"))
o:value("exchange", translate("Replace Dnsmasq (Port 53)"))
o.default = "none"

---- Paths
o = s:option(Value, "binpath", translate("Bin Path"))
o.default = "/usr/bin/AdGuardHome/AdGuardHome"
o.datatype = "string"

o = s:option(Value, "configpath", translate("Config Path"))
o.default = "/etc/AdGuardHome.yaml"
o.datatype = "string"

o = s:option(Value, "workdir", translate("Work Dir"))
o.default = "/usr/bin/AdGuardHome"
o.datatype = "string"

o = s:option(Value, "logfile", translate("Log File"))
o.default = "/var/log/AdGuardHome.log"
o.description = translate("Path to log file or 'syslog'")

---- Toggles
o = s:option(Flag, "verbose", translate("Verbose Log"))
o.default = 0

o = s:option(Flag, "waitonboot", translate("Wait for Network on Boot"))
o.default = 1

---- Backup (Simplified)
o = s:option(MultiValue, "upprotect", translate("Keep files during sysupgrade"))
o:value("$binpath", translate("Core Binary"))
o:value("$configpath", translate("Config File"))
o:value("$workdir/data/sessions.db", "sessions.db")
o:value("$workdir/data/stats.db", "stats.db")
o.widget = "checkbox"
o.default = nil

---- Helper Scripts (GFW)
o = s:option(Button, "gfw_manage", translate("GFW List"))
o.inputtitle = translate("Update GFW List")
o.write = function()
	luci.sys.call("/usr/share/AdGuardHome/gfw2adg.sh >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "AdGuardHome"))
end

---- Download Links
o = s:option(TextValue, "downloadlinks", translate("Download Links"))
o.rows = 3
o.cfgvalue = function(self, section)
	return fs.readfile("/usr/share/AdGuardHome/links.txt") or ""
end
o.write = function(self, section, value)
	fs.writefile("/usr/share/AdGuardHome/links.txt", value:gsub("\r\n", "\n"))
end

-- On Commit: Simple Reload
function m.on_commit(map)
	-- Phase 1's init.d script handles config changes via Procd triggers.
	-- But to be safe and responsive, we can trigger a reload.
	luci.sys.call("/etc/init.d/AdGuardHome reload >/dev/null 2>&1")
end

return m