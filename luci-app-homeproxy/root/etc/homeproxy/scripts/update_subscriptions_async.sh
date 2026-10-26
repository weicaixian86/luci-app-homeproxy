#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 订阅更新的脱管启动器（供 rpcd 的 subscription_update 调用）。
#
# 为什么存在
# ----------
# 「更新 N 个订阅」原来是一条**同步**的 `fs.exec_direct`：rpcd 的 file.exec
# 会一直等到脚本退出才回包。而这个脚本要依次抓 N 个订阅（每条 connect 上限
# 10 秒、整条上限 60 秒），成功后再 stop+start 一次内核。现场 5 条订阅正常
# 耗时约 21 秒（抓取 13 + 重启 8），已经贴着 rpcd/ubus 约 30 秒的上限：
#   · 界面上是一条一直转圈的请求，20 秒的白屏等待没有任何进度；
#   · 只要有一个机场响应慢一点就超时，前端弹一句英文错误并刷新页面，
#     **而脚本其实还在路由器上继续跑** —— 用户看到的就是「转很久、报错、
#     但节点后来又变了」。
# 这里照搬内核更新的做法：立即脱管、立刻返回，让前端去轮询状态。
#
# 契约（路径与 luci.homeproxy 的 subscription_update_progress 共享）：
#   $RUN_DIR/subscription_update.pid  运行期间存在，退出时删除
#   $RUN_DIR/subscription_update.out  ucode 的 stdout/stderr（正常为空）
#   $RUN_DIR/subscription_update.rc   退出码，最后写
# rc 在 pid 删除之前写，所以「rc 存在 + pid 不存在」唯一地表示「已结束」，
# 陈旧的 pid 文件不可能让界面误以为还在跑。

set -u

# 与其它 update 脚本一致：rpcd / procd / cron / SSH 的环境差别很大，PATH 里
# 少了 /usr/sbin 时 ucode 和 curl 都会 command not found，而这条链路的 stderr
# 平时是丢掉的 —— 现象就是「点了按钮什么都没有」。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ── 时区修正：必须放在任何 date / ucode 调用之前 ───────────────────────────────
# ucode 是 C 程序跑在 musl 上，musl 的 localtime 只认 POSIX 串（如 CST-8）和
# IANA 名，**不支持「冒号 + 任意 TZif 路径」** 那种 Go 才认的写法（内核给
# sing-box 设的正是 `TZ=:/var/run/homeproxy/core.zone`，子进程会继承）。解析
# 失败时 musl 静默回退 UTC，日志时间就比 shell 的 date 早 8 小时。现场
# 0.1.25 的 [SUBSCRIBE] 行 11:51:52 vs [DAEMON] 行 19:51:52 就是这么来的。
if [ -s /etc/TZ ]; then
	hp_tz="$(cat /etc/TZ 2>/dev/null)"
	[ -n "$hp_tz" ] && { TZ="$hp_tz"; export TZ; }
	unset hp_tz
else
	unset TZ
fi

HP_DIR='/etc/homeproxy'
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
UPDATER_UC="${HP_DIR}/scripts/update_subscriptions.uc"
PID_FILE="${RUN_DIR}/subscription_update.pid"
OUT_FILE="${RUN_DIR}/subscription_update.out"
RC_FILE="${RUN_DIR}/subscription_update.rc"

# --- detach stage -----------------------------------------------------------
# 被调用成 `update_subscriptions_async.sh --detach` 时：fork 出真正的工作进程
# 并立刻退出，调用方的 popen() 因此在毫秒级返回。
#
# 脱管手段按运行时能力挑：iStoreOS 等精简 BusyBox 没有 nohup（早期内核更新
# 直接调 nohup，现场 `nohup: not found` + exit 127，下载连启动都没启动，
# 而 ubus 照样回成功），有 setsid 就用新会话，最后才是裸 `&`（Linux 上孤儿子
# 进程会被 reparent 到 init，足够）。
if [ "${1:-}" = "--detach" ]; then
	mkdir -p "$RUN_DIR" 2>/dev/null

	# SIG_IGN 会在 exec 后继续被继承，所以父进程设好再 fork 即可，不依赖外部命令。
	trap '' HUP

	if command -v nohup >/dev/null 2>&1; then
		nohup /bin/sh "$0" >/dev/null 2>&1 &
	elif command -v setsid >/dev/null 2>&1; then
		setsid /bin/sh "$0" >/dev/null 2>&1 &
	else
		/bin/sh "$0" >/dev/null 2>&1 &
	fi

	exit 0
fi
# ---------------------------------------------------------------------------

mkdir -p "$RUN_DIR" 2>/dev/null || exit 1

# 上一次运行的退出码绝不能当成本次结果：先前跑失败的 rc 会让第一次轮询
# 直接报「失败」，而这次其实刚起步。
rm -f "$RC_FILE" "$OUT_FILE" 2>/dev/null

echo $$ > "$PID_FILE"

cleanup() {
	rm -f "$PID_FILE" 2>/dev/null
}
trap cleanup EXIT

trap '' HUP
trap 'exit 1' INT TERM

# 一律用 ucode 显式执行：脚本自身的执行位（git mode）曾经是 644，直接调用会
# Permission denied，而 rpcd 的 file.exec 仍返回成功 —— 那条链路已经不再使用，
# 但这里保持 `ucode <脚本>` 的写法，免得再被同一块石头绊一次。
# --source 让日志能区分「面板按钮」与「cron / 单机场」，三者共用同一个抓取点。
if command -v ucode >/dev/null 2>&1; then
	ucode "$UPDATER_UC" --source "LuCI「更新全部订阅」按钮" > "$OUT_FILE" 2>&1
	rc=$?
else
	"$UPDATER_UC" --source "LuCI「更新全部订阅」按钮" > "$OUT_FILE" 2>&1
	rc=$?
fi

echo "$rc" > "$RC_FILE" 2>/dev/null
exit 0
