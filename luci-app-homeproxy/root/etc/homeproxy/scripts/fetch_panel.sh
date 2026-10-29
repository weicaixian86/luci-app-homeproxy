#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Download and install the web dashboard (external_ui) without involving the
# sing-box core.
#
# Why this exists
# ---------------
# The panel used to be fetched exclusively through the core's own endpoint,
# `POST /upgrade/ui`. That path has three structural problems on a real
# router:
#
#   1. It is SINGLE-SOURCE. sing-box downloads `external_ui_download_url`
#      through `external_ui_download_detour` (usually direct-out) with no
#      mirror fallback, so on a line where one CDN is flaky the panel simply
#      never arrives.
#   2. It is SYNCHRONOUS and silent. The core answers only after the whole
#      archive is on disk, so a 9.5 MB zip at 17 KB/s looks like a frozen UI
#      for ten minutes and there is no progress to show.
#   3. It requires the core to be UP. The Clash API listener starts only after
#      every remote rule-set has been initialised, so a slow rule-set warm-up
#      blocks the panel download for reasons that have nothing to do with it.
#
# Downloading here removes all three: several mirrors in order, a zip magic
# check before anything is unpacked, and the result is installed straight into
# `external_ui`, which sing-box serves statically — no core, no API, no
# restart needed.

CONF="homeproxy"
# 显式固定 PATH：本脚本会被 init.d、LuCI（ubus）、install.sh 以不同环境调用，
# PATH 不全时 uci/curl 之类的调用会静默失败（stderr 多被 /dev/null 吞掉），
# 表现为「什么都没发生」而不是报错。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"
LOG_FILE="$RUN_DIR/panel_download.log"

# Total wall-clock budget for the whole mirror chain.
BUDGET=900
FORCE=0
QUIET=0
# 后台下载（服务正在给用户上网）时置 1：**绝不停服务**。面板只是一个静态
# 目录，为了它掐断全屋网络几分钟完全不值得 —— 失败就失败，用户可稍后手动更新。
NO_STOP_SERVICE=0

# 谁触发了这次面板下载，由调用方显式传入并写进日志。
# 以前面板日志只有「开始下载面板」，看不出是开机自动下、还是界面点了按钮，
# 出问题时只能靠时间戳猜。
SOURCE="手动执行（终端/SSH）"

log_msg() {
	mkdir -p "$RUN_DIR" 2>/dev/null
	local msg="面板: $*"
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$LOG_FILE" 2>/dev/null
	[ "$QUIET" = "1" ] || logger -t homeproxy "$msg" 2>/dev/null
	return 0
}

# 把字节数格式化为可读字符串（B/KB/MB/GB），便于日志阅读。
human_size() {
	local n="$1"
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	if [ "$n" -ge 1073741824 ]; then
		echo "$((n / 1073741824)) GB"
	elif [ "$n" -ge 1048576 ]; then
		echo "$((n / 1048576)) MB"
	elif [ "$n" -ge 1024 ]; then
		echo "$((n / 1024)) KB"
	else
		echo "${n} B"
	fi
	return 0
}

# 返回某目录所在分区的可用字节数（拿不到时返回 0，调用方应放行）。
disk_free_bytes() {
	local dir="$1" kb
	kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
	case "$kb" in ''|*[!0-9]*) echo 0; return ;; esac
	echo $((kb * 1024))
	return 0
}

# ---------------------------------------------------------------------------
# 单实例互斥
#
# 面板下载有三个触发源：init.d 启动预取、cron/规则集流程、LuCI「更新面板」
# 按钮，三者完全可能撞在一起。并发下载不仅浪费带宽，还会让同一个
# $panel_dir 被两个进程交替 rm -rf / cp，最后留下半套文件。
# 用 mkdir 当锁（POSIX 上是原子的，且不依赖 lock/flock 这类不一定存在的
# applet）；持锁进程被 kill 或重启留下的陈旧锁，按 pid 是否存活清理。
# ---------------------------------------------------------------------------
LOCK_DIR="$RUN_DIR/panel-download.lock"
LOCK_HELD=0

