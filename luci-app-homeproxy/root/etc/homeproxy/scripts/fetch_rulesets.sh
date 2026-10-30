#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Pre-download homeproxy rule-sets into the local cache, validating each file,
# so that sing-box can be configured with `type: local` and start without any
# network I/O.
#
# Why this exists
# ---------------
# With `type: remote`, sing-box fetches every enabled rule-set while it is
# initialising, BEFORE it starts listening on the Clash API. On a line where a
# single mirror is reachable this means N sequential downloads: the log shows
# one "outbound connection to gh-proxy.com:443" every 4-6 s, and startup takes
# minutes. Two failure modes follow:
#
#   1. The Clash API never comes up in time, so the web panel is never
#      downloaded ("等待 clash API 就绪超时").
#   2. A mirror answers 404/502 with an HTML page and sing-box happily saves it
#      as `<tag>.srs`. The binary decoder then aborts the whole instance, and
#      because the size varies between requests it is easy to mistake for a
#      truncated but genuine download.
#
# Downloading here, out of band, with a magic-number check and an explicit
# mirror fallback chain removes both. generate_client.uc then emits `local`
# whenever a validated copy exists and falls back to `remote` only when there
# is none, so a broken line still behaves exactly as it used to.

# 显式固定 PATH。本脚本会被 procd（init.d）、install.sh、cron、LuCI（ubus）
# 各自以完全不同的环境变量调用。PATH 里少了 /sbin 时 `uci` 直接
# command not found，而所有 uci 调用的 stderr 都被 /dev/null 吞掉，于是
# 「一条规则集都扫不到」和「用户根本没配规则集」在日志里一模一样。
# 0.1.19 现场就是这样：配置里 21 条 enabled=1/remote 的规则集，启动日志却
# 报「当前没有已启用的远程规则集」，且没有任何报错可查。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# --detach：自我脱管（后台 + 忽略 SIGHUP + 三处重定向）。
# ⚠️ 不能用 nohup：iStoreOS 等精简 BusyBox 没有 nohup（现场 `nohup: not found`，
# 前台得到 Done(127)，后台连进程都不存在）。而 rpcd 的 ruleset_sync 之前正是
# 用 `nohup ... &` 启动下载的 —— 于是 ubus 返回成功、日志里却一行规则集都没有，
# 「点了保存并应用不下规则集」的真正原因就在这里。
# POSIX 规则：SIG_IGN 会被 fork 出的子进程继承、且 exec 后仍保持忽略，
# 所以父进程设好 trap 再 fork 即可，不依赖任何外部命令。
if [ "$1" = "--detach" ]; then
	shift
	trap '' HUP
	/bin/sh "$0" "$@" </dev/null >/dev/null 2>&1 &
	exit 0
fi

CONF="homeproxy"
# 允许覆盖，便于自检时用临时文件演练「uci 读不出来」的兜底路径。
CONF_FILE="${CONF_FILE:-/etc/config/$CONF}"

# uci 是否可用。不可用时用一个同名 shell 函数顶掉外部命令，让所有 uci 调用
# 安静地失败（返回非 0、不刷满屏 command not found），由下级函数统一走
# CONF_FILE 兜底；--check 会额外输出一行 warn uci_missing 作为证据。
# 函数必须在 command -v 之后定义，否则这里自己就会先被匹配到。
if command -v uci >/dev/null 2>&1; then
	UCI_OK=1
else
	UCI_OK=0
	uci() { return 127; }
fi
# procd 锁的 fd 是 1000（rc.common 的 procd_lock），start_service 里派生这个脚本时
# 会被继承：本脚本跑多久，那把锁就被占多久，期间所有 start/stop/reload 都卡在
# 阻塞的 flock 上（2026-10-30 现场：内核下载 26 MB 期间服务起不来、reload 排队）。
# 而且本脚本收尾会回调 init.d start —— 持有继承来的锁去等自己，直接自锁。
# 只在真的被继承时才关：dash（CI 的 /bin/sh）对 fd>9 的重定向会直接报错退出，
# 而那时本来也没有锁可放 —— 无条件写会让 --check / --only 这些用例在 CI 里
# 一句输出都没有地以 127 退出（0.3.5 现场：16 项全红）。
if [ -e "/proc/$$/fd/1000" ]; then
	exec 1000>&- 2>/dev/null
fi

HP_DIR="/etc/homeproxy"
# HP_RULESET_DIR 同 HP_RUN_DIR：显式指定就原样使用，绝不回落到真机目录。
# 没有它，任何在本机跑过一次真实下载的环境都会在 /etc/homeproxy/ruleset
# 留下有效副本，自检里「--check 应报 missing=3」从此永远变绿/变红 ——
# 断言读到了机器上恰好存在的东西（0.1.22 的 CI「3 of 92」是同一类病）。
RULESET_DIR="${HP_RULESET_DIR:-$HP_DIR/ruleset}"
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
LOG_FILE="$RUN_DIR/ruleset_download.log"

# 运行目录降级。极个别固件上 /var/run 不可写（tmpfs 满、只读 overlay、
# 被同名普通文件占位），此时所有日志会“成功”写到无处可去：用户看到的现象
# 是「脚本跑了，日志文件却不存在」，完全无法判断卡在哪一步。
# 这里先试 /var/run，失败则整个 RUN_DIR（含日志与锁）一起挪到 /tmp，
# 保证「跑过就一定有日志」这个不变量成立。
# 注意只碰 RUN_DIR（易失的运行目录）；$RULESET_DIR 的创建留到下载段，
# 以免 `--check` 这个「只读校验」入口在磁盘上留下任何东西。
# HP_RUN_DIR 是给测试用的显式覆盖：指定了就**不再降级**，否则日志会被兜底
# 写到 /tmp 去，调用方按自己给的路径去读就会读到空。
if [ -n "${HP_RUN_DIR:-}" ]; then
	mkdir -p "$RUN_DIR" 2>/dev/null
elif ! mkdir -p "$RUN_DIR" 2>/dev/null || [ ! -d "$RUN_DIR" ]; then
	RUN_DIR="/tmp/homeproxy"
	LOG_FILE="$RUN_DIR/ruleset_download.log"
	mkdir -p "$RUN_DIR" 2>/dev/null
fi

# Total wall-clock budget in seconds. Whatever is not finished when it expires
# is simply left as `remote` for the core to fetch, i.e. the old behaviour.
BUDGET=600
# Per-file ceiling. Rule-sets are 10 KB - 5 MB, so this is generous.
PER_FILE_MAX=120

FORCE=0
CHECK_ONLY=0
QUIET=0
ONLY=""

# 这次下载是谁触发的。写进开始/结束横幅，让 ruleset_download.log 自己就能
# 回答「这批规则集哪来的」——以前只能靠预算秒数反推（600=面板、240=服务
# 启动、900=cron、90=页面按钮），而默认值和手动执行撞号，且脚本升级后预算
# 随时会变，这个隐式契约一断就没有第二条线索。现在由调用方显式传入。
SOURCE="手动执行（终端/SSH）"

# 下载结束后若服务未运行就把它拉起来。只有面板「保存并应用」这条路径传：
# 它把「同步规则集」从「重启服务」里拆出来后就没接回去，于是现场出现了
# 「规则集补齐了、插件还是未运行、新文件也没生效」——补全的意义只有服务
# 真的跑起来才成立。cron 路径不需要（update_rulesets.sh 末尾自己 restart），
# init.d 路径本来就在启动流程里。
AUTOSTART=0

log_msg() {
	local line

	line="$(date '+%Y-%m-%d %H:%M:%S') $*"

	mkdir -p "$RUN_DIR" 2>/dev/null

	# 写不进日志文件时绝不能静默：降级打到 stderr，调用方（init.d 的主日志
	# 重定向、终端、cron）都能接住。以前这一句静默失败，最后的结果是
	# 「脚本退出码 75/0，但任何地方都看不到原因」。
	if ! printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null; then
		printf '%s\n' "$line" >&2
	fi

	# 手动在终端执行（stdout 是 tty）时同步回显。否则「脚本一秒就返回、
	# 屏幕上什么都没有、日志文件还找不到」会让人以为脚本根本没干活 ——
	# 现场就是这样，把「无规则集」「让路给另一个任务」都藏了起来。
	[ -t 1 ] && printf '%s\n' "$line"

	[ "$QUIET" = "1" ] || logger -t homeproxy "$*" 2>/dev/null

	return 0
}

# 服务是否在运行。
# 不能 `kill -0` 判兄弟进程（某些 shell 下对非子进程恒失败，会得出「一直没
# 跑完」的错判），也不能假定有 pgrep（精简 BusyBox 常常没有）。先问 ubus
# ——procd 自己维护的状态，最准；没有 ubus 或查不到时退回看进程命令行。
hp_service_running() {
	if command -v ubus >/dev/null 2>&1; then
		if ubus call service list '{"name":"homeproxy"}' 2>/dev/null \
			| grep -q '"running": *true'; then
			return 0
		fi
	fi

	ps 2>/dev/null | grep -F 'sing-box' | grep -v -F 'grep' | grep -q -F 'run --config'
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

usage() {
	cat <<'EOF'
Usage: fetch_rulesets.sh [options]

  --force        re-download even when a valid local copy exists
  --budget N     total time budget in seconds (default 600)
  --check        verify only; exit 1 when some enabled rule-set has no valid
                 local copy (nothing is downloaded, nothing is written)
  --quiet        do not log to syslog
  --only NAME    download pass only handles the named rule-set
                 (NAME = section id 或 tag，如 ruleset_geosite_cn / geosite-cn；
                  tag 命中多段时报错并要求改用段名。LuCI「立即更新」按钮
                  传的是 section id；--check 模式忽略此参数)
  --detach       fork into background immediately (no nohup needed; the
                 minimal BusyBox on iStoreOS ships without it)
  --source TEXT  who asked for this run, printed in both banners, e.g.
                 "LuCI 保存并应用". Defaults to 手动执行（终端/SSH）.
  --autostart    when the pass finishes and the service is NOT running, start
                 it (only the LuCI save & apply path passes this)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1 ;;
		--check) CHECK_ONLY=1 ;;
		--quiet) QUIET=1 ;;
		--autostart) AUTOSTART=1 ;;
		--source)
			shift
			case "${1:-}" in
				''|-*) log_msg "错误：--source 需要一段说明文字（谁触发了这次下载）"; exit 2 ;;
			esac
			SOURCE="$1"
			;;
		--only)
			shift
			# 值可以是段名（ruleset_geosite_cn）也可以是 tag（geosite-cn）。
			# tag 一定带连字符，早先只放行 [A-Za-z0-9_] 时 `--only geosite-cn`
			# 在解析阶段就被判成「缺少参数」并 exit 2，用户看到的是
			# 「--only 需要一个规则集 section 名」，根本走不到下面的 tag 反查。
			case "${1:-}" in
				''|-|-*) log_msg "错误：--only 需要一个规则集名（段名或 tag）"; exit 2 ;;
				*[!A-Za-z0-9_.-]*) log_msg "错误：--only 只接受段名或 tag（字母、数字、下划线、点、连字符）"; exit 2 ;;
			esac
			ONLY="$1"
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Map a tag to a file name exactly like ruleset_file_name() in
# generate_client.uc, otherwise the local file lands next to the one the core
# expects and `local` would point at a missing path.
ruleset_file_name() {
	local name
	name="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g')"
	[ -n "$name" ] || name="ruleset"
	if [ "$2" = "source" ]; then
		printf '%s.json' "$name"
	else
		printf '%s.srs' "$name"
	fi
}

# Strip a known GitHub proxy wrapper, leaving the real upstream URL.
# Pure shell (no sed -E): BusyBox sed on older OpenWrt builds rejects -E, and a
# silent failure here would hand sing-box the wrapper URL as if it were direct.
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

# raw.githubusercontent.com/OWNER/REPO/REF/PATH
#   -> fastly.jsdelivr.net/gh/OWNER/REPO@REF/PATH
raw_to_jsdelivr() {
	local u="$1" rest owner repo ref tail
	case "$u" in
		http://raw.githubusercontent.com/*|https://raw.githubusercontent.com/*) ;;
		*) return 0 ;;
	esac

	rest="${u#*raw.githubusercontent.com/}"

	owner="${rest%%/*}"
	[ "$owner" != "$rest" ] || return 0
	rest="${rest#*/}"

	repo="${rest%%/*}"
	[ "$repo" != "$rest" ] || return 0
	rest="${rest#*/}"

	ref="${rest%%/*}"
	[ "$ref" != "$rest" ] || return 0
	tail="${rest#*/}"
	[ -n "$tail" ] || return 0

	printf 'https://fastly.jsdelivr.net/gh/%s/%s@%s/%s\n' "$owner" "$repo" "$ref" "$tail"
	return 0
}

# Ordered, de-duplicated candidate URLs for one rule-set.
build_candidates() {
	local url="$1" direct jsd
	direct="$(strip_proxy_prefix "$url")"
	jsd="$(raw_to_jsdelivr "$direct")"

	# jsdelivr first: it is a real CDN and is reachable from CN lines far more
	# reliably than gh-proxy, which is what makes start-up slow in the first
	# place.
	[ -n "$jsd" ] && printf '%s\n' "$jsd"
	printf '%s\n' "$direct"
	case "$direct" in
		https://github.com/*|https://raw.githubusercontent.com/*)
			printf 'https://gh-proxy.com/%s\n' "$direct" ;;
	esac
	[ "$url" != "$direct" ] && printf '%s\n' "$url"
	return 0
}

# A real binary rule-set starts with the "SRS" magic; a real source rule-set is
# a JSON object/array. A mirror error page is neither, which is the whole point
# of checking instead of trusting the exit status.
valid_ruleset() {
	local f="$1" fmt="$2"
	[ -s "$f" ] || return 1
	case "$fmt" in
		source)
			local c
			c="$(head -c 1 "$f" 2>/dev/null)"
			[ "$c" = "{" ] || [ "$c" = "[" ] || return 1
			;;
		*)
			[ "$(head -c 3 "$f" 2>/dev/null)" = "SRS" ] || return 1
			;;
	esac
	return 0
}

LAST_HTTP=""

# A URL that answered 404 is remembered for a while: retrying it on every
# start-up costs ~15 s per entry and can never succeed until the user fixes the
# URL. The marker stores the URL it was probed with, so editing the URL in LuCI
# invalidates it immediately. `--force` ignores markers entirely.
UNAVAIL_TTL=21600

mark_unavailable() {
	printf '%s\n%s\n' "$(date +%s)" "$2" > "$1" 2>/dev/null
	return 0
}

recently_unavailable() {
	local marker="$1" url="$2" ts prev now
	[ -f "$marker" ] || return 1
	[ "$FORCE" = "1" ] && return 1
	ts="$(sed -n '1p' "$marker" 2>/dev/null)"
	prev="$(sed -n '2p' "$marker" 2>/dev/null)"
	[ "$prev" = "$url" ] || return 1
	case "$ts" in ''|*[!0-9]*) return 1 ;; esac
	now=$(date +%s)
	[ $((now - ts)) -lt "$UNAVAIL_TTL" ]
}

