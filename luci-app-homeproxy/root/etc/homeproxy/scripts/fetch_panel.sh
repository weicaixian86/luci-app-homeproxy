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
HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"
LOG_FILE="$RUN_DIR/panel_download.log"

# Total wall-clock budget for the whole mirror chain.
BUDGET=900
FORCE=0
QUIET=0

log_msg() {
	mkdir -p "$RUN_DIR" 2>/dev/null
	local msg="面板: $*"
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$LOG_FILE" 2>/dev/null
	[ "$QUIET" = "1" ] || logger -t homeproxy "$msg" 2>/dev/null
	return 0
}

usage() {
	cat <<'EOF'
Usage: fetch_panel.sh [options]

  --force        re-download even when index.html already exists
  --budget N     total time budget in seconds (default 900)
  --quiet        do not log to syslog
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1 ;;
		--quiet) QUIET=1 ;;
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

panel_dir="$(uci -q get "$CONF.clash_api.external_ui" 2>/dev/null)"
[ -n "$panel_dir" ] || panel_dir="$HP_DIR/run/ui"
panel_url="$(uci -q get "$CONF.clash_api.external_ui_download_url" 2>/dev/null)"

if [ "$FORCE" != "1" ] && [ -f "$panel_dir/index.html" ]; then
	[ "$QUIET" = "1" ] || log_msg "面板已存在（$panel_dir/index.html），跳过下载。"
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

# Ordered, de-duplicated candidate URLs. The configured URL is tried first so
# that whatever the user picked in LuCI keeps priority; the wrappers around it
# are pure redundancy for the case where that one wrapper is down.
build_candidates() {
	local url="$1" direct
	direct="$(strip_proxy_prefix "$url")"

	printf '%s\n' "$url"
	[ "$direct" != "$url" ] && printf '%s\n' "$direct"
	case "$direct" in
		https://github.com/*|http://github.com/*)
			printf '%s\n' "https://gh-proxy.com/${direct}"
			printf '%s\n' "https://ghproxy.net/${direct}"
			printf '%s\n' "https://ghfast.top/${direct}"
			;;
	esac
	return 0
}

LAST_HTTP=""

download_to() {
	local url="$1" out="$2" max="$3"
	LAST_HTTP=""
	if command -v curl >/dev/null 2>&1; then
		# -f turns HTTP 4xx/5xx into a failure instead of saving the error page,
		# which is exactly how a 73-byte "404" ends up installed as a dashboard.
		# --speed-limit/--speed-time abort only when the transfer is too slow to
		# be worth waiting for (a 0.9 KB/s mirror), so a merely slow but working
		# mirror (17 KB/s measured) is still allowed to finish.
		LAST_HTTP="$(curl -fsSL --connect-timeout 20 \
			--speed-limit 6144 --speed-time 60 --max-time "$max" \
			-w '%{http_code}' -o "$out" "$url" 2>/dev/null)"
		return $?
	fi
	wget -q -T "$max" -O "$out" "$url" >/dev/null 2>&1
	return $?
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

work="/tmp/homeproxy_panel.$$"
zip="$work/dist.zip"
extract="$work/extract"
stage="$work/stage"
backup="$panel_dir.backup"

cleanup() {
	rm -rf "$work" 2>/dev/null
	return 0
}

rm -rf "$work" 2>/dev/null
mkdir -p "$work" "$extract" "$stage" 2>/dev/null || { log_msg "下载失败：无法创建临时目录 $work"; exit 1; }
trap cleanup EXIT INT TERM

deadline=$(( $(date +%s) + BUDGET ))
got=0
codes=""
used_url=""

log_msg "开始下载面板（不依赖 clash API）：$panel_url"

for u in $(build_candidates "$panel_url" | awk '!seen[$0]++'); do
	now=$(date +%s)
	left=$((deadline - now))
	if [ "$left" -lt 15 ]; then
		log_msg "预算 ${BUDGET}s 用尽，停止尝试。"
		break
	fi
	rm -f "$zip" 2>/dev/null
	if download_to "$u" "$zip" "$left"; then
		if valid_zip "$zip"; then
			got=1
			used_url="$u"
			log_msg "已取到面板包（$(wc -c < "$zip" | tr -d ' ') 字节）：$u"
			break
		fi
		# Exit status 0 but not a zip: a mirror that answers 200 with an HTML
		# placeholder page. Installing that is exactly how a "downloaded"
		# dashboard ends up as a blank screen, so drop it and move on.
		log_msg "镜像返回的不是 zip（HTTP ${LAST_HTTP:-000}，$(wc -c < "$zip" | tr -d ' ') 字节），已丢弃：$u"
	else
		log_msg "镜像不可用或传输中断（HTTP ${LAST_HTTP:-000}）：$u"
	fi
	codes="$codes ${LAST_HTTP:-000}"
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
