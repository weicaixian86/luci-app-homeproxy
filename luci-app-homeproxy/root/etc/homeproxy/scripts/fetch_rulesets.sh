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

CONF="homeproxy"
HP_DIR="/etc/homeproxy"
RULESET_DIR="$HP_DIR/ruleset"
RUN_DIR="/var/run/homeproxy"
LOG_FILE="$RUN_DIR/ruleset_download.log"

# Total wall-clock budget in seconds. Whatever is not finished when it expires
# is simply left as `remote` for the core to fetch, i.e. the old behaviour.
BUDGET=600
# Per-file ceiling. Rule-sets are 10 KB - 5 MB, so this is generous.
PER_FILE_MAX=120

FORCE=0
CHECK_ONLY=0
QUIET=0

log_msg() {
	mkdir -p "$RUN_DIR" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
	[ "$QUIET" = "1" ] || logger -t homeproxy "$*" 2>/dev/null
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
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1 ;;
		--check) CHECK_ONLY=1 ;;
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
list_sections() {
	local sec
	uci -q show "$CONF" 2>/dev/null | awk -F. -v c="$CONF" '
		$1 == c && $3 ~ /^type=/ && $3 ~ /remote/ {
			sub(/^type=/, "", $3);
			gsub(/'"'"'/, "", $3);
			if ($3 == "remote") print $2;
		}' | while read -r sec; do
			[ "$(uci -q get "$CONF.$sec.enabled")" = "1" ] && printf '%s\n' "$sec"
		done
	return 0
}

# ---------------------------------------------------------------------------
# --check: report whether every enabled rule-set already has a valid copy
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = "1" ]; then
	missing=0
	for sec in $(list_sections); do
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
	[ "$missing" -eq 0 ] && exit 0
	printf '%s\n' "$missing"
	exit 1
fi

# ---------------------------------------------------------------------------
# Download pass
# ---------------------------------------------------------------------------

mkdir -p "$RUN_DIR" "$RULESET_DIR" 2>/dev/null

sections="$(list_sections)"
if [ -z "$sections" ]; then
	log_msg "没有启用的远程规则集，跳过。"
	exit 0
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

log_msg "==== 规则集预下载开始（预算 ${BUDGET}s）===="

for sec in $sections; do
	total=$((total + 1))

	fmt="$(uci -q get "$CONF.$sec.format")"
	[ -n "$fmt" ] || fmt="binary"
	url="$(uci -q get "$CONF.$sec.url")"
	tag="$(uci -q get "$CONF.$sec.tag")"
	[ -n "$tag" ] || tag="cfg-$sec-rule"
	path="$(resolve_path "$sec" "$tag" "$fmt")"

	if [ -z "$url" ]; then
		log_msg "跳过 $tag：未配置 URL。"
		fail_summary="$fail_summary  - $tag：未配置 URL（请在 LuCI 规则集页面填写下载地址）\n"
		failed=$((failed + 1))
		continue
	fi

	if [ "$FORCE" != "1" ] && valid_ruleset "$path" "$fmt"; then
		cached=$((cached + 1))
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

	for u in $(build_candidates "$url" | awk '!seen[$0]++'); do
		rm -f "$tmp" 2>/dev/null
		if download_to "$u" "$tmp" "$left" && valid_ruleset "$tmp" "$fmt"; then
			if mv -f "$tmp" "$path" 2>/dev/null; then
				ok=$((ok + 1))
				done_one=1
				rm -f "$path.unavailable" 2>/dev/null
				log_msg "已更新 $tag（$u）"
			fi
			break
		fi
		last_codes="$last_codes ${LAST_HTTP:-000}"
	done

	if [ "$done_one" != "1" ]; then
		rm -f "$tmp" 2>/dev/null
		failed=$((failed + 1))
		# Keep whatever valid copy was already there (if any); the generator
		# will keep using `local` for it. Otherwise it stays `remote`.
		log_msg "下载失败 $tag：所有镜像均不可用（HTTP 状态：${last_codes# }）。保留原有文件。"
		fail_summary="$fail_summary  - $tag：所有镜像均不可用（HTTP 状态：${last_codes# }）\n"
		case "$last_codes" in
			*404*)
				# 404 is decisive: the file does not exist upstream. Remember
				# it so the next start-up does not spend another ~15 s on it.
				mark_unavailable "$path.unavailable" "$url"
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

log_msg "==== 规则集预下载结束：共 ${total} 条，新下载 ${ok}，已缓存 ${cached}，失败 ${failed} ===="

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
