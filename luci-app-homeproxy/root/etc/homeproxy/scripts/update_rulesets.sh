#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org

# cron 在登录 shell 之外运行，PATH 只有最小集合；少了 /usr/sbin 时 uci 直接
# command not found，而它的 stderr 常被引走，于是「缓存清不掉」看起来和
# 「本来就没缓存」一模一样。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"
LOG_FILE="$RUN_DIR/ruleset_download.log"

# 第一个参数是 cron 表达式：init.d 登记定时任务时把它写进 crontab
# （`sh update_rulesets.sh '0 3 * * *' #homeproxy_autosetup`）。老配置里可能
# 还是不带参数的旧格式，这里兼容——没有就只写「定时更新」，不编造。
CRON_EXPR="${1:-}"

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
	logger -t homeproxy "$*" 2>/dev/null
}

# Refresh the local rule-set cache BEFORE restarting.
#
# generate_client.uc emits `type: local` whenever a validated copy exists, so a
# warm cache means the core starts with zero rule-set downloads. That matters
# because sing-box loads rule-sets while initialising, before it starts the
# Clash API listener: with 20+ remote rule-sets a slow mirror delayed the API by
# minutes and the web panel was therefore never downloaded.
#
# 这次整件事（下载 → 清缓存 → 重启）以前完全没有自己的横幅，只在下载日志里
# 留下几行 fetch_rulesets.sh 的输出；「到底有没有按点跑」只能靠文件 mtime 猜。
# 现在首尾各写一行，并带上触发它的 cron 表达式。
mkdir -p "$RUN_DIR" 2>/dev/null
log "==== 规则集定时更新开始（cron #homeproxy_autosetup${CRON_EXPR:+，表达式=}${CRON_EXPR}）===="

if [ -x "$HP_DIR/scripts/fetch_rulesets.sh" ]; then
	/bin/sh "$HP_DIR/scripts/fetch_rulesets.sh" --force --budget 900 \
		--source "定时更新（cron #homeproxy_autosetup）" \
		>>"$LOG_FILE" 2>&1
	log "规则集定时更新：下载阶段结束（rc=$?）。"
else
	log "规则集定时更新：下载脚本 $HP_DIR/scripts/fetch_rulesets.sh 缺失，跳过（内核将按 remote 方式自行下载）。"
fi

CACHE_PATH="$(uci -q get homeproxy.cache.path)"
[ -n "$CACHE_PATH" ] || CACHE_PATH="/etc/homeproxy/cache.db"

rm -f "$CACHE_PATH"
log "规则集定时更新：已清除缓存 $CACHE_PATH，正在重启服务让新规则生效…"
/etc/init.d/homeproxy restart
log "==== 规则集定时更新结束（restart rc=$?）===="
