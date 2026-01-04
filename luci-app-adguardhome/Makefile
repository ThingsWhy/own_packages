# Copyright (C) 2018-2024 Lienol <https://github.com/Lienol>
# Copyright (C) 2024 rufengsuixing <https://github.com/rufengsuixing>

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=1.8
PKG_RELEASE:=1

PKG_MAINTAINER:=<https://github.com/rufengsuixing/luci-app-adguardhome>
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI app for AdGuard Home
# 依赖：curl(下载), ca-bundle(HTTPS), xz-utils(UPX), luci-compat(CBI兼容)
LUCI_DEPENDS:=+curl +ca-bundle +xz-utils +luci-compat
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=LuCI support for AdGuard Home

# 确保配置文件和数据目录在固件升级时保留
define Package/luci-app-adguardhome/conffiles
/etc/config/AdGuardHome
/etc/AdGuardHome.yaml
/etc/AdGuardHome/
endef

# 显式定义安装过程，确保脚本拥有执行权限
define Package/luci-app-adguardhome/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci
	$(CP) ./luasrc/* $(1)/usr/lib/lua/luci/
	$(INSTALL_DIR) $(1)/
	$(CP) ./root/* $(1)/
	# 显式赋予脚本执行权限
	$(INSTALL_DIR) $(1)/usr/share/AdGuardHome
	$(INSTALL_BIN) ./root/usr/share/AdGuardHome/*.sh $(1)/usr/share/AdGuardHome/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature