# Copyright (C) 2018-2019 Lienol
# Copyright (C) 2024 rufengsuixing
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=1.8
PKG_RELEASE:=1

PKG_MAINTAINER:=<https://github.com/rufengsuixing/luci-app-adguardhome>

LUCI_TITLE:=LuCI app for AdGuard Home
# Dependencies Updated:
# - luci-lib-jsonc: Required for JSON parsing in Lua backend
# - uclient-fetch: Lightweight downloader (standard in OpenWrt)
# - xz: Required for UPX decompression
LUCI_DEPENDS:=+luci-lib-jsonc +uclient-fetch +xz
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=LuCI support for AdGuard Home

define Package/luci-app-adguardhome/conffiles
/usr/share/AdGuardHome/links.txt
/etc/config/AdGuardHome
endef

define Package/luci-app-adguardhome/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Ensure execution permissions for scripts
	chmod +x /usr/share/AdGuardHome/update_core.sh
	chmod +x /usr/share/AdGuardHome/firewall.include
	chmod +x /usr/share/AdGuardHome/gfw2adg.sh
	chmod +x /etc/init.d/AdGuardHome

	# Clear LuCI cache
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*
fi
exit 0
endef

define Package/luci-app-adguardhome/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Stop and disable service
	/etc/init.d/AdGuardHome disable >/dev/null 2>&1
	/etc/init.d/AdGuardHome stop >/dev/null 2>&1

	# Clean up firewall include registration
	uci -q delete firewall.adguardhome_include
	uci -q commit firewall

	# Clean up ucitrack entry
	uci -q batch <<-EOF >/dev/null 2>&1
		delete ucitrack.@AdGuardHome[-1]
		commit ucitrack
	EOF
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
