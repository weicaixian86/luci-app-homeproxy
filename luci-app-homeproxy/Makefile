# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-homeproxy
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

LUCI_TITLE:=Sing-box proxy management platform for OpenWrt
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+firewall4 \
	+dnsmasq-full \
	+ip \
	+kmod-tun \
	+kmod-nft-tproxy \
	+ca-bundle \
	+curl \
	+jsonfilter \
	+unzip \
	+ucode-mod-digest \
	+ucode-mod-fs \
	+ucode-mod-math \
	+ucode-mod-ubus \
	+ucode-mod-uci

define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
endef

# HomeProxy no longer bundles a single-architecture sing-box binary. The reF1nd
# sing-box core is downloaded at runtime by root/etc/homeproxy/scripts/update_core.sh
# according to the device architecture, then installed to /usr/bin/sing-box. We
# therefore create the dedicated sing-box system user/group here (previously
# provided by the OpenWrt sing-box package) so the ujail jail can run the core
# under the sing-box account.
define Package/luci-app-homeproxy/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if ! grep -qs '^sing-box:' "$$IPKG_INSTROOT/etc/group" 2>/dev/null && ! grep -qs '^sing-box:' /etc/group 2>/dev/null; then
		addgroup -S sing-box 2>/dev/null || true
	fi
	if ! grep -qs '^sing-box:' "$$IPKG_INSTROOT/etc/passwd" 2>/dev/null && ! grep -qs '^sing-box:' /etc/passwd 2>/dev/null; then
		adduser -S -D -H -G sing-box -s /sbin/nologin sing-box 2>/dev/null || true
	fi
fi
endef

include $(TOPDIR)/feeds/luci/luci.mk

# ---------------------------------------------------------------------------
# Translations
#
# luci.mk ships translations as a *separate* luci-i18n-<app>-<lang> package,
# which means luci-app-homeproxy itself never contains any .lmo and the UI
# falls back to English. This project intentionally publishes exactly one
# architecture-independent package, so compile the Simplified Chinese catalog
# straight into the main package, at the same path the per-language i18n
# packages install to.
# ---------------------------------------------------------------------------
define Build/Compile
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/lib/lua/luci/i18n
	po2lmo $(CURDIR)/po/zh_Hans/homeproxy.po \
		$(PKG_BUILD_DIR)/root/usr/lib/lua/luci/i18n/homeproxy.zh-cn.lmo
endef

# call BuildPackage - OpenWrt buildroot signature