download_to() {
	local url="$1" out="$2" max="$3"
	LAST_HTTP=""
	if command -v curl >/dev/null 2>&1; then
		# -f makes HTTP 4xx/5xx a failure instead of saving the error page.
		# -w still prints the status code on failure, which is what lets the
		# caller tell "mirror is down" (000) from "this file does not exist"
		# (404) — the latter is a config mistake, not a network problem.
		LAST_HTTP="$(curl -fsSL --connect-timeout 20 --max-time "$max" \
			-w '%{http_code}' -o "$out" "$url" 2>/dev/null)"
		return $?
	fi
	wget -q -T "$max" -O "$out" "$url" >/dev/null 2>&1
	return $?
}

# Resolve "<path><name>" from the UCI fields, mirroring ruleset_remote_path().
resolve_path() {
	local sec="$1" tag="$2" fmt="$3" p
	p="$(uci -q get "$CONF.$sec.remote_path")"
	[ -n "$p" ] || p="$(uci -q get "$CONF.$sec.path")"

	if [ -z "$p" ]; then
		printf '%s/%s' "$RULESET_DIR" "$(ruleset_file_name "$tag" "$fmt")"
	elif [ "${p%/}" != "$p" ]; then
		printf '%s%s' "$p" "$(ruleset_file_name "$tag" "$fmt")"
	else
		printf '%s' "$p"
	fi
}

# Every enabled remote rule-set, one section name per line.
# awk instead of `sed -E`: BusyBox sed without -E support would silently match
# nothing, and an empty list looks exactly like "nothing to do".
#
# A section WITHOUT an explicit `type` counts as remote. That is what the core
# assumes (sing-box defaults `rule_set.type` to "remote") and what the RPC
# layer already does (`sec.type || 'remote'` in ruleset_status/ruleset_update).
# Requiring a literal `type=remote` here made such sections invisible to the
# whole download chain: --check reported "nothing missing", the download pass
# exited before mkdir could even create /etc/homeproxy/ruleset, no log line
# was written, and the core quietly re-fetched every rule-set on each start.
# 所有 ruleset 段（不论启用与否），一行一个段名。
# 这里不用 `awk -F'[.=]'` + `NF==3`：BusyBox awk 的正则 FS 并非所有构建都
# 支持，一旦被当成普通字符串 '[...]' 处理，就一条段名都提取不到，而空列表
# 与「本来就没有规则集」完全无法区分。用 substr/index 纯位置判断，任何 awk
# 都能跑，并且能正确处理段名里带点、以及同名子键（xxx.enabled）的情况。
all_sections() {
	local out
	out="$(uci -q show "$CONF" 2>/dev/null | awk -v c="$CONF" '
		{
			line = $0
			eq = index(line, "=")
			if (eq == 0) next
			key = substr(line, 1, eq - 1)
			val = substr(line, eq + 1)
			# `=<type>` 只出现在段声明行（homeproxy.NAME=ruleset）；
			# 形如 NAME.enabled 的子键行右侧是取值，不会是段类型。
			# 注意：awk 的注释是 #，写成 /* */ 会报 unterminated regexp。
			if (val != "ruleset") next
			if (substr(key, 1, length(c) + 1) != c ".") next
			rest = substr(key, length(c) + 2)
			if (rest == "") next
			print rest
		}')"
	if [ -n "$out" ]; then
		printf '%s\n' "$out"
		return 0
	fi
	# uci 一句话都没解析出来时才走文件解析。正常情况下不会到这里；一旦
	# 到了，说明「拿不到段名」这个故障本身要被记录下来，而不是伪装成
	# 「用户没有配置规则集」—— 0.1.19 就是这样：界面里 5 条远程规则集，
	# start_service 却报告「当前没有已启用的远程规则集」。
	all_sections_from_file
	return 0
}

# 兜底：直接读 /etc/config/homeproxy 的 `config ruleset 'name'` 行。
# 不经过 uci 的输出格式，不会因为 uci 输出被改版/被截断而整段失效。
# 只覆盖具名段；匿名段（@ruleset[N]）只能靠 uci show 拿到，那种写法本插件
# 从不生成，故不在兜底范围内。
all_sections_from_file() {
	[ -f "$CONF_FILE" ] || return 0
	awk '
		$1 == "config" && $2 == "ruleset" {
			name = $3
			if (name == "") next
			c1 = substr(name, 1, 1)
			if (c1 == "\047" || c1 == "\"") name = substr(name, 2)
			c2 = substr(name, length(name), 1)
			if (c2 == "\047" || c2 == "\"") name = substr(name, 1, length(name) - 1)
			if (name != "") print name
		}' "$CONF_FILE" 2>/dev/null
	return 0
}

