#!/bin/sh
# Manage named HomeProxy UCI profiles.
#
# 设计要点（都是踩过的坑）：
#   · 固定目录 /etc/config，文件名白名单 homeproxy-*，绝不接受任意路径；
#   · 默认配置固定叫 homeproxy-default，既不进上传列表也不能被覆盖/删除；
#   · 切换前必须在临时目录里跑一遍 `uci show`，语法错误时**当前配置不动**；
#   · 写盘一律「临时文件 + mv」，BusyBox 上直接覆盖被中断会留下半截配置；
#   · 切换过程中放一个 marker，让 start_service 里的 sync 让路 —— 否则
#     「已改 state、未换 active」那一瞬间的自愈会把源文件反向覆盖掉。

set -u

PROFILE_DIR="/etc/config"
ACTIVE_FILE="$PROFILE_DIR/homeproxy"
DEFAULT_FILE="$PROFILE_DIR/homeproxy-default"
STATE_FILE="/etc/homeproxy/current_profile"
SWITCH_MARKER="/etc/homeproxy/.profile-switching"
UPLOAD_FILE="/tmp/homeproxy_profile.tmp"

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

valid_name() {
	case "${1:-}" in
		'') return 1 ;;
		homeproxy-default) return 0 ;;
		homeproxy-*)
			[ "${1:-}" = "homeproxy-back" ] && return 1
			# 只允许字母数字点下划线和横线：挡掉 ../、空格、通配符。
			case "${1#homeproxy-}" in
				*[!A-Za-z0-9._-]*) return 1 ;;
			esac
			return 0
			;;
	esac
	return 1
}

current_name() {
	local name
	name="$(cat "$STATE_FILE" 2>/dev/null)"
	if ! valid_name "$name" || [ ! -f "$PROFILE_DIR/$name" ]; then
		name="homeproxy-default"
	fi
	printf '%s\n' "$name"
}

atomic_copy() {
	local src="$1" dst="$2" tmp
	tmp="${dst}.tmp.$$"
	cp "$src" "$tmp" 2>/dev/null || return 1
	chmod 600 "$tmp" 2>/dev/null
	mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
	return 0
}

# 在隔离的目录里真跑一遍 `uci show`：UCI 语法错误（少引号、段名重复、
# option 缺值……）都会在这里暴露，而不会污染正在使用的配置。
validate_file() {
	local src="$1" tmpdir output rc
	[ -f "$src" ] || { printf '文件不存在\n'; return 1; }
	[ -s "$src" ] || { printf '文件是空的\n'; return 1; }

	tmpdir="/tmp/homeproxy_profile_check.$$"
	rm -rf "$tmpdir"
	mkdir -p "$tmpdir" || { printf '无法创建校验临时目录\n'; return 1; }
	cp "$src" "$tmpdir/homeproxy" 2>/dev/null || { rm -rf "$tmpdir"; printf '无法读取配置文件\n'; return 1; }

	# 不能用 `uci -q`：-q 会把解析错误一起吞掉，只剩一句「格式错误」。
	# 需求要求「有格式错误时在插件日志里显示出内容」，所以这里保留 stderr
	# （uci 会给出 `Parse error (option requires an argument) at line N, byte M`）。
	output="$(uci -c "$tmpdir" show homeproxy 2>&1)"
	rc=$?
	rm -rf "$tmpdir"

	if [ "$rc" -ne 0 ]; then
		printf '%s\n' "${output:-UCI 配置格式错误}"
		return 1
	fi
	[ -n "$output" ] || { printf '配置里没有任何可识别的段\n'; return 1; }
	return 0
}

ensure_default() {
	if [ ! -f "$DEFAULT_FILE" ] && [ -f "$ACTIVE_FILE" ]; then
		atomic_copy "$ACTIVE_FILE" "$DEFAULT_FILE" || return 1
	fi
	if [ ! -f "$STATE_FILE" ]; then
		mkdir -p "${STATE_FILE%/*}" 2>/dev/null
		printf 'homeproxy-default\n' > "${STATE_FILE}.tmp.$$" || return 1
		mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE" || return 1
	fi
	return 0
}

set_state() {
	mkdir -p "${STATE_FILE%/*}" 2>/dev/null
	printf '%s\n' "$1" > "${STATE_FILE}.tmp.$$" || return 1
	mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE" || return 1
	return 0
}

case "${1:-}" in
list)
	ensure_default || fail '无法创建默认配置文件'
	printf 'current=%s\n' "$(current_name)"
	printf '%s\n' homeproxy-default
	for path in "$PROFILE_DIR"/homeproxy-*; do
		[ -f "$path" ] || continue
		name="${path##*/}"
		valid_name "$name" || continue
		[ "$name" = "homeproxy-default" ] && continue
		printf '%s\n' "$name"
	done
	;;
