#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -u

# ── 时区修正：必须放在任何 date / ucode 调用之前 ─────────────────────────────
# 本脚本是被 sing-box 内核 exec 起来的（面板「更新」按钮那条链路），而内核为了
# 让 Go 拿到正确时区，给自己设了 `TZ=:/var/run/homeproxy/core.zone` —— 那是 Go
# 认得的「冒号 + TZif 文件路径」写法。子进程会**继承**这个变量，可 ucode 是 C
# 程序跑在 musl 上，musl 只认 POSIX 串（如 CST-8）和 IANA 名，**不支持任意路径
# 的 TZif**，遇到这个值会静默回退 UTC。于是 ucode 写的 [SUBSCRIBE] 日志比 shell
# 的 date 整整早 8 小时。
# 现场（0.1.25 装机）：19:51:52 的 [DAEMON] 行后面紧跟着 11:51:52 的 [SUBSCRIBE]
# 行，而手动在 shell 里跑 `sh update_crond.sh` 的时间是对的（那种环境没有 TZ，
# musl 会读 /etc/TZ）。「只有面板触发的日志时间错」就是这条继承链的标志。
# 修法：把 TZ 改回系统时区。/etc/TZ 是 OpenWrt 标准的 POSIX 串，musl 能解析；
# 都没有就 unset，让 libc 走默认路径（比设一个它解析不了的值安全）。
if [ -s /etc/TZ ]; then
	hp_tz="$(cat /etc/TZ 2>/dev/null)"
	[ -n "$hp_tz" ] && { TZ="$hp_tz"; export TZ; }
	unset hp_tz
else
	unset TZ
fi

NAME="homeproxy"
RUN_DIR="/var/run/$NAME"
REQUEST_FILE="$RUN_DIR/provider-update-id"
LOCK_DIR="$RUN_DIR/provider-update.lock"
LOG_FILE="$RUN_DIR/homeproxy.log"
UPDATER="/etc/homeproxy/scripts/update_subscriptions.uc"
PROVIDER_ID="${1:-}"
LOCK_WAIT=30
LOCK_HELD=0

log() {
	printf '%s [SUBSCRIBE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

case "$PROVIDER_ID" in
	*[!0-9a-f]*|'') log "更新请求被忽略：提供者标识非法（'${PROVIDER_ID}'）。"; exit 1 ;;
esac
[ "${#PROVIDER_ID}" -eq 32 ] || { log "更新请求被忽略：提供者标识长度不是 32 位（'${PROVIDER_ID}'）。"; exit 1; }

mkdir -p "$RUN_DIR" 2>/dev/null

# 互斥用 mkdir（POSIX 原子操作，BusyBox 必有）。
#
# ⚠️ 这里原来写的是 `lock -n "$LOCK_FILE"` / `lock "$LOCK_FILE"`。锁本身**不是
# 问题所在**（现场 iStoreOS 上 `/bin/lock`、`/usr/bin/flock` 都有，`lock -n` 对
# 一个新路径返回 0），问题是这套写法：
#   · 用的是固定路径且**从不释放**（没有 `lock -u`，无任何清理）→ 只要有一次
#     拿锁后中途失败（curl 失败、更新脚本返回非 0），锁文件就永久残留在
#     /var/run 里，之后每次都直接走「已有任务在跑」，再也跑不动；
#   · 写成 `lock -n 文件 true` 也不行：锁在那条命令结束时就被释放，保护不到
#     后续步骤；
#   · `flock` 只在部分镜像里有，cron 的 PATH 还常常不含 /usr/bin。
# 而内核 `exec.Command(...).Start()` 只要 /bin/sh 起来就立刻回 204，脚本内部
# 任何提前退出都不会反馈给面板 —— 现象就是「面板上那个刷新按钮点了没反应」。
# 所以：互斥必须用自带陈旧判定与清理的 mkdir 锁，出错也绝不能静默。
# 于是脚本在写请求文件之前就退出（127），而内核那边 `command.Start()`
# 早已成功返回 204，面板显示「操作成功」却什么都没发生 —— 现场感受
# 就是「面板上那个刷新按钮点了没反应」。所以：绝不能用外部 lock 命令，
# 出错也绝不能静默，每一步都要留痕。
lock_acquire() {
	local waited=0 holder

	# 旧版（≤0.1.24）用**同名文件**当锁，且从不释放；升级后它还留在 /var/run
	# 里，正好挡住新版要建的**同名目录** —— 不处理的话「点了没反应」会一直
	# 持续到重启。凡「存在但不是目录」必是旧版残留，直接删掉。
	if [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; then
		log "清理旧版遗留的锁文件（$LOCK_DIR）。"
		rm -f "$LOCK_DIR" 2>/dev/null
	fi

	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		holder="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
		if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
			log "清理陈旧的更新锁（pid $holder 已不存在）。"
			rm -rf "$LOCK_DIR" 2>/dev/null
			continue
		fi
		if [ "$waited" -ge "$LOCK_WAIT" ]; then
			log "另一个更新任务已运行超过 ${LOCK_WAIT} 秒，放弃本次更新。"
			return 1
		fi
		[ "$waited" -eq 0 ] && log "另一个机场正在更新，排队等待…"
		sleep 1
		waited=$((waited + 1))
	done

	printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
	LOCK_HELD=1
	return 0
}

# 只在真正持有锁时才清请求文件与锁目录：拿不到锁而退出时，这两样属于
# 正在跑的那个任务，删掉会把别人的更新搞坏。
cleanup() {
	[ "$LOCK_HELD" = "1" ] || return 0
	rm -f "$REQUEST_FILE" 2>/dev/null
	rm -rf "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

lock_acquire || exit 3

umask 077
printf '%s\n' "$PROVIDER_ID" > "$REQUEST_FILE" || {
	log "无法写入请求文件 $REQUEST_FILE，放弃本次更新。"
	exit 4
}

# Give the Clash API response time to reach the panel before HomeProxy restarts.
log "收到面板的机场更新请求（${PROVIDER_ID}），开始更新该机场订阅…"
sleep 1

if [ ! -f "$UPDATER" ]; then
	log "更新失败：$UPDATER 不存在。"
	exit 5
fi

rc=0
# 优先用 ucode 显式执行：脚本执行位万一丢了（644），直接调用只会
# "Permission denied"，而面板早已收到内核的 204，看起来就像「点了没反应」。
if command -v ucode >"/dev/null" 2>&1; then
	ucode "$UPDATER" --source "面板单个机场「更新」按钮" || rc=$?
elif [ -x "$UPDATER" ]; then
	"$UPDATER" --source "面板单个机场「更新」按钮" || rc=$?
else
	log "更新失败：$UPDATER 既不可执行，也找不到 ucode。"
	exit 5
fi

if [ "$rc" -eq 0 ]; then
	log "机场更新完成（${PROVIDER_ID}）。"
else
	log "机场更新失败（${PROVIDER_ID}），更新脚本返回码 ${rc}，详见上方日志。"
	exit 4
fi
