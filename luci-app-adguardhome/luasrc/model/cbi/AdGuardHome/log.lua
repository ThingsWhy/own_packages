local m, s, o
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local json = require "luci.jsonc"
-- 修复：移除 require "luci"，引入 dispatcher
local dispatcher = require "luci.dispatcher"

m = SimpleForm("AdGuardHome", translate("Log"))
m.submit = false
m.reset = false

-- Log View
s = m:section(SimpleSection)
s.template = "AdGuardHome/log"

-- We can pass some variables to the template if needed
-- For example, the URL to fetch logs
-- 修复：使用 dispatcher.build_url
s.poll_url = dispatcher.build_url("admin", "services", "AdGuardHome", "getlog")
s.del_url = dispatcher.build_url("admin", "services", "AdGuardHome", "dodellog")

return m