# $1 = 段名，$2 = 选项名。直接从 CONF_FILE 里取某个 option 的值（去引号）。
# 只在 uci 取值为空时使用：兜底路径下 uci 很可能整体不可用，此时若一律
# 当作「未设置」，用户显式关掉的规则集也会被下载，属于静默违背配置。
conf_file_option() {
	[ -f "$CONF_FILE" ] || return 0
	awk -v s="$1" -v o="$2" '
		function unq(v) {
			c = substr(v, 1, 1)
			if (c == "\047" || c == "\"") v = substr(v, 2)
			c = substr(v, length(v), 1)
			if (c == "\047" || c == "\"") v = substr(v, 1, length(v) - 1)
			return v
		}
		$1 == "config" && $2 == "ruleset" { cur = unq($3); next }
		cur == s && $1 == "option" && $2 == o { print unq($3); exit }
	' "$CONF_FILE" 2>/dev/null
	return 0
}

# $1 = 段名。返回 0 表示启用。
# 未写 enabled 按「启用」处理，与界面语义保持一致：form.Flag 的 default
# 被设为 '1'，所以界面在 enabled 缺失时显示为勾选；而 LuCI 保存时
# rmempty=false 会把关闭状态明确写成 '0'。也就是说「缺失」只可能来自
# 没走过保存流程的旧段或备份还原，这时界面显示启用、后端却当成关闭，
# 就是最典型的「界面里明明开着，规则集却一条都不下载」。
section_enabled() {
	local v
	v="$(uci -q get "$CONF.$1.enabled")"
	[ -n "$v" ] || v="$(conf_file_option "$1" enabled)"
	case "$v" in
		0|false|no|off|disabled) return 1 ;;
	esac
	return 0
}

# $1 = 段名。未写 type 一律按 remote 处理，与内核/rpcd 的默认值保持一致。
section_type() {
	local t
	t="$(uci -q get "$CONF.$1.type")"
	[ -n "$t" ] || t="$(conf_file_option "$1" type)"
	[ -n "$t" ] || t="remote"
	printf '%s' "$t"
}

# Every enabled remote rule-set, one section name per line.
list_sections() {
	local sec
	all_sections | while read -r sec; do
		[ -n "$sec" ] || continue
		section_enabled "$sec" || continue
		[ "$(section_type "$sec")" = "remote" ] || continue
		printf '%s\n' "$sec"
	done
	return 0
}

# ---------------------------------------------------------------------------
# --check: report whether every enabled rule-set already has a valid copy
#
# 输出约定（init.d 依赖，勿随意改动）：
#   最后一行  sections=<全部 ruleset 段数> total=<纳入下载的段数> missing=<缺失数>
#   之前若干行 skip <段名> reason=<原因>   —— 每条被排除的段一行
# 之所以要把「为什么被排除」打出来：这几行是唯一能在现场区分
#   「界面显示已启用、UCI 里其实没有 enabled=1」
#   「类型是 local 所以本来就不下载」
#   「段名都提取不到」
# 的证据。没有它，三种情况的日志表现完全相同，只能靠反复猜。
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = "1" ]; then
	missing=0
	total=0
	sections=0
	for sec in $(all_sections); do
		sections=$((sections + 1))

		if ! section_enabled "$sec"; then
			skip_reason="$(uci -q get "$CONF.$sec.enabled")"
			[ -n "$skip_reason" ] || skip_reason="$(conf_file_option "$sec" enabled)"
			printf 'skip %s reason=enabled=%s\n' "$sec" "${skip_reason:-<unset>}"
			continue
		fi

		sec_type="$(section_type "$sec")"
		if [ "$sec_type" != "remote" ]; then
			printf 'skip %s reason=type=%s\n' "$sec" "$sec_type"
			continue
		fi

		total=$((total + 1))
		fmt="$(uci -q get "$CONF.$sec.format")"
		tag="$(uci -q get "$CONF.$sec.tag")"
		[ -n "$tag" ] || tag="cfg-$sec-rule"
		path="$(resolve_path "$sec" "$tag" "$fmt")"
		valid_ruleset "$path" "$fmt" && continue
		# A known-dead URL must not make every start-up re-probe it.
		url="$(uci -q get "$CONF.$sec.url")"
		recently_unavailable "$path.unavailable" "$url" && continue
		missing=$((missing + 1))
	done
	# 段名扫描失败的自证：uci 里确实有 ruleset 段，但 all_sections 一条都
	# 没解析出来。这种情况以前会表现成「当前没有已启用的远程规则集」，
	# 把解析器 bug 伪装成「用户没配置」，是最难查的一类静默失败。
	# uci 整体不可用时另有 warn：兜底能跑通不等于环境正常，必须留证，
	# 否则「一直靠兜底」这件事永远不会有人发现。
	if [ "$UCI_OK" = "0" ]; then
		if [ -f "$CONF_FILE" ]; then
			printf 'warn uci_missing source=file\n'
		else
			printf 'warn uci_missing source=none\n'
		fi
	elif [ "$sections" = "0" ]; then
		rs_raw="$(uci -q show "$CONF" 2>/dev/null | grep -c '=ruleset$')"
		case "$rs_raw" in ''|*[!0-9]*) rs_raw=0 ;; esac
		[ "$rs_raw" -gt 0 ] && \
			printf 'warn section_scan_failed uci_ruleset_lines=%s\n' "$rs_raw"
	fi

	# 无论是否缺失都输出统计，供 init.d 打印「共 N 条，缺失 M 条」：
	# 「保存并应用」时若本地副本都是有效的，日志里要能看到「已检查、跳过下载」，
	# 否则静默跳过和「根本没检查」在用户看来完全一样。
	printf 'sections=%s total=%s missing=%s\n' "$sections" "$total" "$missing"
	[ "$missing" -eq 0 ] && exit 0
	exit 1
