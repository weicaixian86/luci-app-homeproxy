#!/bin/sh
#
# Detached launcher for the core download/update helper.
#
# WHY THIS EXISTS
# ---------------
# A core tarball is 34 MB and the only usable mirror measured 17-132 KB/s on
# the target router, i.e. 4 to 33 minutes for one download. The RPC used to
# popen() update_core.sh directly and read until EOF, so the HTTP request
# stayed open for the entire transfer; uhttpd eventually dropped it and the
# helper usually died with the connection, which is why the UI reported a
# failure with an empty log.
#
# This wrapper runs the helper detached from the request, records its exit
# status and stdout, and lets the RPC return immediately. The UI polls
# singbox_core_progress until the pid file disappears.
#
# Contract (paths shared with luci.homeproxy):
#   $RUN_DIR/core_update.pid  present while the update is running
#   $RUN_DIR/core_update.out  stdout/stderr of the helper (ok / failed / ...)
#   $RUN_DIR/core_update.rc   exit status of update_core.sh, written last
#
# The rc file is written after the helper returns and the pid file is removed
# on exit, so "rc present + pid absent" unambiguously means "finished". A
# stale pid file can therefore never make the UI believe a finished run is
# still in progress.

set -u

# procd 锁的 fd 是 1000（rc.common 的 procd_lock），start_service 里派生这个脚本时
# 会被继承：本脚本跑多久，那把锁就被占多久，期间所有 start/stop/reload 都卡在
# 阻塞的 flock 上（2026-10-30 现场：内核下载 26 MB 期间服务起不来、reload 排队）。
# 而且本脚本收尾会回调 init.d start —— 持有继承来的锁去等自己，直接自锁。
exec 1000>&- 2>/dev/null

HP_DIR='/etc/homeproxy'
RUN_DIR='/var/run/homeproxy'
CORE_SCRIPT="${HP_DIR}/scripts/update_core.sh"
PID_FILE="${RUN_DIR}/core_update.pid"
OUT_FILE="${RUN_DIR}/core_update.out"
RC_FILE="${RUN_DIR}/core_update.rc"

# --- detach stage -----------------------------------------------------------
# Called as `update_core_async.sh --detach`, this forks the real worker and
# exits at once, so the caller's popen() returns immediately.
#
# The detach helper is picked at runtime because the available set differs
# between images: iStoreOS ships no `nohup` (the RPC used to call it directly,
# which failed with exit 127 before anything ran), while stock OpenWrt has it.
# `setsid` gives a new session when available; a plain `&` is the POSIX
# last resort and is enough on Linux, where the orphan is reparented to init.
if [ "${1:-}" = "--detach" ]; then
	shift
	mkdir -p "$RUN_DIR" 2>/dev/null

	# 参数必须原样带给 worker：`--source`（日志里谁发起的）和
	# `--start-after`（下完自己把服务拉起来）都是调用方的语义，
	# 这里吞掉就等于没传。
	if command -v nohup >/dev/null 2>&1; then
		nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &
	elif command -v setsid >/dev/null 2>&1; then
		setsid /bin/sh "$0" "$@" >/dev/null 2>&1 &
	else
		/bin/sh "$0" "$@" >/dev/null 2>&1 &
	fi

	exit 0
fi

# --- worker arguments -------------------------------------------------------
#   --source <文本>   谁发起的（写进 core_download.log，排查时区分
#                     面板按钮 / 服务启动 / cron）
#   --start-after     下载成功后自己执行 init.d start —— 服务启动路径把内核
#                     下载转后台时靠它收尾，用户不需要再点一次
SRC="LuCI「更新内核」按钮"
START_AFTER=0
while [ $# -gt 0 ]; do
	case "$1" in
		--source) shift; [ -n "${1:-}" ] && SRC="$1" ;;
		--start-after) START_AFTER=1 ;;
		--detach) : ;;
	esac
	shift
done
# ---------------------------------------------------------------------------

mkdir -p "$RUN_DIR" 2>/dev/null || exit 1

# A previous run's status must never be mistaken for this run's result.
rm -f "$RC_FILE" "$OUT_FILE" 2>/dev/null

echo $$ > "$PID_FILE"

cleanup() {
	rm -f "$PID_FILE" 2>/dev/null
}
trap cleanup EXIT

# Ignore SIGHUP instead of relying on `nohup` in the caller: minimal BusyBox
# images (iStoreOS among them) do not always ship nohup, and the launcher then
# dies with exit 127 before running anything — the download silently never
# starts while the UI waits for a progress file that is never created.
trap '' HUP
trap 'exit 1' INT TERM

# stdout carries the machine-readable verdict ("ok" / "unsupported" /
# "no_asset" / "failed"); stderr is merged in so a fatal shell error (bad
# syntax, missing interpreter) is preserved for the UI instead of vanishing.
/bin/sh "$CORE_SCRIPT" update --source "$SRC" > "$OUT_FILE" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then
	# 失败时把「具体原因」补进 out：面板只看 out 与 rc，而 core_download.log
	# 里既有真正的失败行，也有「提示：若系统时间未同步…」这类建议性文案；
	# 不筛一下就会把用户引去查 NTP（0.2.13 现场踩过）。
	reason="$(grep -v '提示：' "$RUN_DIR/core_download.log" 2>/dev/null \
		| grep -E '内核缺失|下载失败（返回码|暂不支持|未找到' \
		| tail -n 1 | sed 's/^.*download : //')"
	[ -n "$reason" ] && printf 'failed: %s\n' "$reason" >> "$OUT_FILE"
fi

echo "$rc" > "$RC_FILE" 2>/dev/null

if [ "$rc" -eq 0 ] && [ "$START_AFTER" = "1" ]; then
	# 后台下载的收尾：内核就绪后自己把服务拉起来。这时 check 一定返回
	# 「ready」，启动路径不会再触发第二次下载，也就不会自己等自己。
	# 注意这里是**直接执行** init.d，没有 `sh ` 前缀：那个脚本的 shebang 是
	# `#!/bin/sh /etc/rc.common`，靠它才会 source 到 rc.common 并派发 start。
	# 用解释器硬跑（`sh <路径> start`）会跳过 shebang：函数定义完就结束，
	# 退出码 0 却什么都没干 —— 服务静默不启动，日志里连一行都没有。
	/etc/init.d/homeproxy start >"$RUN_DIR/core_update.start.log" 2>&1 || true
fi

exit 0
