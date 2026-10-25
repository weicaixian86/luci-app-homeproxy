# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-homeproxy
# 占位版本号：正式发布由 CI（.github/workflows/build-deploy.yml）在编译前把
# PKG_VERSION 改写成本次填写的发布版本（如 0.1.17）。本地 make 得到 0.0.0-1，
# 一眼就能看出是本地构建，也不会和真实发布版本混淆。
PKG_VERSION:=0.0.0
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

# Only files that are actually shipped by this package and that a user may
# edit belong here. The previous list also named /etc/homeproxy/certs/,
# /etc/homeproxy/ruleset/, resources/direct_list.txt and
# resources/proxy_list.txt:
#   - the two directories are created at service start (init.d does mkdir -p),
#     so they are not part of the package and opkg/apk silently ignored the
#     entries;
#   - the two list files are no longer shipped (superseded by the geodata
#     lists), so the entries were dead as well.
# Keeping only real paths means a stale entry can never fail a conffile
# integrity check, and `tools/tests/run.sh` guards against regressions.
define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
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
	# LuCI 的菜单树缓存在 /tmp/luci-modulecache（目录）里，只删
	# /tmp/luci-indexcache* 文件是不够的：侧栏菜单读的是 modulecache 里的
	# 解析结果，不刷新它就看不到新装的菜单项——「apk 装完、服务里根本没有
	# HomeProxy」就是这个原因（deploy/install.sh 一直 rm -rf + 重启 uhttpd，
	# 所以本地部署从没暴露过）。顺序也有讲究：先清缓存再重启 uhttpd，
	# 它起来时才会重新扫描 menu.d / acl.d。
	rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache 2>/dev/null || true
	( /etc/init.d/uhttpd restart >/dev/null 2>&1 || service uhttpd restart >/dev/null 2>&1 ) || true
	# rpcd 只在启动时扫描 /usr/share/rpcd/ucode/*.uc 与 acl.d/*.json，不重启
	# 就仍是旧方法表与旧 ACL 组：新增的 RPC（如 dns_server_test、ruleset_update）
	# 会报 "method not found"/"object not found"（界面上是「延迟测试全部失败」），
	# 而 ACL 组不存在时菜单的 depends.acl 也会失败（菜单同样不显示）。
	# 用子 shell + || true 兜底：postinst 返回非 0 会导致整包安装失败。
	( /etc/init.d/rpcd restart >/dev/null 2>&1 || service rpcd restart >/dev/null 2>&1 ) || true
	# ucitrack：「保存并应用」改 /etc/config/homeproxy 后由 LuCI 的
	# /sbin/luci-reload 调 /etc/init.d/homeproxy reload。procd 的
	# reload 触发器只对已有实例的服务生效，而本插件没配节点时会早退、
	# 不创建实例，所以必须靠 ucitrack。这里装包即登记，不必等下次
	# 启动再跑 /etc/uci-defaults（同一个段，幂等）。
	if ! uci -q get ucitrack.@homeproxy[0] >/dev/null 2>&1; then
		hp_track="$$(uci -q add ucitrack homeproxy)"
		if [ -n "$$hp_track" ]; then
			uci -q set "ucitrack.$$hp_track.init=homeproxy"
			uci -q add_list "ucitrack.$$hp_track.affects=homeproxy"
			uci -q commit ucitrack
		fi
	fi
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
# tree by CI (.github/workflows/build-deploy.yml) right before the build, so
# luci.mk's own Build/Prepare copies it into the package. See build-deploy.yml.
# ---------------------------------------------------------------------------

# call BuildPackage - OpenWrt buildroot signature