lock_acquire() {
	local holder=""
	mkdir -p "$RUN_DIR" 2>/dev/null
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
		LOCK_HELD=1
		return 0
	fi
	holder="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
	if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
		return 1
	fi
	# 有锁目录但持有者已不在：陈旧锁，清掉重来
	rm -rf "$LOCK_DIR" 2>/dev/null
	mkdir "$LOCK_DIR" 2>/dev/null || return 1
	printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
	LOCK_HELD=1
	return 0
}

lock_release() {
	# 只删自己持有的锁：没拿到锁就退出时绝不能把别人的锁清掉
	[ "$LOCK_HELD" = "1" ] || return 0
	rm -rf "$LOCK_DIR" 2>/dev/null
	LOCK_HELD=0
	return 0
}

usage() {
	cat <<'EOF'
Usage: fetch_panel.sh [options]

  --force        re-download even when index.html already exists
  --budget N     total time budget in seconds (default 900)
  --quiet        do not log to syslog
  --no-stop-service  never stop homeproxy to get a direct link (background runs)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1 ;;
		--quiet) QUIET=1 ;;
		--no-stop-service) NO_STOP_SERVICE=1 ;;
		--source)
			shift
			case "${1:-}" in
				''|-*) log_msg "错误：--source 需要一段说明文字（谁触发了这次下载）"; exit 2 ;;
			esac
			SOURCE="$1"
			;;
		--budget)
			shift
			case "$1" in
				''|*[!0-9]*) log_msg "错误：--budget 需要一个数字"; exit 2 ;;
			esac
			BUDGET="$1"
			;;
		-h|--help) usage; exit 0 ;;
		*) log_msg "错误：未知参数 $1"; usage; exit 2 ;;
	esac
	shift
done

# 面板目录来自用户输入（LuCI「UI 路径」），后面会被 rm -rf / mv 直接操作。
# 规则与 rpcd 侧 sanitizePanelDir() 一致：绝对路径、至少两级、不含 `..`、
# 不落在系统目录，/etc 下只允许本应用目录；不合规一律回落默认目录。
sanitize_panel_dir() {
	local d="$1" p
	case "$d" in
		/*) ;;
		*) printf '%s' "$HP_DIR/run/ui"; return 0 ;;
	esac
	d="$(printf '%s' "$d" | sed 's#//*#/#g; s#/$##')"
	case "/$d/" in
		*/../*) printf '%s' "$HP_DIR/run/ui"; return 0 ;;
	esac
	case "$d" in
		/*/*) ;;
		*) printf '%s' "$HP_DIR/run/ui"; return 0 ;;
	esac
	for p in /bin /sbin /lib /usr /proc /sys /dev /overlay /rom /boot /tmp /var; do
		case "$d" in
			"$p"/*) printf '%s' "$HP_DIR/run/ui"; return 0 ;;
		esac
	done
	case "$d" in
		/etc/*)
			case "$d" in
				/etc/homeproxy/*) ;;
				*) printf '%s' "$HP_DIR/run/ui"; return 0 ;;
			esac
			;;
	esac
	printf '%s' "$d"
	return 0
}

panel_dir="$(uci -q get "$CONF.clash_api.external_ui" 2>/dev/null)"
[ -n "$panel_dir" ] || panel_dir="$HP_DIR/run/ui"
panel_dir="$(sanitize_panel_dir "$panel_dir")"
panel_url="$(uci -q get "$CONF.clash_api.external_ui_download_url" 2>/dev/null)"

if [ "$FORCE" != "1" ] && [ -f "$panel_dir/index.html" ]; then
	[ "$QUIET" = "1" ] || log_msg "面板已存在（来源=「$SOURCE」，$panel_dir/index.html），跳过下载。"
	exit 0
fi

if [ -z "$panel_url" ]; then
	log_msg "下载失败：未配置 external_ui_download_url。"
	exit 1
fi

# ---------------------------------------------------------------------------
# Mirror chain
# ---------------------------------------------------------------------------

# Strip a known GitHub proxy wrapper, leaving the real upstream URL.
# Pure shell (no sed -E): BusyBox sed on older OpenWrt builds rejects -E.
strip_proxy_prefix() {
	local u="$1"
	case "$u" in
		http://gh-proxy.com/*|https://gh-proxy.com/*|\
		http://ghproxy.net/*|https://ghproxy.net/*|\
		http://ghproxy.com/*|https://ghproxy.com/*|\
		http://mirror.ghproxy.com/*|https://mirror.ghproxy.com/*|\
		http://ghfast.top/*|https://ghfast.top/*|\
		http://gh.api.kkgithub.com/*|https://gh.api.kkgithub.com/*)
			printf '%s' "${u#*://*/}"
			return 0
			;;
	esac
	printf '%s' "$u"
	return 0
}