fi

# ---------------------------------------------------------------------------
# 单实例互斥
#
# 规则集下载会被三处触发：init.d 启动预取、LuCI「立即更新」（--only）、
# 以及用户手动执行。并发时两个进程会同时写同一批 .srs，虽然用了临时文件
# + rename，仍会互相覆盖、白白占满带宽。
# mkdir 在 POSIX 上是原子的，用它当锁不依赖 lock/flock applet；
# 持锁者被 kill 留下的陈旧锁按 pid 是否存活清理。
# ---------------------------------------------------------------------------
LOCK_DIR="$RUN_DIR/rulesets-download.lock"
LOCK_HELD=0

# $1 = 最多等待秒数（0 表示拿不到就立刻返回 1）
lock_acquire() {
	local wait_s="${1:-0}" holder waited=0 tries=0

	mkdir -p "$RUN_DIR" 2>/dev/null

	while :; do
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
			LOCK_HELD=1
			return 0
		fi

		holder="$(cat "$LOCK_DIR/pid" 2>/dev/null)"

		if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
			[ "$waited" -ge "$wait_s" ] && return 1
			sleep 2
			waited=$((waited + 2))
			continue
		fi

		# 持有者已不在：陈旧锁，清掉后重试
		rm -rf "$LOCK_DIR" 2>/dev/null

		# 清锁后若仍 mkdir 不出来（$RUN_DIR 不可写、或 LOCK_DIR 被一个同名
		# 普通文件占着），旧实现是 `while :` 空转死循环：CPU 打满、服务启动
		# 永久卡住、且一行日志都不留。这里给上限并明确报错。
		tries=$((tries + 1))
		if [ "$tries" -ge 3 ]; then
			log_msg "错误：无法创建规则集下载锁 $LOCK_DIR（目录不可写或被同名文件占用），本次跳过下载。"
			return 1
		fi
		sleep 1
	done
}

lock_release() {
	# 只删自己持有的锁：没拿到锁就退出时绝不能把别人的锁清掉
	[ "$LOCK_HELD" = "1" ] || return 0
	rm -rf "$LOCK_DIR" 2>/dev/null
	LOCK_HELD=0
	return 0
}

# ---------------------------------------------------------------------------
# Download pass
# ---------------------------------------------------------------------------

mkdir -p "$RUN_DIR" "$RULESET_DIR" 2>/dev/null

if [ -n "$ONLY" ]; then
	# 「立即更新」必须给出真实结果：等正在跑的批量预下载腾出锁（最多 60s），
	# 等不到就明确失败，而不是假装成功。
	if ! lock_acquire 60; then
		log_msg "错误：另一个规则集下载任务仍在运行，稍后再试。"
		exit 1
	fi
elif ! lock_acquire 0; then
	# 75 = 让路（另一个任务在跑）。以前这里 exit 0，init.d 就把它当成
	# 「下载成功」并打印「N 条缺失已补齐」—— 明明一条都没下，日志却报完成。
	log_msg "另一个规则集下载任务正在运行，本次跳过。"
	exit 75
fi

trap 'lock_release' EXIT INT TERM

# 下载磁盘空间预检：规则集虽单条不大，但一次性拉取 N 条仍需要余量。
# 可用空间拿不到（df 缺失）时放行，不阻断下载。
free="$(disk_free_bytes "$RULESET_DIR")"
if [ "$free" -gt 0 ] && [ "$free" -lt 52428800 ]; then
	log_msg "警告：磁盘可用空间仅 $(human_size "$free")，低于 50MB，规则集下载可能失败（磁盘满时部分 .srs 会写入不完整）。"
fi

sections="$(list_sections)"
if [ -z "$sections" ]; then
	# 「一条都没扫到」有两种完全不同的原因，日志里必须区分开：
	#   a) 用户确实没配 / 全关了 → 正常跳过；
	#   b) 配置里有 ruleset 段但没被识别（uci 不可用、段名不在 config
	#      ruleset 下、格式不受支持）→ 是故障，必须报错。
	# 0.1.19/0.1.20 现场就是 b 被当成 a 打印成「没有已启用的远程规则集」，
	# 用户看着配置里的 21 条完全无从下手。
	rs_raw="$(uci -q show "$CONF" 2>/dev/null | grep -c '=ruleset$')"
	case "$rs_raw" in ''|*[!0-9]*) rs_raw=0 ;; esac
	if [ "$rs_raw" -gt 0 ]; then
		log_msg "错误：配置里有 $rs_raw 条 ruleset 段，但一条都没被识别为「已启用的远程规则集」。请检查 uci 是否可用（command -v uci）、段是否写在 config ruleset 下、以及 format 是否为 remote/binary。"
		exit 1
	fi
	log_msg "没有启用的远程规则集，跳过。"
	exit 0
fi

