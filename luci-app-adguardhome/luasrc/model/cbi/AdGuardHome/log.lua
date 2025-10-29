local fs = require("nixio.fs")
local uci = require("luci.model.uci").cursor()
local util = require("luci.util") -- For pcall wrapper if needed

local f, t

f = SimpleForm("logview")
f.reset = false
f.submit = false

t = f:field(TextValue, "conf")
t.rmempty = true
t.rows = 20
t.template = "AdGuardHome/log"
t.readonly = "readonly"

local logfile = uci:get("AdGuardHome", "AdGuardHome", "logfile") or ""
t.timereplace = (logfile ~= "syslog" and logfile ~= "")
t.pollcheck = (logfile ~= "")

-- Safely write the file using pcall
local ok, err = pcall(fs.writefile, "/var/run/lucilogreload", "")
if not ok then
	-- Optionally log the error, but don't prevent page load
	-- print("Error writing /var/run/lucilogreload: " .. tostring(err))
end

return f