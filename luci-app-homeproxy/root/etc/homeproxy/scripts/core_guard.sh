#!/bin/sh
# 内核健康兜底：启动后 15 秒内必须能看到客户端内核进程。
#
# 为什么需要它：start_service 的顺序是「先装防火墙/DNS 劫持、再让 procd 拉起
# 内核」，而 procd 是异步的。内核如果压根起不来（0.2.9 现场：清空订阅节点后
# 分组没有成员，sing-box 报 `FATAL: start outbound: … missing outbound and
# provider tags` 后退出 1），劫持已经挂在 fw4 上了 —— 整个局域网失去 DNS，
# 连「更新订阅」都拉不回来，用户只能 SSH 进来自救。
#
# 为什么是一个独立脚本 + setsid：init 脚本里 `( … ) &` 起的子 shell 会在
# init 进程退出时被一起杀掉。0.2.9 实测：探针只写到了 start，循环里的 sleep
# 再没回来 —— 检查形同虚设。setsid 让它换到新会话，脱离那个进程组。
#
# 判定只看「进程在不在」：procd 起来之后进程就一定在，不看内核日志（日志会被
# 轮转/截断）。退出手段是直接 `/etc/init.d/homeproxy stop` —— 复用现成的完整
# 清理（ip rule / nft 链 / DNS 劫持 / dnsmasq），不在这里重写一份。

HP_DIR="/etc/homeproxy"
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
LOG_PATH="$RUN_DIR/homeproxy.log"
CONF="homeproxy"

log_line() {
	printf '%s [DAEMON] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_PATH"
}

i=0
while [ "$i" -lt 15 ]; do
	sleep 1
	i=$((i + 1))

	# 用户在启动过程中把服务停了：这是正常操作，不是启动失败。
	[ -f "$RUN_DIR/.stopping" ] && exit 0

	pgrep -f "sing-box run --config $RUN_DIR/sing-box-c.json" >/dev/null 2>&1 && exit 0
done

log_line "错误：内核启动 15 秒后仍未运行（原因见 $RUN_DIR/sing-box-c.log），已停止服务并撤销防火墙/DNS 劫持，避免路由器失去 DNS。"
logger -t homeproxy "内核启动 15 秒后仍未运行，已停止服务并撤销 DNS 劫持"

/etc/init.d/homeproxy stop >/dev/null 2>&1
