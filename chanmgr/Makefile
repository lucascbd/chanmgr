# SPDX-License-Identifier: GPL-2.0-only
#
# chanmgr built straight from this repository, which can be used as an
# OpenWrt feed:
#   src-git chanmgr https://github.com/lucascbd/luci-app-chanmgr.git
# For the openwrt/packages feed see openwrt/net/chanmgr/Makefile.upstream.

include $(TOPDIR)/rules.mk

PKG_NAME:=chanmgr
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Lucas <lucascbdias@gmail.com>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

# the sources are the files/ tree next to this directory
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../files $(CURDIR)/../LICENSE $(PKG_BUILD_DIR)/
endef

define Package/chanmgr
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WirelessAPD
  TITLE:=Periodic Wi-Fi channel optimizer
  URL:=https://github.com/lucascbd/luci-app-chanmgr
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci \
	+rpcd +rpcd-mod-ucode +iw +uclient-fetch
  PKGARCH:=all
endef

define Package/chanmgr/description
  Periodically measures Wi-Fi channel congestion (passive survey sampling
  plus scheduled off-channel scans) and moves radios to the least
  congested channels using channel switch announcements, without
  disconnecting clients. Several access points can be planned jointly
  from one controller, so they also avoid each other. Runs in
  recommend-only mode by default.
endef

define Package/chanmgr/conffiles
/etc/config/chanmgr
endef

define Build/Compile
endef

define Package/chanmgr/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/usr/sbin/chanmgr $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/share/ucode/chanmgr
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/usr/share/ucode/chanmgr/*.uc $(1)/usr/share/ucode/chanmgr/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/usr/share/rpcd/ucode/chanmgr.uc $(1)/usr/share/rpcd/ucode/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/usr/share/rpcd/acl.d/chanmgr-agent.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/files/etc/config/chanmgr $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/etc/init.d/chanmgr $(1)/etc/init.d/
endef

define Package/chanmgr/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd reload
exit 0
endef

$(eval $(call BuildPackage,chanmgr))