check)
	name="${2:-}"
	valid_name "$name" || fail '非法配置文件名'
	[ -f "$PROFILE_DIR/$name" ] || fail '配置文件不存在'
	if out="$(validate_file "$PROFILE_DIR/$name")"; then
		printf '配置格式正确\n'
	else
		printf '%s\n' "$out"
		exit 1
	fi
	;;
switch)
	name="${2:-}"
	valid_name "$name" || fail '非法配置文件名'
	src="$PROFILE_DIR/$name"
	[ -f "$src" ] || fail '配置文件不存在'

	# 先校验：不通过就什么都不动，用户当前那套配置继续跑。
	if ! out="$(validate_file "$src")"; then
		printf '%s\n' "$out"
		exit 1
	fi

	old="$(current_name)"

	# marker 让 start_service 里的 sync 在这段时间内让路（见文件头注释）。
	mkdir -p "${SWITCH_MARKER%/*}" 2>/dev/null
	: > "$SWITCH_MARKER" 2>/dev/null

	# 先换 active、再写 state：反过来的话，「state 已指新文件、active 还是旧的」
	# 那一刻若恰好有 start 进来，sync 会把旧 active 反向写回新 profile。
	if ! atomic_copy "$src" "$ACTIVE_FILE"; then
		rm -f "$SWITCH_MARKER"
		fail '无法切换当前配置（写盘失败，原配置未改动）'
	fi

	if ! set_state "$name"; then
		# 回滚：把原来那个配置写回 active，避免「当前配置」和文件对不上。
		atomic_copy "$PROFILE_DIR/$old" "$ACTIVE_FILE" >/dev/null 2>&1
		set_state "$old" >/dev/null 2>&1
		rm -f "$SWITCH_MARKER"
		fail '无法记录当前配置（已回滚）'
	fi

	rm -f "$SWITCH_MARKER"
	printf '配置已切换：%s\n' "$name"
	;;
upload)
	name="${2:-}"
	valid_name "$name" || fail '文件名必须是 homeproxy- 前缀，且不能包含特殊字符'
	[ "$name" != "homeproxy-default" ] || fail '不能上传或覆盖默认配置文件'
	[ -f "$UPLOAD_FILE" ] || fail '没有收到上传文件'

	# 真实的 UCI 配置只有几十 KB。没有上限的话，一次误选（镜像、日志、
	# 归档）就会把几百 MB 写进 /etc/config —— overlay 在 flash 上，写满
	# 之后连 uci commit 都会失败。
	size="$(wc -c <"$UPLOAD_FILE" 2>/dev/null | tr -d ' ')"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -gt 1048576 ]; then
		rm -f "$UPLOAD_FILE"
		fail '文件超过 1 MB，不是 UCI 配置文件的正常大小'
	fi

	if ! out="$(validate_file "$UPLOAD_FILE")"; then
		rm -f "$UPLOAD_FILE"
		printf '%s\n' "$out"
		exit 1
	fi

	atomic_copy "$UPLOAD_FILE" "$PROFILE_DIR/$name" || fail '无法保存配置文件'
	rm -f "$UPLOAD_FILE"
	printf '上传成功：%s\n' "$name"
	;;
delete)
	name="${2:-}"
	valid_name "$name" || fail '非法配置文件名'
	[ "$name" != "homeproxy-default" ] || fail '不能删除默认配置文件'
	[ "$name" != "$(current_name)" ] || fail '不能删除当前正在使用的配置文件'
	[ -f "$PROFILE_DIR/$name" ] || fail '配置文件不存在'
	rm -f "$PROFILE_DIR/$name" || fail '删除配置文件失败'
	printf '已删除：%s\n' "$name"
	;;
sync)
	# 由 start_service 调用：LuCI 只写 /etc/config/homeproxy，这里把生效中的
	# 配置回写到当前选中的配置文件，保证「切换过去 → 改设置 → 再切回来」
	# 不会丢掉改动。
	[ -f "$SWITCH_MARKER" ] && exit 0
	ensure_default || fail '无法准备默认配置文件'
	name="$(current_name)"
	[ -f "$ACTIVE_FILE" ] || exit 0
	atomic_copy "$ACTIVE_FILE" "$PROFILE_DIR/$name" || fail '无法把当前配置同步到配置文件'
	printf '已同步当前配置：%s\n' "$name"
	;;
*)
	printf 'usage: %s list|check|switch|upload|delete|sync [name]\n' "$0" >&2
	exit 2
	;;
esac