# --only：只处理指定的规则集 section（须在「已启用的远程规则集」列表中，
# 否则视为配置错误退出 2）。列表以空白分隔，用前后加空格的 case 匹配。
if [ -n "$ONLY" ]; then
	case "$(printf ' %s ' $sections)" in
		*" $ONLY "*)
			sections="$ONLY"
			;;
		*)
			# 也允许直接给 tag：界面上看到的是 geosite-cn，段名却是
			# ruleset_geosite_cn，凭界面信息猜段名非常容易猜错（现场就猜错过）。
			# 只有「唯一命中」才接受 —— 多段同 tag 时必须报错，否则会下错对象。
			only_sec=""
			only_hits=0
			for only_s in $sections; do
				only_tag="$(uci -q get "$CONF.$only_s.tag" 2>/dev/null)"
				[ -n "$only_tag" ] || continue
				[ "$only_tag" = "$ONLY" ] || continue
				only_sec="$only_s"
				only_hits=$((only_hits + 1))
			done
			case "$only_hits" in
				1)
					log_msg "--only：'$ONLY' 是 tag，对应段名 $only_sec。"
					sections="$only_sec"
					;;
				0)
					log_msg "错误：--only 指定的规则集 '$ONLY' 不存在或未启用（段名与 tag 都对不上）。"
					exit 2
					;;
				*)
					log_msg "错误：--only 指定的 tag '$ONLY' 命中 $only_hits 个规则集段，请改用段名。"
					exit 2
					;;
			esac
			;;
	esac
fi

total=0
ok=0
cached=0
failed=0
# Human-readable list of every failing rule-set, surfaced on stdout at the
# end so callers that redirect our output (init.d main log, cron mail) show
# the failures directly instead of hiding them in ruleset_download.log.
fail_summary=""
deadline=$(( $(date +%s) + BUDGET ))
out_of_time=0

# 规则集是「多条小文件」，用「已完成条数 / 总条数」代表整体下载进度。
idx=0
total_sections=0
for __s in $sections; do total_sections=$((total_sections + 1)); done

log_msg "==== 规则集预下载开始：来源=「${SOURCE}」，共 ${total_sections} 条，预算 ${BUDGET}s ===="

for sec in $sections; do
	total=$((total + 1))
	idx=$((idx + 1))

	fmt="$(uci -q get "$CONF.$sec.format")"
	[ -n "$fmt" ] || fmt="binary"
	url="$(uci -q get "$CONF.$sec.url")"
	tag="$(uci -q get "$CONF.$sec.tag")"
	[ -n "$tag" ] || tag="cfg-$sec-rule"
	path="$(resolve_path "$sec" "$tag" "$fmt")"

	log_msg "规则集下载进度 $(( idx * 100 / total_sections ))%（第 $idx/$total_sections 条）：$tag"

	if [ -z "$url" ]; then
		log_msg "跳过 $tag：未配置 URL。"
		fail_summary="$fail_summary  - $tag：未配置 URL（请在 LuCI 规则集页面填写下载地址）\n"
		failed=$((failed + 1))
		continue
	fi

	if [ "$FORCE" != "1" ] && valid_ruleset "$path" "$fmt"; then
		cached=$((cached + 1))
		log_msg "跳过 $tag：本地已有有效副本（$(human_size "$(wc -c < "$path" 2>/dev/null | tr -d ' ')")），不重复下载。"
		continue
	fi

	if recently_unavailable "$path.unavailable" "$url"; then
		cached=$((cached + 1))
		log_msg "跳过 $tag：该 URL 上次返回 404，6 小时内不再重试（改动 URL 后会立即重试）。"
		continue
	fi

	now=$(date +%s)
	if [ "$now" -ge "$deadline" ]; then
		out_of_time=1
		break
	fi
	left=$((deadline - now))
	[ "$left" -gt "$PER_FILE_MAX" ] && left="$PER_FILE_MAX"
	[ "$left" -lt 10 ] && left=10

	mkdir -p "$(dirname "$path")" 2>/dev/null
	tmp="$path.part.$$"
	done_one=0
	last_codes=""
	bad_content=0
	bad_sample=""

	for u in $(build_candidates "$url" | awk '!seen[$0]++'); do
		rm -f "$tmp" 2>/dev/null
		if download_to "$u" "$tmp" "$left"; then
			if valid_ruleset "$tmp" "$fmt"; then
				if mv -f "$tmp" "$path" 2>/dev/null; then
					ok=$((ok + 1))
					done_one=1
					rm -f "$path.unavailable" 2>/dev/null
					log_msg "已更新 $tag（$(human_size "$(wc -c < "$path" 2>/dev/null | tr -d ' ')")）：$u"
				fi
				break
			fi
			# HTTP OK but the body is not a rule-set: a mirror error page,
			# an HTML login/redirect page, or a source/binary format mismatch.
			# Keep the first sample so the failure message can show what
			# actually came back instead of a confusing bare "HTTP 200".
			bad_content=1
			if [ -z "$bad_sample" ]; then
				bad_sample="$(head -c 32 "$tmp" 2>/dev/null | tr -d '\r\n' | sed 's/[^[:print:]]/./g' | cut -c1-24)"
			fi
		fi
		last_codes="$last_codes ${LAST_HTTP:-000}"
	done

	if [ "$done_one" != "1" ]; then
		rm -f "$tmp" 2>/dev/null
		failed=$((failed + 1))
		# Keep whatever valid copy was already there (if any); the generator
		# will keep using `local` for it. Otherwise it stays `remote`.
		#
		# Distinguish the two very different failure modes: the HTTP request
		# itself failed (non-2xx / network error) versus a 200 whose body is
		# not a rule-set at all (mirror error page, HTML redirect, or a
		# source/binary format mismatch). Reporting the latter as
		# "HTTP 状态：200" reads like a success and confuses the user.
		if [ "$bad_content" = "1" ]; then
			fail_reason="服务器返回 200 但内容不是有效的 .srs（开头为「${bad_sample:-?}」），URL 可能指向 HTML 页面/错误页，或规则集格式（binary/source）与配置不符"
		else
			fail_reason="所有镜像均不可用（HTTP 状态：${last_codes# }）"
		fi
		case "$last_codes" in
			*404*)
				# 404 is decisive: the file does not exist upstream. Remember
				# it so the next start-up does not spend another ~15 s on it.
				fail_reason="URL 不存在（HTTP 404），请检查规则集下载地址"
				mark_unavailable "$path.unavailable" "$url"
				;;
		esac
		log_msg "下载失败 $tag：$fail_reason。保留原有文件。"
		fail_summary="$fail_summary  - $tag：$fail_reason\n"
		case "$last_codes" in
			*404*)
				# sing-geoip only carries country/region IP lists, so a 404 on
				# `geoip-<company>` is almost always a naming mistake. Say so
				# instead of leaving the user with a bare status code.
				case "$tag" in
					geoip-*)
						log_msg "提示：$tag 在 sing-geoip 中不存在（geoip-* 只收录国家/地区 IP 段）。若本意是公司/服务类域名规则，应改用 geosite-${tag#geoip-}。"
						fail_summary="$fail_summary    提示：$tag 在 sing-geoip 中不存在，应改用 geosite-${tag#geoip-}（geoip-* 仅含国家/地区 IP 段）\n"
						;;
				esac
				;;
		esac
	fi
