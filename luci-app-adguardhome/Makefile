# Copyright (C) 2018-2019 Lienol
# Copyright (C) 2024 rufengsuixing
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_MAINTAINER:=<https://github.com/rufengsuixing/luci-app-adguardhome>

LUCI_TITLE:=LuCI app for AdGuard Home
# Updated Dependencies: Flexible downloader, add xz for upx, core dependency
LUCI_DEPENDS:=+(wget||wget-ssl||curl) +xz +adguardhome
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=LuCI support for AdGuard Home

define Package/luci-app-adguardhome/conffiles
/usr/share/AdGuardHome/links.txt
/etc/config/AdGuardHome
endef

define Package/luci-app-adguardhome/postinst
#!/bin/sh
# Service enable logic remains here, reload moved to uci-defaults
if [ -z "$${IPKG_INSTROOT}" ]; then
    /etc/init.d/AdGuardHome enable >/dev/null 2>&1
fi
# Clear cache remains
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*
exit 0
endef

define Package/luci-app-adguardhome/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
     # Stop and disable service
     /etc/init.d/AdGuardHome disable >/dev/null 2>&1
     /etc/init.d/AdGuardHome stop >/dev/null 2>&1
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