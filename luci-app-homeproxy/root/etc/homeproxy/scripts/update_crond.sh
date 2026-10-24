#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 ImmortalWrt.org
#
# cron 在登录 shell 之外运行，PATH 只有最小集合（精简 BusyBox 上连 /usr/sbin
# 都不一定有）。这里显式补上，否则下面脚本里的 curl / md5sum / tar 会「找不到
# 命令」，而 cron 不会把这句话写进任何日志 —— 用户看到的就是「到了时间什么都
# 没发生」。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ── 时区修正：必须放在任何 date / ucode 调用之前 ─────────────────────────────
# ucode 是 C 程序跑在 musl 上，musl 的 localtime 只认 POSIX 串（如 CST-8）和
# IANA 名，**不支持「冒号 + 任意 TZif 路径」** 那种 Go 才认的写法；解析失败会
# 静默回退 UTC，于是订阅日志的时间比 shell 的 date 早 8 小时（面板按钮那条链路
# 会继承内核的 `TZ=:/var/run/homeproxy/core.zone`，已实测到 11:51:52 vs
# 19:51:52）。cron 的环境同样不保证有 TZ，所以这里统一改回系统时区：优先
# /etc/TZ（OpenWrt 标准的 POSIX 串），都没有就 unset，让 libc 走默认路径。
if [ -s /etc/TZ ]; then
	hp_tz="$(cat /etc/TZ 2>/dev/null)"
	[ -n "$hp_tz" ] && { TZ="$hp_tz"; export TZ; }
	unset hp_tz
else
	unset TZ
fi

SCRIPTS_DIR="/etc/homeproxy/scripts"
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
LOG_FILE="$RUN_DIR/homeproxy.log"

mkdir -p "$RUN_DIR" 2>/dev/null

log() {
	printf '%s [SCHEDULE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
	logger -t homeproxy "$*" 2>/dev/null
}

started="$(date +%s)"
log "==== 定时任务开始：内置资源 + 订阅（cron）===="

# 给 update_subscriptions.uc 留个「这次是定时任务触发的」标记：它自己分不清
# 手动按钮和 cron，日志里就只能含糊地写「更新开始」。文件用 trap 兜底删除，
# 脚本被中断也不会留下过期标记把下一次手动更新标错。
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$RUN_DIR/schedule-run" 2>/dev/null
trap 'rm -f "$RUN_DIR/schedule-run" 2>/dev/null' EXIT INT TERM

for i in "china_ip4" "china_ip6" "gfw_list" "china_list"; do
	log "更新内置资源：$i"
	/bin/sh "$SCRIPTS_DIR/update_resources.sh" "$i"
	[ "$?" = "0" ] || log "内置资源 $i 更新失败（update_resources.sh 返回非 0）"
done

log "开始更新订阅…"

# 用 ucode 显式执行：脚本自身如果少了执行位（644），直接调用会
# "Permission denied"，而 cron 把这句话吞掉，日志里只剩下一片空白。
# --source 显式告诉脚本「这次是定时任务」：脚本自己也看 schedule-run 标记，
# 但那是间接证据（标记文件残留就会标错），调用方直接说清楚更可靠。
if command -v ucode >"/dev/null" 2>&1; then
	ucode "$SCRIPTS_DIR/update_subscriptions.uc" --source "定时任务（cron，update_crond.sh）"
	rc="$?"
else
	"$SCRIPTS_DIR/update_subscriptions.uc" --source "定时任务（cron，update_crond.sh）"
	rc="$?"
fi

[ "$rc" = "0" ] || log "订阅更新脚本以非 0 退出（rc=$rc），明细见上面的 [SUBSCRIBE] 行"

log "==== 定时任务结束：用时 $(( $(date +%s) - started )) 秒 ===="
