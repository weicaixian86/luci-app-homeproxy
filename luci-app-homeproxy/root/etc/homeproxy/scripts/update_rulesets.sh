#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org

HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"

# Refresh the local rule-set cache BEFORE restarting.
#
# generate_client.uc emits `type: local` whenever a validated copy exists, so a
# warm cache means the core starts with zero rule-set downloads. That matters
# because sing-box loads rule-sets while initialising, before it starts the
# Clash API listener: with 20+ remote rule-sets a slow mirror delayed the API by
# minutes and the web panel was therefore never downloaded.
mkdir -p "$RUN_DIR" 2>/dev/null
if [ -x "$HP_DIR/scripts/fetch_rulesets.sh" ]; then
	/bin/sh "$HP_DIR/scripts/fetch_rulesets.sh" --force --budget 900 \
		>>"$RUN_DIR/ruleset_download.log" 2>&1
else
	printf '%s 规则集预下载脚本缺失，跳过（内核将按 remote 方式自行下载）\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" >>"$RUN_DIR/ruleset_download.log" 2>/dev/null
fi

CACHE_PATH="$(uci -q get homeproxy.cache.path)"
[ -n "$CACHE_PATH" ] || CACHE_PATH="/etc/homeproxy/cache.db"

rm -f "$CACHE_PATH"
/etc/init.d/homeproxy restart