done

if [ "$out_of_time" = "1" ]; then
	log_msg "预算 ${BUDGET}s 已用尽，剩余规则集留待下次或由内核按 remote 方式下载。"
fi

log_msg "==== 规则集预下载结束：来源=「${SOURCE}」，共 ${total} 条，新下载 ${ok}，已缓存 ${cached}，失败 ${failed} ===="

# 把「补规则集」接回「服务真的跑起来」。
# 0.1.22 为了修「保存并应用不下规则集」，把同步从重启服务里拆了出来，拆完
# 却没接回去：下载结束即脚本结束，没人再去启动服务。于是现场出现了
# 「22:49 补齐 21 条 → 插件仍显示未运行 → 新 .srs 也没被 generate_client
# 引用 → 23:06 手动 restart 才生效」。补全的意义只在服务跑起来时才成立，
# 所以这条路径结束后必须自己补上这一步。
# 只在 --autostart 时做：cron 路径末尾自己 restart，init.d 路径本就在启动
# 流程中，重复 start 只会互相打断。
if [ "$AUTOSTART" = "1" ]; then
	if hp_service_running; then
		log_msg "自动启动：服务已在运行，跳过启动（本次新下载的规则集需重启服务后才会被内核引用）。"
	else
		log_msg "自动启动：规则集已处理完毕但服务未运行，执行 /etc/init.d/homeproxy start …"
		/etc/init.d/homeproxy start >>"$LOG_FILE" 2>&1
		rc=$?
		if [ "$rc" = "0" ]; then
			log_msg "自动启动：服务已启动（rc=0）。"
		else
			log_msg "自动启动：启动未成功（rc=${rc}）。常见原因：① 未配置主节点且服务端未启用（start_service 判定无事可做）；② sing-box 配置校验失败。详见主日志 $RUN_DIR/homeproxy.log。"
		fi
	fi
fi

# Any unresolved rule-set is a real problem: the core will try to fetch it as
# `remote` while initialising, and a 404 there aborts the whole instance. Report
# it so init.d can warn instead of silently pretending everything is fine.
if [ "$failed" -gt 0 ]; then
	# Echo a self-contained failure summary to stdout. Callers that redirect
	# our output (init.d -> homeproxy.log, cron mail) therefore surface the
	# failure directly, instead of the user having to open ruleset_download.log.
	printf '[homeproxy-ruleset] 规则集预下载有 %s 条失败，明细见 %s：\n' "$failed" "$LOG_FILE"
	printf '%b' "$fail_summary"
	printf '[homeproxy-ruleset] 失败项将由内核按 remote 方式下载；若对应 URL 返回 404，\n'
	printf '内核会把这些 HTML 错误页当成 .srs 载入并崩溃，导致服务起不来。\n'
	printf '处理办法：检查失败项 URL（geoip-* 公司/服务类域名规则应改为 geosite-*），\n'
	printf '或手动下载正确的 .srs 放到 %s。\n' "$RULESET_DIR"
	exit 1
fi
exit 0
