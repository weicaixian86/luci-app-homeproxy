#!/bin/sh
# 配置自愈：0.2.5 装机实测，apk 用包内默认模板覆盖了 /etc/config/homeproxy
# （72242 字节、90 个节点 → 2795 字节、0 个节点），用户的订阅与节点全丢。
# Makefile 的 conffiles 只声明了 /etc/config/homeproxy，apk 侧本应保留被改过
# 的 conffile（留成 .apk-new），实际没有；根因尚未定位。这里加一道**与包管理
# 器行为无关**的保险，两种用法：
#
#   backup  —— 服务成功启动后，把「确实含 config node 段」的配置存一份；
#   restore —— 装包后若当前配置里一个 node 段都没有、而备份里有，就地还原。
#
# 关键设计（照抄就废了）：**没有节点的配置永远不能覆盖备份**。第一次被覆盖
# 时如果照抄，备份也会变成默认模板，保险反过来变成帮凶。
#
# restore 只允许由 postinst 调用，不在 start_service 里跑：用户自己删光节点
# 保存后，服务重启不该把旧节点又塞回来。装包时那一次才算「被外力覆盖」。
#
# 路径可用环境变量覆盖，用于自检在沙箱里跑（与 HP_RUN_DIR 同一套路）。

CONFIG="${HP_CONFIG:-/etc/config/homeproxy}"
BACKUP="${HP_CONFIG_BAK:-/etc/homeproxy/config.uci.bak}"
LOGFILE="${HP_LOG:-/var/run/homeproxy/homeproxy.log}"

log_config() {
	local ts
	ts="$(date "+%Y-%m-%d %H:%M:%S")"
	[ -f "$LOGFILE" ] && echo "$ts [DAEMON] $*" >> "$LOGFILE" 2>/dev/null
	logger -t homeproxy "$*" 2>/dev/null
	return 0
}

# uci 配置文件里节点段是 `config node 'name'`；用 grep -q 只判断「有没有」，
# 不关心具体内容——数量对不上也可能是机场换了节点，不算异常。
has_nodes() {
	[ -f "$1" ] || return 1
	grep -q "^config node" "$1" 2>/dev/null
}

case "$1" in
backup)
	# 只在确实有节点时刷新备份。服务启动失败、配置为空、节点全删——都不刷新。
	has_nodes "$CONFIG" || exit 0
	cp -f "$CONFIG" "$BACKUP.tmp" 2>/dev/null || exit 0
	# 先写 tmp 再 mv：拷一半断电不至于把唯一的好备份毁掉。
	mv -f "$BACKUP.tmp" "$BACKUP" 2>/dev/null || { rm -f "$BACKUP.tmp" 2>/dev/null; exit 0; }
	[ -n "$HP_GUARD_VERBOSE" ] && echo "backup ok: $BACKUP"
	exit 0
	;;

restore)
	# 备份本身没有节点就没有还原价值（也避免把坏备份传回去）。
	has_nodes "$BACKUP" || exit 0
	# 当前配置有节点 = 没被覆盖，什么都不做。
	if has_nodes "$CONFIG"; then
		exit 0
	fi
	# 被覆盖的那份留档再覆盖，出问题还能回退看到「默认模板长什么样」。
	if [ -f "$CONFIG" ]; then
		cp -f "$CONFIG" "$CONFIG.apk-new" 2>/dev/null
	fi
	cp -f "$BACKUP" "$CONFIG" 2>/dev/null || exit 0
	chmod 644 "$CONFIG" 2>/dev/null
	log_config "检测到 $CONFIG 被包内默认模板覆盖（没有任何 node 段），已从 $BACKUP 还原。被覆盖的那份留在 $CONFIG.apk-new。"
	[ -n "$HP_GUARD_VERBOSE" ] && echo "restore ok: $CONFIG"
	exit 0
	;;

*)
	echo "usage: $0 backup|restore" >&2
	exit 2
	;;
esac
