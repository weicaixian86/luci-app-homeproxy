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
#   - 单个文件上限默认 1 MiB，可用 UCI 覆盖（隐藏选项，不占用界面）：
#       uci set homeproxy.config.log_max_kb=2048 && uci commit homeproxy
#   - 超限时先把内容另存为 <file>.1（只保留一代），再截断原文件，
#     因此刚被轮转时仍能看到上一次的完整内容；
#   - 检查间隔仍是 180 秒；文件不存在或读不到大小就跳过。

NAME="homeproxy"

log_max_kb="$(uci -q get homeproxy.config.log_max_kb 2>/dev/null)"
case "$log_max_kb" in
	''|*[!0-9]*|0) log_max_kb=1024 ;;
esac
log_max_bytes=$((log_max_kb * 1024))

main_log_file="/var/run/$NAME/$NAME.log"
singc_log_file="/var/run/$NAME/sing-box-c.log"
sings_log_file="/var/run/$NAME/sing-box-s.log"

rotate_log() {
	local f="$1" size
	[ -s "$f" ] || return 0
	size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
	case "$size" in
		''|*[!0-9]*) return 0 ;;
	esac
	[ "$size" -ge "$log_max_bytes" ] || return 0
	# 保留一代历史：先复制再截断，写者即便正好在写也只会丢最后一行
	cp -f "$f" "$f.1" 2>/dev/null
	: > "$f" 2>/dev/null
	return 0
}

while true; do
	sleep 180
	for i in "$main_log_file" "$singc_log_file" "$sings_log_file"; do
		rotate_log "$i"
	done
done
