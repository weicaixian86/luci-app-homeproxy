#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org
#
# 日志清理：按「大小」轮转，而不是按固定间隔清空。
#
# 原实现每 180 秒检查一次，超过 50 KB 就 `echo "" >` 直接清空：排障时
# 最关键的上下文常常在 3 分钟内就被冲掉，而且没有任何历史可回看。
# 现在改为：
#   - 上限来自「日志设置」页面写的 /etc/homeproxy/log.conf
#     （refresh / size / unit 三个 key；size + unit 就是这里的阈值）。
#     没有这个文件时回落到旧版隐藏项 uci homeproxy.config.log_max_kb，
#     再没有就是 1 MiB。
#   - 六个日志文件共用同一个上限。以前下载类日志单独用 256 KiB，界面上
#     却只有一个「日志大小上限」—— 数字对不上，用户量了半天也不知道该信
#     哪个。现在一个数字管全部。
#   - 超限时先把内容另存为 <file>.1（只保留一代），再截断原文件，
#     因此刚被轮转时仍能看到上一次的完整内容；
#   - 检查间隔仍是 180 秒；**每轮都重新读一次 log.conf**，所以在界面上
#     改了上限不必重启本脚本（更不必重启服务）。
#   - 文件不存在或读不到大小就跳过。

NAME="homeproxy"
RUN_DIR="${HP_RUN_DIR:-/var/run/$NAME}"
LOG_CONF="${HP_LOG_CONF:-/etc/homeproxy/log.conf}"

# 下界 64 KiB：设成 0 或几 KB 会让日志一行都留不下。
MIN_BYTES=$((64 * 1024))
# 上界 1 GiB：/var/run 是内存盘，填个 999999 MB 等于把内存吃光。
MAX_BYTES=$((1024 * 1024 * 1024))

# key=value 读一行。缺失/读不到时给默认值。顺手去掉 # 注释和 CR
#（Windows 上编辑过的文件会带 \r，不处理的话 "MB\r" 不等于 "MB"）。
log_conf_get() {
	local key="$1" dflt="$2" line k v
	if [ ! -f "$LOG_CONF" ]; then
		printf '%s' "$dflt"
		return 0
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"
		[ "$line" = "${line#*=}" ] && continue   # 没有 '=' 的行
		k="$(printf '%s' "${line%%=*}" | tr -d ' \t\r')"
		v="$(printf '%s' "${line#*=}" | tr -d ' \t\r')"
		if [ "$k" = "$key" ]; then
			printf '%s' "$v"
			return 0
		fi
	done < "$LOG_CONF"
	printf '%s' "$dflt"
}

resolve_limit() {
	local size unit kb
	size="$(log_conf_get size '')"
	unit="$(log_conf_get unit MB)"

	case "$size" in
		''|*[!0-9]*)
			# 没有 log.conf（<=0.1.27 装的机器）：沿用旧版隐藏 uci 项
			kb="$(uci -q get homeproxy.config.log_max_kb 2>/dev/null)"
			case "$kb" in ''|*[!0-9]*|0) kb=1024 ;; esac
			log_max_bytes=$((kb * 1024))
			;;
		*)
			case "$unit" in
				KB|kb) log_max_bytes=$((size * 1024)) ;;
				*)     log_max_bytes=$((size * 1024 * 1024)) ;;
			esac
			;;
	esac

	[ "$log_max_bytes" -ge "$MIN_BYTES" ] || log_max_bytes="$MIN_BYTES"
	[ "$log_max_bytes" -le "$MAX_BYTES" ] || log_max_bytes="$MAX_BYTES"
}

rotate_log() {
	local f="$1" limit="$2" size
	[ -s "$f" ] || return 0
	size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
	case "$size" in
		''|*[!0-9]*) return 0 ;;
	esac
	[ "$size" -ge "$limit" ] || return 0
	# 保留一代历史：先复制再截断，写者即便正好在写也只会丢最后一行
	cp -f "$f" "$f.1" 2>/dev/null
	: > "$f" 2>/dev/null
	return 0
}

while true; do
	sleep 180
	resolve_limit
	for f in "$RUN_DIR/$NAME.log" \
	         "$RUN_DIR/sing-box-c.log" \
	         "$RUN_DIR/sing-box-s.log" \
	         "$RUN_DIR/core_download.log" \
	         "$RUN_DIR/panel_download.log" \
	         "$RUN_DIR/ruleset_download.log"; do
		rotate_log "$f" "$log_max_bytes"
	done
done