# 候选列表，每条是「模式 URL」：P = 经本地代理，D = 直连。
#
# 顺序：**原地址走代理优先**（用户配置的 URL 只取其中的 GitHub 原地址，
# 镜像前缀先剥掉）。代理能用时它是唯一一条又完整又快的路；镜像服务器本身
# 也是替我们回 GitHub 取，多绕一圈只会更慢。
# 代理不可用时（mode=direct，此时已停服务）才用镜像地址走直连——镜像存在
# 的意义正是「直连可达」。
build_candidates() {
	local url="$1" mode="${2:-auto}" direct
	direct="$(strip_proxy_prefix "$url")"

	# auto 轮**只**给代理那条：这一轮里任何「直连」请求在服务运行时都会被
	# tproxy 劫持回当前节点，等于用同一个（可能已坏掉的）节点再试一次，
	# 白白多等一轮超时。直连是第二轮的职责——那一轮会先停服务。
	if [ "$mode" = "auto" ]; then
		printf 'P|%s\n' "$direct"
		return 0
	fi

	# 直连轮：镜像在前、原地址最后。镜像存在的意义就是「直连可达」，
	# 而直连 github.com 实测只有 60~80 KB/s 且经常断，放前面会把预算耗光。
	case "$direct" in
		https://github.com/*|http://github.com/*)
			printf 'D|%s\n' "https://gh-proxy.com/${direct}"
			printf 'D|%s\n' "https://ghproxy.net/${direct}"
			printf 'D|%s\n' "https://ghfast.top/${direct}"
			;;
	esac
	printf 'D|%s\n' "$direct"
	return 0
}

# Last HTTP status seen by download_with_progress(); reported when every mirror
# fails so the log says *why* (404 vs timeout vs TLS error).
LAST_HTTP=""

# 带进度显示的下载：后台运行 curl 并轮询已下载字节，按百分比/可读字节数
# 写日志，避免单文件大下载（面板约 9.5MB）期间日志长时间无输出、看起来像卡死。
# 这是本脚本唯一的下载入口（旧的静默 download_to 已删除，避免两套超时参数
# 与镜像策略各走一路、彼此不一致）。
download_with_progress() {
	local url="$1" out="$2" max="$3" label="$4" via_proxy="${5:-}"
	LAST_HTTP=""
	local total=0 cur=0 pct=0 last_pct=0 last_time=0 last_cur=0 pid rc codefile now

	if command -v curl >/dev/null 2>&1; then
		codefile="$out.code"
		# HEAD 探测总大小；部分镜像（如 gh-proxy）可能不支持 HEAD，
		# 此时 total=0，退化为只显示已下载字节数。
		if [ -n "$via_proxy" ]; then
			total="$(curl -sI --connect-timeout 20 --proxy "$via_proxy" "$url" 2>/dev/null \
				| awk '{s=tolower($0)} s ~ /^content-length:/ {gsub(/\r/,"",$2); v=$2} END{print v+0}')"
		else
			total="$(curl -sI --connect-timeout 20 "$url" 2>/dev/null \
				| awk '{s=tolower($0)} s ~ /^content-length:/ {gsub(/\r/,"",$2); v=$2} END{print v+0}')"
		fi
		rm -f "$codefile" "$out"
		if [ -n "$via_proxy" ]; then
			curl -fsSL --connect-timeout 20 --proxy "$via_proxy" \
				--speed-limit 6144 --speed-time 60 --max-time "$max" \
				-o "$out" -w '%{http_code}' "$url" >"$codefile" 2>/dev/null &
		else
			curl -fsSL --connect-timeout 20 \
				--speed-limit 6144 --speed-time 60 --max-time "$max" \
				-o "$out" -w '%{http_code}' "$url" >"$codefile" 2>/dev/null &
		fi
		pid=$!
		while kill -0 "$pid" 2>/dev/null; do
			# curl 是后台启动的，输出文件可能尚未创建；此时 `wc -c < 文件`
			# 的 shell 重定向会在 stderr 报 "can't open ... no such file"。
			# 先判断文件存在再读取，缺失时按 0 处理。
			cur=0
			[ -f "$out" ] && cur="$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
			[ -z "$cur" ] && cur=0
			now=$(date +%s)
			if [ "$total" -gt 0 ]; then
				pct=$(( cur * 100 / total ))
				if [ "$pct" -ge "$((last_pct + 5))" ] || [ "$pct" -ge 100 ] || [ "$((now - last_time))" -ge 10 ]; then
					log_msg "$label 下载进度 ${pct}%（$(human_size "$cur")/$(human_size "$total")）：$url"
					last_pct=$pct; last_time=$now
				fi
			else
				if [ "$cur" -ge "$((last_cur + 1048576))" ] || [ "$((now - last_time))" -ge 10 ]; then
					log_msg "$label 已下载 $(human_size "$cur")（总大小未知）：$url"
					last_cur=$cur; last_time=$now
				fi
			fi
			sleep 1
		done
		wait "$pid"; rc=$?
		if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ]; then
			log_msg "$label 下载进度 100%（$(human_size "$total")/$(human_size "$total")）：$url"
		fi
		LAST_HTTP="$(cat "$codefile" 2>/dev/null | tr -d ' \r\n')"
		rm -f "$codefile"
	else
		if [ -n "$via_proxy" ]; then
			http_proxy="$via_proxy" https_proxy="$via_proxy" \
				wget -q -T "$max" -O "$out" "$url" >/dev/null 2>&1
		else
			wget -q -T "$max" -O "$out" "$url" >/dev/null 2>&1
		fi
		rc=$?
	fi
	return $rc
}


