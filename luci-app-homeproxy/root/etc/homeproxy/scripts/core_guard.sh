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
#
# ── 0.4.40：崩溃自动恢复 ──────────────────────────────────────────────
# 0.4.39 现场（238）：订阅更新触发 restart，内核对一个「uci 有节点但种子
# 文件已写坏」的 provider 加载失败，整个 sing-box 退出；本脚本 15 秒窗口内
# 看不到进程，就直接 stop 了整个服务 —— 而服务被 stop 后**没有任何机制再
# 拉起**（cron 只跑评分），于是整夜宕机，直到人工介入。
# 修复：第一次 15 秒窗口失败时，**不立即 stop**，而是先把「这一次失败」当作
# 可能的瞬时崩溃，尝试 `init.d restart` 重试拉起；每次重试再给 15 秒观察窗。
# 最多重试 MAX_RETRY 次；全部失败才记录错误并 stop（保住「绝不让局域网长期
# 失 DNS」的安全底线 —— 真·坏配置下迟早会 stop，不会无限重试）。
#
# 自动恢复的边界（务必保留）：
#   · 用户/系统主动停（.stopping 标记存在）→ 立刻退出，绝不重启；
#   · 重试期间用户主动停（.stopping 出现）→ 立刻退出，不再重试；
#   · 重试用 restart（生成器会重新生成配置）：provider 下发前的「含节点」
#     校验（generate_client.uc: provider_content_has_nodes）已从源头挡掉
#     坏种子，故重试能救回瞬时崩溃，又不会被坏 provider 拖入死循环。

HP_DIR="/etc/homeproxy"
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
LOG_PATH="$RUN_DIR/homeproxy.log"
CONF="homeproxy"

# 首次窗口 + 每次重试后的观察窗口（秒）。合计最长守护约 15*(1+MAX_RETRY)。
WINDOW=15
MAX_RETRY=2

log_line() {
	printf '%s [DAEMON] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_PATH"
}

# 在 WINDOW 秒内轮询内核进程是否出现；出现返回 0，超时返回 1。
# 若检测到 .stopping（用户/系统主动停），以特殊码 2 返回，让调用方立即退出。
wait_core() {
	local i=0
	while [ "$i" -lt "$WINDOW" ]; do
		sleep 1
		i=$((i + 1))
		[ -f "$RUN_DIR/.stopping" ] && return 2
		pgrep -f "sing-box run --config $RUN_DIR/sing-box-c.json" >/dev/null 2>&1 && return 0
	done
	return 1
}

retry=0
while :; do
	wait_core
	rc=$?
	# rc=0 内核已在运行：成功，退出。
	[ "$rc" -eq 0 ] && exit 0
	# rc=2 用户/系统主动停：这不是启动失败，直接退出，绝不重启。
	[ "$rc" -eq 2 ] && exit 0

	# rc=1 首个/重试窗口超时：若还有重试额度，先尝试 restart 拉起。
	if [ "$retry" -lt "$MAX_RETRY" ]; then
		retry=$((retry + 1))
		log_line "警告：内核启动 ${WINDOW} 秒后仍未运行，尝试自动恢复（第 ${retry}/${MAX_RETRY} 次，原因见 $RUN_DIR/sing-box-c.log）。"
		logger -t homeproxy "内核未运行，自动恢复重试 ${retry}/${MAX_RETRY}"
		# restart 走 rc.common，同一进程顺序 stop+start，只取一次 procd 锁。
		# 若此时已被用户停用（.stopping），restart 内部也会尊重，不会异常。
		/etc/init.d/homeproxy restart >/dev/null 2>&1
		# 重试后回到 while 顶部，再给一个 WINDOW 观察窗。
		continue
	fi

	# 重试耗尽仍失败：记录并停止服务，撤销防火墙/DNS 劫持，避免路由器失去 DNS。
	log_line "错误：内核启动失败（已自动重试 ${MAX_RETRY} 次仍无法运行，原因见 $RUN_DIR/sing-box-c.log），已停止服务并撤销防火墙/DNS 劫持，避免路由器失去 DNS。"
	logger -t homeproxy "内核启动失败（重试 ${MAX_RETRY} 次仍失败），已停止服务并撤销 DNS 劫持"
	/etc/init.d/homeproxy stop >/dev/null 2>&1
	exit 0
done
