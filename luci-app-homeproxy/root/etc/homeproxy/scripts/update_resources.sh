#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

# ── 时区修正：必须放在任何 date 调用之前 ─────────────────────────────────────
# 本脚本可能被 sing-box 内核 exec 起来，而内核为了让 Go 拿到正确时区，给自己设了
# `TZ=:/var/run/homeproxy/core.zone` —— 那是 Go 认得的「冒号 + TZif 文件路径」，
# 子进程会继承它。C 程序（musl）不认这种写法，解析失败静默回退 UTC，于是日志时间
# 比 `date` 早 8 小时（0.1.25 现场：[DAEMON] 19:51:52 后面跟着 [SUBSCRIBE]
# 11:51:52）。这里统一改回系统时区：优先 /etc/TZ（OpenWrt 标准的 POSIX 串，musl
# 能解析），都没有就 unset，让 libc 走默认路径。
if [ -s /etc/TZ ]; then
	hp_tz="$(cat /etc/TZ 2>/dev/null)"
	[ -n "$hp_tz" ] && { TZ="$hp_tz"; export TZ; }
	unset hp_tz
else
	unset TZ
fi

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
mkdir -p "$RESOURCES_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

# 锁目录（本脚本一次只处理一份列表，所以一个就够）。
LOCK_DIR=""
cleanup() {
	if [ -n "$LOCK_DIR" ]; then
		rm -rf "$LOCK_DIR" 2>"/dev/null"
		LOCK_DIR=""
	fi
	return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_list_update() {
	local LIST_FILE="$1"
	local REPO_NAME="$2"
	local REPO_BRANCH="$3"
	local REPO_FILE="$4"
	local GITHUB_TOKEN="$(uci -q get homeproxy.config.github_token)"
	local holder

	# ⚠️ 这里原来写的是 `if ! lock -n "$LOCK_FILE" 2>/dev/null; then …
	# return 2; fi`，于是四份内置资源（china_ip4 / china_ip6 / gfw_list /
	# china_list）**从来没有被更新过**，日志里还只留一句误导性的
	# 「A task is already running.」。真因不是「命令不存在」也不是「语法错」：
	#   ① 现场 iStoreOS 上 `/bin/lock`、`/usr/bin/flock` 都有，且
	#      `lock -n /tmp/t.lock` 对**一个新路径**返回 **0**（裸调用是能成功的）；
	#   ② 脚本用的是**固定路径**且**从不释放**（没有 `lock -u`，也没有任何
	#      清理）。只要某一次在拿锁之后中途失败 —— 例如 `curl` 取不到最新
	#      release tag 就 `return 1`、或下载失败 `return 1` —— 那个锁文件就
	#      永久留在 `/var/run` 里，此后**每一次**都是 rc=2「已有任务在跑」，
	#      再也跑不动（/var/run 是内存盘，只有重启才清）。
	#   ③ 即使换成 `lock -n 文件 true`，锁也会在那条命令结束时释放，保护不到
	#      后面的 curl/mv；`flock` 又只在部分镜像里有，cron 的 PATH 还常常
	#      不含 /usr/bin。
	# 现场判据：`ls -l /etc/homeproxy/resources/` 的 mtime 一直是打包日期；
	# `ls /var/run/homeproxy/*.lock` 能看到残留的锁文件。
	# 现场证据：/etc/homeproxy/resources/ 下 8 个文件的 mtime 一直是打包日期。
	# 互斥改用 mkdir（POSIX 原子，BusyBox 必有），锁内写 pid 判陈旧。
	LOCK_DIR="$RUN_DIR/update_resources-$LIST_FILE.lock"

	# 旧版（≤0.1.24）用**同名文件**当锁，且从不释放；升级后那个文件还留在
	# /var/run 里，正好挡住新版要建的**同名目录** —— 不处理的话用户装完新版
	# 还是「A task is already running.」，必须重启才见效。凡「存在但不是目录」
	# 必是旧版残留，直接删掉。
	if [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; then
		log "[$(to_upper "$LIST_FILE")] 清理旧版遗留的锁文件（$LOCK_DIR）。"
		rm -f "$LOCK_DIR" 2>"/dev/null"
	fi

	if ! mkdir "$LOCK_DIR" 2>"/dev/null"; then
		holder="$(cat "$LOCK_DIR/pid" 2>"/dev/null")"
		if [ -n "$holder" ] && [ ! -d "/proc/$holder" ]; then
			rm -rf "$LOCK_DIR" 2>"/dev/null"
			mkdir "$LOCK_DIR" 2>"/dev/null"
		fi
		if [ ! -d "$LOCK_DIR" ]; then
			log "[$(to_upper "$LIST_FILE")] A task is already running."
			return 2
		fi
	fi
	printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>"/dev/null"

	# 「取不到版本号」至少有四种完全不同的原因，只写一句 "Failed to get the
	# latest version, please retry later." 会让排障的人以为插件坏了：
	#   ① GitHub 未认证 API 限流（60 次/小时/IP）—— 最常见，连着跑几次就撞上；
	#   ② 网络/DNS 不通；③ 仓库或 release 不存在；④ 返回体结构变了。
	# 现场（0.1.25）：连跑四次内置资源就撞上 ①，日志却只说「请稍后重试」，只能
	# 手工 curl 才知道是限流。所以把 API 的 message 与响应片段一起写进日志。
	local API_RESP API_REASON API_SNIP
	API_RESP=$(curl -sL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "https://api.github.com/repos/$REPO_NAME/releases/latest" 2>"/dev/null")
	local NEW_VER=$(printf '%s' "$API_RESP" | jsonfilter -e "@.tag_name")
	if [ -z "$NEW_VER" ]; then
		API_REASON=$(printf '%s' "$API_RESP" | jsonfilter -e "@.message" 2>"/dev/null")
		API_SNIP=$(printf '%s' "$API_RESP" | tr '\n\t' '  ' | head -c 120)

		case "$API_REASON" in
			*"rate limit"*)
				log "[$(to_upper "$LIST_FILE")] 获取最新版本失败：GitHub API 限流（未认证每小时 60 次/IP）。请在插件设置里填 GitHub Token（可提到每小时 5000 次），或稍后重试。"
				;;
			*)
				log "[$(to_upper "$LIST_FILE")] 获取最新版本失败：${API_REASON:-API 无响应或返回无法解析}（响应前 120 字节：$API_SNIP）"
				;;
		esac

		return 1
	fi

	local OLD_VER=$(cat "$RESOURCES_DIR/$LIST_FILE.ver" 2>/dev/null || echo "NOT FOUND")
	if [ "$OLD_VER" = "$NEW_VER" ]; then
		log "[$(to_upper "$LIST_FILE")] Current version: $NEW_VER."
		log "[$(to_upper "$LIST_FILE")] You're already at the latest version."

		return 3
	else
		log "[$(to_upper "$LIST_FILE")] Local version: $OLD_VER, latest version: $NEW_VER."
	fi

	if ! curl -sL -o "$RUN_DIR/$REPO_FILE" "https://cdn.jsdelivr.net/gh/$REPO_NAME@$REPO_BRANCH/$REPO_FILE" || [ ! -s "$RUN_DIR/$REPO_FILE" ]; then
		rm -f "$RUN_DIR/$REPO_FILE"
		log "[$(to_upper "$LIST_FILE")] Update failed."

		return 1
	fi

	mv -f "$RUN_DIR/$REPO_FILE" "$RESOURCES_DIR/$LIST_FILE.${REPO_FILE##*.}"
	echo -e "$NEW_VER" > "$RESOURCES_DIR/$LIST_FILE.ver"
	log "[$(to_upper "$LIST_FILE")] Successfully updated."

	return 0
}

case "$1" in
"china_ip4")
	check_list_update "$1" "Loyalsoldier/surge-rules" "release" "cncidr.txt" && \
		sed -i "/IP-CIDR6,/d; s/IP-CIDR,//g" "$RESOURCES_DIR/china_ip4.txt"
	;;
"china_ip6")
	check_list_update "$1" "Loyalsoldier/surge-rules" "release" "cncidr.txt" && \
		sed -i "/IP-CIDR,/d; s/IP-CIDR6,//g" "$RESOURCES_DIR/china_ip6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/surge-rules" "release" "gfw.txt" && \
		sed -i "s/^\.//g" "$RESOURCES_DIR/gfw_list.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/surge-rules" "release" "direct.txt" && \
		sed -i "s/^\.//g" "$RESOURCES_DIR/china_list.txt"
	;;
*)
	echo -e "Usage: $0 <china_ip4 / china_ip6 / gfw_list / china_list>"
	exit 1
	;;
esac
