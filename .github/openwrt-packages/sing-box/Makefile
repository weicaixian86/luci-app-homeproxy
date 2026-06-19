# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=sing-box
PKG_VERSION:=1.13.13
PKG_RELEASE:=1

PKG_SOURCE:=sing-box-$(PKG_VERSION)-linux-amd64.tar.gz
PKG_SOURCE_URL:=https://github.com/SagerNet/sing-box/releases/download/v$(PKG_VERSION)
PKG_HASH:=skip
PKG_BUILD_DIR:=$(BUILD_DIR)/sing-box-$(PKG_VERSION)-linux-amd64

include $(INCLUDE_DIR)/package.mk

define Package/sing-box
  SECTION:=net
  CATEGORY:=Network
  TITLE:=The universal proxy platform
  URL:=https://github.com/SagerNet/sing-box
  DEPENDS:=+ca-bundle
endef

define Package/sing-box/description
  sing-box $(PKG_VERSION) binary package for x86_64 OpenWrt.
endef

define Build/Compile
endef

define Package/sing-box/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/sing-box $(1)/usr/bin/sing-box
endef

$(eval $(call BuildPackage,sing-box))