# A real zip starts with "PK\x03\x04". Mirror error pages are HTML and would
# otherwise be extracted into "nothing" with a confusing failure later.
valid_zip() {
	[ -s "$1" ] || return 1
	[ "$(head -c 2 "$1" 2>/dev/null)" = "PK" ] || return 1
	return 0
}

unzip_cmd() {
	if command -v unzip >/dev/null 2>&1; then
		printf 'unzip'
	elif busybox --list 2>/dev/null | grep -qx unzip; then
		printf 'busybox unzip'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Download pass
# ---------------------------------------------------------------------------

# 下载盘预检：面板先下载到临时目录再解压，临时目录默认在 /tmp（内存盘）。
# 内存盘空间有限（尤其是小内存路由器），不足时改到 /etc/homeproxy（overlay 闪存）。
if [ "$(disk_free_bytes /tmp)" -lt 31457280 ]; then
	work="${HP_DIR}/run/panel_tmp.$$"
	log_msg "面板：/tmp 可用空间不足 30MB，临时目录改用 ${work}。"
else
	work="/tmp/homeproxy_panel.$$"
fi
zip="$work/dist.zip"
extract="$work/extract"
stage="$work/stage"
backup="$panel_dir.backup"

# 本地代理入口（mixed-inbound）：优先走它拉原地址，代理不可用时才退回镜像直连。
proxy_endpoint() {
	local port

	port="$(uci -q get "$CONF.infra.mixed_port" 2>/dev/null)"
	[ -n "$port" ] || return 1

	printf 'http://127.0.0.1:%s' "$port"
}

# 第二轮（直连轮）前要停一次服务：服务运行时路由器自身出站被 tproxy 劫持，
# 「直连镜像」其实还是走当前节点；节点坏了就等于所有镜像一起坏。停服务会走
# firewall_teardown 撤掉 nft 与 DNS 劫持，这一轮才是真的直连。
# 用 EXIT trap 兜底恢复，脚本被 Ctrl-C / 被 sleep 打断也不会把局域网挂在
# 「代理停了」的状态上。
panel_stopped=""

# 服务是否在运行。**不走 `init.d running`**：rc.common 的每个动作都要拿
# procd 锁（`lock -w`，没有超时），而这里只是想知道一个事实 —— 0.2.14 现场
# 一个 `init.d running` 与 start 互等十分钟就是这么来的。
service_running() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -f '[s]ing-box run' >/dev/null 2>&1
	else
		ps w 2>/dev/null | grep -q '[s]ing-box run'
	fi
}

