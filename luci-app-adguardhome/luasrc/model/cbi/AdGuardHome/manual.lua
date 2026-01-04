local m, s, o
local fs = require("nixio.fs")
local agh = require("luci.model.adguardhome")
local sys = require("luci.sys")

m = Map("AdGuardHome")
local configpath = agh.get_yaml_path()
local binpath = agh.get_bin_path()

s = m:section(TypedSection, "AdGuardHome")
s.anonymous = true
s.addremove = false

--- Config Editor
o = s:option(TextValue, "manual_config")
o.rows = 30
o.wrap = "off"
o.description = translate("Edit AdGuardHome.yaml manually. 'Use Template' will overwrite current content.")

o.cfgvalue = function(self, section)
	return fs.readfile(configpath) or ""
end

o.validate = function(self, value)
	local tmp_file = "/tmp/AdGuardHome_check.yaml"
	fs.writefile(tmp_file, value:gsub("\r\n", "\n"))

	if fs.access(binpath) then
		local ret = sys.call(string.format("'%s' -c '%s' --check-config >/dev/null 2>&1", binpath, tmp_file))
		if ret ~= 0 then
			return nil, translate("Config validation failed! Check syntax.")
		end
	end
	
	fs.remove(tmp_file)
	return value
end

o.write = function(self, section, value)
	fs.writefile(configpath, value:gsub("\r\n", "\n"))
end

--- Template Button (Implemented in JS in View, logic in Controller)
o = s:option(DummyValue, "template_btn")
o.template = "AdGuardHome/yamleditor" -- We'll keep the view, it's mostly JS

return m