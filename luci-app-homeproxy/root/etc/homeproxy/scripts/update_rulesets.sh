# 生效时机（2026-11-21 用户决定）：**单条定时更新只落盘、不重载内核**——
# sing-box 只在启动时读 local rule-set，新 .srs 待下次「重载服务」或重启服务
# 时生效，定时更新全程零断流。手动「重载服务」走 rpcd caller → init.d 风暴
# 守卫 force=1 永远执行（「用户在界面点按钮 → 永远执行」），不会被「配置没变」
# 判定跳过；cron/触发器 caller 才受 mtime 判定——那正是旧 touch+reload 方案
# 的由来，现已废弃。
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


# 生效时机（2026-11-21 用户决定）：**单条定时更新只落盘、不重载内核**——
# sing-box 只在启动时读 local rule-set，新 .srs 待下次「重载服务」或重启服务
# 时生效，定时更新全程零断流。手动「重载服务」走 rpcd caller → init.d 风暴
# 守卫 force=1 永远执行（「用户在界面点按钮 → 永远执行」），不会被「配置没变」
# 判定跳过；cron/触发器 caller 才受 mtime 判定——那正是旧 touch+reload 方案
# 的由来，现已废弃。
# cache.db 只在全量模式清：它是 DNS/选择缓存，与规则集内容无关；旧行为保留。
if [ -n "$RULESET_SECTION" ]; then
	# 只下载落盘、不重载内核（不断网）：新 .srs 待下次手动「重载服务」（界面
	# 按钮 force=1 必执行）或重启服务时生效。
	log "规则集定时更新：已更新 ${RULESET_SECTION}（不重载内核、不断网）；新规则将在下次手动「重载服务」或重启服务时生效。"
	log "==== 规则集定时更新结束 ===="
else
	# cache.db（DNS/选择缓存，含 store_selected 的手动选择）只在全量模式清：
	# 单条 .srs 更新与它无关——清掉会让 reload 后的内核丢缓存，用户的手动
	# 选择（store_selected）也随之被抹（237/238 现场：每周 13 条错峰更新会
	# 逐一抹掉「全球手动」的手动节点）。
	rm -f "$CACHE_PATH"
	log "规则集定时更新：已清除缓存 $CACHE_PATH，正在重启服务让新规则生效…"
	/etc/init.d/homeproxy restart
	log "==== 规则集定时更新结束（restart rc=$?）===="
fi
