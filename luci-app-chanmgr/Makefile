# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for chanmgr (Wi-Fi channel manager)
# In access point mode the router reaches this device through /ubus
# (uhttpd-mod-ubus), which the usual LuCI installation (luci-light) brings.
LUCI_DEPENDS:=+luci-base +chanmgr
LUCI_PKGARCH:=all

PKG_MAINTAINER:=Lucas <lucascbdias@gmail.com>
PKG_LICENSE:=GPL-2.0-only

# inside openwrt/luci: ../../luci.mk; as part of this repository's own feed:
# the luci feed of the build tree
include $(firstword $(wildcard ../../luci.mk) $(TOPDIR)/feeds/luci/luci.mk)

# call BuildPackage - OpenWrt buildroot signature
