local luci = require("luci")
local sys = require("luci.sys")
local util = require("luci.util")
local fs = require("nixio.fs")
local uci = require("luci.model.uci").cursor()
local http = require("luci.http")

local m, s, o

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

---- httpport
o = s:option(Value, "httpport", translate("Browser management port"))
o.placeholder = 3000
o.default = 3000
o.datatype = "port"
o.description = translate("<input type=\"button\" style=\"width:210px;border-color:Teal; text-align:center;font-weight:bold;color:Green;\" value=\"AdGuardHome Web:" .. httpport .. "\" onclick=\"window.open('http://'+window.location.hostname+':'.." .. httpport .. "/')\"/>")

---- version check
local function get_version()
    if not fs.access(binpath) then return translate("no core") end
    local ver = sys.exec(binpath .. " --version 2>/dev/null | grep -o 'v[0-9.]*' | head -n1")
    if ver == "" then return translate("unknown") end
    return ver
end

o = s:option(Button, "restart", translate("Update"))
o.inputtitle = translate("Update core version")
o.template = "AdGuardHome/AdGuardHome_check"
o.description = string.format(translate("core version:") .. " <strong><font id=\"updateversion\" color=\"green\">%s</font></strong>", get_version())

---- Redirect
o = s:option(ListValue, "redirect", translate("Redirect"), translate("AdGuardHome redirect mode"))
o.placeholder = "none"
o:value("none", translate("none"))
o:value("dnsmasq-upstream", translate("Run as dnsmasq upstream server"))
o:value("redirect", translate("Redirect 53 port to AdGuardHome"))
o:value("exchange", translate("Use port 53 replace dnsmasq"))
o.default = "none"

---- bin path
o = s:option(Value, "binpath", translate("Bin Path"))
o.default = "/usr/bin/AdGuardHome/AdGuardHome"
o.datatype = "string"

--- upx
o = s:option(ListValue, "upxflag", translate("use upx to compress bin after download"))
o:value("", translate("none"))
o:value("-1", translate("compress faster"))
o:value("-9", translate("compress better"))
o.default = ""
o.description = translate("bin use less space,but may have compatibility issues")

---- config path
o = s:option(Value, "configpath", translate("Config Path"))
o.default = "/etc/AdGuardHome.yaml"
o.datatype = "string"

---- work dir
o = s:option(Value, "workdir", translate("Work dir"))
o.default = "/etc/AdGuardHome"
o.datatype = "string"

---- log file
o = s:option(Value, "logfile", translate("Runtime log file"))
o.default = "/var/log/AdGuardHome.log"
o.datatype = "string"

---- debug
o = s:option(Flag, "verbose", translate("Verbose log"))
o.default = 0

---- GFWList logic
o = s:option(Button, "gfwadd", translate("Add gfwlist"))
o.inputtitle = translate("Add")
o.write = function()
    sys.call("sh /usr/share/AdGuardHome/gfw2adg.sh >/dev/null 2>&1")
    http.redirect(luci.dispatcher.build_url("admin", "services", "AdGuardHome"))
end

o = s:option(Value, "gfwupstream", translate("Gfwlist upstream dns server"))
o.default = "tcp://208.67.220.220:5353"
o.datatype = "string"

---- Upgrade Protect
o = s:option(MultiValue, "upprotect", translate("Keep files when system upgrade"))
o:value("$configpath", translate("config file"))
o:value("$workdir/sessions.db", "sessions.db")
o:value("$workdir/stats.db", "stats.db")
o:value("$workdir/querylog.json", "querylog.json")
o.widget = "checkbox"
o.default = nil

---- Backup
o = s:option(MultiValue, "backupfile", translate("Backup workdir files when shutdown"))
o:value("stats.db", "stats.db")
o:value("querylog.json", "querylog.json")
o.widget = "checkbox"

o = s:option(Value, "backupwdpath", translate("Backup workdir path"))
o.default = "/etc/AdGuardHome/backup"

---- Crontab
o = s:option(MultiValue, "crontab", translate("Crontab task"))
o:value("autoupdate", translate("Auto update core"))
o:value("autohost", translate("Auto update ipv6 hosts"))
o:value("autogfw", translate("Auto update gfwlist"))
o.widget = "checkbox"

---- Download Links
o = s:option(TextValue, "downloadlinks", translate("Download links for update"))
o.rows = 4
o.wrap = "soft"
o.cfgvalue = function(self, section)
    return fs.readfile("/usr/share/AdGuardHome/links.txt") or ""
end
o.write = function(self, section, value)
    fs.writefile("/usr/share/AdGuardHome/links.txt", value:gsub("\r\n", "\n"))
end

-- Clear log position
fs.writefile("/var/run/lucilogpos", "0")

function m.on_commit(map)
    sys.call("/etc/init.d/AdGuardHome reload &")
end

return m