stop_service_for_direct() {
	[ -n "$panel_stopped" ] && return 1

	# 后台下载时服务可能正在给用户上网：为了一块面板掐断全屋网络几分钟，
	# 代价和收益完全不成比例。直接放弃这一轮，日志留痕。
	if [ "$NO_STOP_SERVICE" = "1" ]; then
		log_msg "跳过「临时停服务走直连」：本次是后台下载，不停正在运行的服务（面板不影响上网；失败可稍后在面板设置里手动更新）。"
		return 1
	fi

	service_running || return 1

	log_msg "代理不可用，临时停止 homeproxy 改用直连重试（下载结束后自动恢复服务）"
	/etc/init.d/homeproxy stop >/dev/null 2>&1
	panel_stopped=1
	sleep 2
	return 0
}

restore_service_after_direct() {
	[ -n "$panel_stopped" ] || return 0
	panel_stopped=""

	if /etc/init.d/homeproxy start >/dev/null 2>&1; then
		log_msg "已重新启动 homeproxy。"
	else
		log_msg "警告：homeproxy 未能自动重新启动，请到「服务状态」页确认，必要时手动执行 /etc/init.d/homeproxy start"
	fi
	return 0
}

cleanup() {
	restore_service_after_direct
	lock_release
	rm -rf "$work" 2>/dev/null
	return 0
}

rm -rf "$work" 2>/dev/null
mkdir -p "$work" "$extract" "$stage" 2>/dev/null || { log_msg "下载失败：无法创建临时目录 $work"; exit 1; }
trap cleanup EXIT INT TERM

# 拿到锁之后再开始下载。抢不到说明另一个进程正在下载同一份面板：它做的
# 正是本脚本要做的事，直接让路（rc 0，调用方会自行检查 index.html）。
if ! lock_acquire; then
	log_msg "另一个面板下载任务正在运行，本次跳过。"
	exit 0
fi

deadline=$(( $(date +%s) + BUDGET ))
got=0
codes=""
used_url=""

log_msg "开始下载面板（来源=「$SOURCE」，不依赖 clash API）：$panel_url"

# 两轮：
#   第一轮 auto  —— 原地址走本地代理（代理能用时最快最完整）
#   第二轮 direct —— 先停服务撤掉 tproxy，再用镜像地址真直连
# 每组内部仍是「逐条试、成功即停」。第一轮若在原地址就成功，第二轮连
# 停服务这一步都不会发生。
for round in auto direct; do
	if [ "$round" = "direct" ]; then
		stop_service_for_direct || true
	fi

	for candidate in $(build_candidates "$panel_url" "$round" | awk '!seen[$0]++'); do
		candidate_mode="${candidate%%|*}"
		candidate_url="${candidate#*|}"
		via_proxy=""

		if [ "$candidate_mode" = "P" ]; then
			via_proxy="$(proxy_endpoint)" || via_proxy=""

			# 读不到 mixed 端口（老配置没写 / uci 异常）就当没有代理，
			# 跳过这条直接进直连轮。
			[ -z "$via_proxy" ] && continue
		fi

		now=$(date +%s)
		left=$((deadline - now))
		if [ "$left" -lt 15 ]; then
			log_msg "预算 ${BUDGET}s 用尽，停止尝试。"
			break 2
		fi

		rm -f "$zip" 2>/dev/null
		if [ -n "$via_proxy" ]; then
			log_msg "面板：经代理 ${via_proxy} 下载原地址：$candidate_url"
		else
			log_msg "面板：直连下载：$candidate_url"
		fi

		if download_with_progress "$candidate_url" "$zip" "$left" "面板" "$via_proxy"; then
			if valid_zip "$zip"; then
				got=1
				used_url="$candidate_url"
				log_msg "已取到面板包（$(human_size "$(wc -c < "$zip" 2>/dev/null | tr -d ' ')")）：$candidate_url（$([ -n "$via_proxy" ] && printf '经代理' || printf '直连')）"
				break
			fi
			# Exit status 0 but not a zip: a mirror that answers 200 with an HTML
			# placeholder page. Installing that is exactly how a "downloaded"
			# dashboard ends up as a blank screen, so drop it and move on.
			log_msg "镜像返回的不是 zip（HTTP ${LAST_HTTP:-000}，$(human_size "$(wc -c < "$zip" 2>/dev/null | tr -d ' ')")），已丢弃：$candidate_url"
		else
			log_msg "镜像不可用或传输中断（HTTP ${LAST_HTTP:-000}）：$candidate_url"
		fi
		codes="$codes ${LAST_HTTP:-000}"
	done

	[ "$got" = "1" ] && break
