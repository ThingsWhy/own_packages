local m, s, o
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"
local json = require "luci.jsonc"
-- 修复：移除 require "luci"，引入 dispatcher
local dispatcher = require "luci.dispatcher"

function gen_template_config()
	local configpath = uci:get("AdGuardHome", "AdGuardHome", "configpath")
	local templatepath = "/usr/share/AdGuardHome/AdGuardHome_template.yaml"
	if (not configpath) or (not fs.access(templatepath)) then return end
	
	local content = fs.readfile(templatepath) or ""
	
	-- Handle comments for template generation
	content = content:gsub("\n#[^\n]*", "")
	
	-- Handle variables
	local binpath = uci:get("AdGuardHome", "AdGuardHome", "binpath") or "/usr/bin/AdGuardHome/AdGuardHome"
	local workdir = uci:get("AdGuardHome", "AdGuardHome", "workdir") or "/etc/AdGuardHome"
	local httpport = uci:get("AdGuardHome", "AdGuardHome", "httpport") or "3000"
	local dnsport = uci:get("AdGuardHome", "AdGuardHome", "dnsport") or "53"
	
	content = content:gsub("YOUR_BINPATH", binpath)
	content = content:gsub("YOUR_WORKDIR", workdir)
	content = content:gsub("YOUR_HTTP_PORT", httpport)
	content = content:gsub("YOUR_DNS_PORT", dnsport)
	
	return content
end

m = SimpleForm("AdGuardHome", translate("Manual Config"))

-- Config editor
s = m:section(SimpleSection, nil, translate("Edit the config file manually. The format is YAML."))

o = s:option(TextValue, "data")
o.width = "100%"
o.rows = 20
o.wrap = "off"
o.template = "AdGuardHome/yamleditor" -- Custom template for editor

o.cfgvalue = function(self, section)
	local configpath = uci:get("AdGuardHome", "AdGuardHome", "configpath")
	if configpath and fs.access(configpath) then
		return fs.readfile(configpath) or ""
	else
		return ""
	end
end

o.write = function(self, section, value)
	local configpath = uci:get("AdGuardHome", "AdGuardHome", "configpath")
	if configpath then
		value = value:gsub("\r\n?", "\n")
		fs.writefile(configpath, value)
		sys.call("/etc/init.d/AdGuardHome reload >/dev/null 2>&1")
	end
end

-- 修复：使用 dispatcher.build_url
o.description = translate("You can click <a href='" .. dispatcher.build_url("admin", "services", "AdGuardHome", "gettemplateconfig") .. "' target='_blank'>here</a> to generate a template config file.")

function m.on_after_commit(map)
	-- Reload performed in write function
end

return m
