# 让新规则生效需要重启内核（sing-box 只在启动时读 local rule-set，没有运行期
# 热重载；remote 模式虽能在线更新但 URL 不可达时内核 FATAL，见变更清单 74）。
# 用 reload 而不是 restart：内核重启 0.1 秒、nftables/dnsmasq 规则不重建
# （237 实测 reload 全链路 ≈3 秒，restart 要数秒），断流窗口小得多。
# ⚠️ reload 有「重载风暴」判定：caller 不在 force 名单（cron 的 caller=crond
# 就不在）且 /etc/config 的 mtime <= last-start 时，这次 reload 会被**静默跳过**
# —— 而 .srs 更新不改 /etc/config，mtime 永远是旧的，cron 场景必中。所以单条
# 模式在 reload 前 touch 一次配置文件（内容不变，只刷新 mtime），让判定走「有
# 新配置」分支。这比往 init.d 的 force 名单里加 crond 影响面小：改名单会让
# crond 的所有 reload 都绕过风暴保护。
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

# 参数：① cron 表达式（日志留痕用），② 规则集段名（可选）。
# ② 存在时本脚本只下载这一条（fetch_rulesets.sh --only）并只 reload 一次：
# 每条规则集各配各的时刻、互不影响 —— 不带段名的旧 crontab 行仍走全量，
# 兼容升级前登记的任务（全量 + restart 是旧行为，行为不变就不会出新问题）。
CRON_EXPR="${1:-}"
RULESET_SECTION="${2:-}"

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
log "==== 规则集定时更新开始（cron #homeproxy_autosetup${CRON_EXPR:+，表达式=}${CRON_EXPR}${RULESET_SECTION:+，规则集=}${RULESET_SECTION}）===="

if [ -x "$HP_DIR/scripts/fetch_rulesets.sh" ]; then
	if [ -n "$RULESET_SECTION" ]; then
		# 单条模式：只下这一条。--only 支持段名或 tag（tag 多义时报错退出 2），
		# --force 忽略「本地副本仍有效」的缓存判断 —— 定时更新的语义就是拉新版。
		# budget 用默认值：单条规则集最大几百 KB（现场最大 geosite-cn 440 KB），
		# 900 秒是给全量慢链路设的，单条用不上。
		/bin/sh "$HP_DIR/scripts/fetch_rulesets.sh" --force --only "$RULESET_SECTION" \
			--source "定时更新（cron #homeproxy_autosetup，仅 ${RULESET_SECTION}）" \
			>>"$LOG_FILE" 2>&1
	else
		/bin/sh "$HP_DIR/scripts/fetch_rulesets.sh" --force --budget 900 \
			--source "定时更新（cron #homeproxy_autosetup）" \
			>>"$LOG_FILE" 2>&1
	fi
	log "规则集定时更新：下载阶段结束（rc=$?）。"
else
	log "规则集定时更新：下载脚本 $HP_DIR/scripts/fetch_rulesets.sh 缺失，跳过（内核将按 remote 方式自行下载）。"
fi

CACHE_PATH="$(uci -q get homeproxy.cache.path)"
[ -n "$CACHE_PATH" ] || CACHE_PATH="/etc/homeproxy/cache.db"

rm -f "$CACHE_PATH"

# 让新规则生效需要重启内核（sing-box 只在启动时读 local rule-set，没有运行期
# 热重载；remote 模式虽能在线更新但 URL 不可达时内核 FATAL，见变更清单 74）。
# 用 reload 而不是 restart：内核重启 0.1 秒、nftables/dnsmasq 规则不重建
# （237 实测 reload 全链路 ≈3 秒，restart 要数秒），断流窗口小得多。
# ⚠️ cron 场景必踩的坑：reload 有「重载风暴」判定 —— caller 不在 force 名单
# （cron 的 caller=crond 就不在）且 /etc/config 的 mtime <= last-start 时，这次
# reload 会被**静默跳过**。而 .srs 更新不改 /etc/config，mtime 永远是旧的，
# cron 场景必然命中跳过 → 单条更新完服务纹丝不动。解法：reload 前 touch 一次
# 配置文件（内容不变、只刷 mtime），让判定走「有新配置」分支。不改 init.d 的
# force 名单——那会让 crond 的所有 reload 都绕过风暴保护。
# cache.db 只在全量模式清：它是 DNS/选择缓存，与规则集内容无关；旧行为保留。
if [ -n "$RULESET_SECTION" ]; then
	log "规则集定时更新：已更新 ${RULESET_SECTION}，重载服务使新规则生效…"
	touch /etc/config/homeproxy
	/etc/init.d/homeproxy reload </dev/null >/dev/null 2>&1
	log "==== 规则集定时更新结束（reload rc=$?）===="
else
	log "规则集定时更新：已清除缓存 $CACHE_PATH，正在重启服务让新规则生效…"
	/etc/init.d/homeproxy restart
	log "==== 规则集定时更新结束（restart rc=$?）===="
fi
