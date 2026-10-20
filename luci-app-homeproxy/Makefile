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
# Record the installed package version so the UI (and any script) can show it
# without relying on parsing the package manager database, which differs
# between opkg- and apk-based images.
mkdir -p "$${IPKG_INSTROOT}/usr/share/homeproxy" 2>/dev/null
echo "$(PKG_VERSION)-$(PKG_RELEASE)" > "$${IPKG_INSTROOT}/usr/share/homeproxy/version" 2>/dev/null
if [ -z "$${IPKG_INSTROOT}" ]; then
	if ! grep -qs '^sing-box:' "$$IPKG_INSTROOT/etc/group" 2>/dev/null && ! grep -qs '^sing-box:' /etc/group 2>/dev/null; then
		addgroup -S sing-box 2>/dev/null || true
	fi
	if ! grep -qs '^sing-box:' "$$IPKG_INSTROOT/etc/passwd" 2>/dev/null && ! grep -qs '^sing-box:' /etc/passwd 2>/dev/null; then
		adduser -S -D -H -G sing-box -s /sbin/nologin sing-box 2>/dev/null || true
	fi
	# /www/cgi-bin/hpapi is a CGI script served by uhttpd. Windows checkouts
	# can lose the executable bit (core.filemode=false) and uhttpd refuses to
	# run a non-executable CGI, which would silently disable the panel's
	# proxy provider page. Re-assert the mode at install time.
	chmod 755 /www/cgi-bin/hpapi 2>/dev/null || true
fi
endef

include $(TOPDIR)/feeds/luci/luci.mk

# ---------------------------------------------------------------------------
# Translations
#
# luci.mk ships translations as a *separate* luci-i18n-<app>-<lang> package,
# so luci-app-homeproxy itself never contains any .lmo and the UI falls back
# to English. This project publishes exactly one architecture-independent
# package, so the Simplified Chinese catalog must end up *inside* the main
# package at the same path the per-language i18n packages install to:
#   /usr/lib/lua/luci/i18n/homeproxy.zh-cn.lmo
#
# IMPORTANT: a `define Build/Compile` hook CANNOT be used for this. luci.mk
# calls `$(eval $(call BuildPackage,...))` on its very last line *during the
# include*, which expands `$(Build/Compile)` / `$(Build/Prepare)` /
# `$(Package/.../install)` at that moment -- before any definition placed
# after the include can take effect (verified against openwrt include/
# package.mk). The .lmo is therefore precompiled into the package's root/
# tree by CI (.github/workflows/build.yml) right before the build, so
# luci.mk's own Build/Prepare copies it into the package. See build.yml.
# ---------------------------------------------------------------------------

# call BuildPackage - OpenWrt buildroot signature