done


if [ "$got" != "1" ]; then
	log_msg "下载失败：所有镜像均不可用（HTTP 状态：${codes# }）。"
	case "$panel_url" in
		*github.com*)
			log_msg "提示：可把「面板下载地址」换成 https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip 或 https://ghfast.top/ 前缀的其他镜像。"
			;;
	esac
	exit 1
fi

# ---------------------------------------------------------------------------
# Extract + install
# ---------------------------------------------------------------------------

unzipper="$(unzip_cmd)"
if [ -z "$unzipper" ]; then
	cp -f "$zip" /tmp/homeproxy_panel_manual.zip 2>/dev/null
	log_msg "下载失败：系统没有 unzip（可执行 opkg update && opkg install unzip 后重试）。"
	[ -f /tmp/homeproxy_panel_manual.zip ] \
		&& log_msg "面板包已另存为 /tmp/homeproxy_panel_manual.zip，可在「面板」页用「上传面板」手动安装。"
	exit 1
fi

if ! $unzipper -oq "$zip" -d "$extract" >/dev/null 2>&1; then
	log_msg "下载失败：面板包解压失败，可能下载不完整。"
	exit 1
fi

# zashboard ships the site either at the top level or inside a single `dist/`
# wrapper; walk down while the directory holds exactly one sub-directory.
src_dir="$extract"
depth=0
while [ "$depth" -lt 3 ]; do
	[ -f "$src_dir/index.html" ] && break
	entry_count=0
	first_entry=""
	for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
		[ -e "$entry" ] || continue
		case "$(basename "$entry")" in
			__MACOSX|.DS_Store) continue ;;
		esac
		entry_count=$((entry_count + 1))
		[ -n "$first_entry" ] || first_entry="$entry"
	done
	if [ "$entry_count" -eq 1 ] && [ -d "$first_entry" ]; then
		src_dir="$first_entry"
		depth=$((depth + 1))
	else
		break
	fi
done

if [ ! -f "$src_dir/index.html" ]; then
	log_msg "下载失败：面板包内找不到 index.html（包的目录结构与预期不同）。"
	exit 1
fi

copied=0
for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
	[ -e "$entry" ] || continue
	cp -a "$entry" "$stage"/ 2>/dev/null && copied=1
done

if [ "$copied" != "1" ] || [ ! -f "$stage/index.html" ]; then
	log_msg "下载失败：无法写入临时安装目录。"
	exit 1
fi

# Swap in the new panel only once a complete copy exists, keeping the old one
# until the move succeeds — a failed install must never leave no panel at all.
rm -rf "$backup" 2>/dev/null
[ -d "$panel_dir" ] && mv "$panel_dir" "$backup" 2>/dev/null
mkdir -p "$panel_dir" 2>/dev/null
if ! cp -a "$stage"/. "$panel_dir"/ 2>/dev/null || [ ! -f "$panel_dir/index.html" ]; then
	rm -rf "$panel_dir" 2>/dev/null
	[ -d "$backup" ] && mv "$backup" "$panel_dir" 2>/dev/null
	log_msg "下载失败：安装面板到 $panel_dir 失败，已回滚到原有面板。"
	exit 1
fi
rm -rf "$backup" 2>/dev/null

# The core may run as the `sing-box` user (ujail); keep the panel readable.
if grep -qs '^sing-box:' /etc/passwd; then
	chown -R sing-box:sing-box "$panel_dir" 2>/dev/null
fi

log_msg "安装完成：$panel_dir/index.html（来源 $used_url）"
exit 0
