#!/bin/sh
# Static + behavioural checks for luci-app-homeproxy.
#
# Runs everything that can be verified without an OpenWrt SDK:
#   - JavaScript syntax            (node --check)
#   - shell syntax                 (sh -n)
#   - JSON / workflow YAML         (python)
#   - ucode syntax, approximated   (strip imports + wrap + node --check)
#   - gettext catalog consistency  (tools/tests/pocheck.py)
#   - log level filtering          (tools/tests/log_level.test.cjs)
#   - Makefile conffiles exist     (packaging guard)
#   - routing-node DOM behaviour   (tools/tests/routing_pin.test.cjs, needs jsdom)
#
# Usage:
#   sh tools/tests/run.sh
#   NODE=/path/to/node PY=python3 sh tools/tests/run.sh
#
# Missing optional tooling is reported as SKIP, never as a failure, so the same
# script works on a bare dev box and on the CI runner.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PKG="$ROOT/luci-app-homeproxy"
NODE=${NODE:-node}
PY=${PY:-python3}

# OpenWrt runs /bin/sh = busybox ash and GitHub's ubuntu runner uses dash. A
# script can pass `bash -n` locally and still die at parse time in CI (and on
# the router), so prefer the strictest POSIX shell available here instead of
# whatever `sh` happens to be. Git Bash maps `sh` to bash — never trust it.
SHN=dash
command -v dash >/dev/null 2>&1 || SHN=sh

FAILED=0
CHECKS=0
FAILLIST=''

section() { printf '\n== %s ==\n' "$1"; }
ok()      { CHECKS=$((CHECKS + 1)); printf '  OK   %s\n' "$1"; }
bad()     {
	CHECKS=$((CHECKS + 1))
	FAILED=$((FAILED + 1))
	printf '  FAIL %s\n' "$1"
	FAILLIST="$FAILLIST
  - $1"
	# Surface it where it is actually readable: the run's summary page and the
	# annotation list, not just deep inside the step log.
	[ -z "${GITHUB_ACTIONS:-}" ] || printf '::error::%s\n' "$1"
}
skip()    { printf '  SKIP %s\n' "$1"; }

if ! command -v "$NODE" >/dev/null 2>&1; then
	printf 'run.sh: node not found (set NODE=/path/to/node)\n' >&2
	exit 2
fi

WORK=$(mktemp -d 2>/dev/null) || WORK="$ROOT/.tests-tmp"
mkdir -p "$WORK" 2>/dev/null
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------- JavaScript
section "JavaScript syntax"
find "$PKG/htdocs" -type f -name '*.js' | sort > "$WORK/js.list"
while IFS= read -r f; do
	[ -n "$f" ] || continue
	if "$NODE" --check "$f" >"$WORK/node.err" 2>&1; then
		ok "${f#$ROOT/}"
	else
		bad "${f#$ROOT/}  <- $(head -2 "$WORK/node.err" | tr '\n' ' ')"
	fi
done < "$WORK/js.list"

# -------------------------------------------------------------------- shell
section "Shell syntax"
{
	find "$PKG/root" -type f -name '*.sh'
	[ -f "$PKG/root/etc/init.d/homeproxy" ] && printf '%s\n' "$PKG/root/etc/init.d/homeproxy"
	# uci-defaults scripts carry no extension but are plain POSIX shell.
	find "$PKG/root/etc/uci-defaults" -type f 2>/dev/null
} | sort > "$WORK/sh.list"
while IFS= read -r f; do
	[ -n "$f" ] || continue
	if "$SHN" -n "$f" >"$WORK/sh.err" 2>&1; then
		ok "${f#$ROOT/}"
	else
		bad "${f#$ROOT/}  <- $(head -2 "$WORK/sh.err" | tr '\n' ' ')"
	fi
done < "$WORK/sh.list"

# --------------------------------------------------------------------- JSON
section "JSON"
if "$PY" -c 'import json' >/dev/null 2>&1; then
	find "$PKG/root" -type f -name '*.json' | sort > "$WORK/json.list"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if "$PY" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" >"$WORK/json.err" 2>&1; then
			ok "${f#$ROOT/}"
		else
			bad "${f#$ROOT/}  <- $(tail -1 "$WORK/json.err")"
		fi
	done < "$WORK/json.list"
else
	skip "python json module unavailable"
fi

# --------------------------------------------------------------------- YAML
section "Workflow YAML"
if "$PY" -c 'import yaml' >/dev/null 2>&1; then
	find "$ROOT/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort > "$WORK/yaml.list"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if "$PY" -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$f" >"$WORK/yaml.err" 2>&1; then
			ok "${f#$ROOT/}"
		else
			bad "${f#$ROOT/}  <- $(tail -1 "$WORK/yaml.err")"
		fi
	done < "$WORK/yaml.list"
else
	skip "PyYAML unavailable (pip install pyyaml)"
fi

# -------------------------------------------------------------------- ucode
section "ucode syntax (approximated)"
"$PY" "$ROOT/tools/tests/ucparse.py" "$WORK/uc" \
	"$PKG/root/etc/homeproxy/scripts/homeproxy.uc" \
	"$PKG/root/etc/homeproxy/scripts/update_subscriptions.uc" \
	"$PKG/root/etc/homeproxy/scripts/generate_client.uc" \
	"$PKG/root/etc/homeproxy/scripts/migrate_config.uc" \
	"$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
	>"$WORK/uc.raw" 2>"$WORK/uc.err"
uc_rc=$?
# Defensive CR strip: any helper that writes text files on Windows may emit
# CRLF, which would glue a CR onto every filename.
tr -d '\r' < "$WORK/uc.raw" > "$WORK/uc.list" 2>/dev/null || cp "$WORK/uc.raw" "$WORK/uc.list"
if [ "$uc_rc" -ne 0 ]; then
	bad "ucparse.py  <- $(tail -1 "$WORK/uc.err")"
else
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		label=$(basename "$f" .js)
		if "$NODE" --check "$f" >"$WORK/ucn.err" 2>&1; then
			ok "$label"
		else
			bad "$label  <- $(tail -1 "$WORK/ucn.err")"
		fi
	done < "$WORK/uc.list"
fi

# ------------------------------------------------------- rpcd regex portability
# rpcd 里的 match()/replace() 走 C 的 regcomp/regexec，不是 JS 引擎。
# 踩过的坑：/^([0-9]+)(\.([0-9]+))?$/ 直接抛
#   Repetition not preceded by valid expression
# 整条 DNS 延迟测试因此全失败，界面上还只剩一串英文。这里守住三类写法。
section "rpcd regex portability"
HP_UC="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"

# 只看代码行：注释里会引用这些坏写法作为反例，不能算命中。
regex_hits() {
	grep -nE "$1" "$HP_UC" 2>/dev/null \
		| grep -vE '^[0-9]+:[[:space:]]*(\*|//|#)' \
		|| true
}

hits=$(regex_hits '(match|replace)\(.*\)\?')
if [ -n "$hits" ]; then
	bad "optional group (?...) in match()/replace(): $(printf '%s' "$hits" | head -1)"
else
	ok "no optional-group regex in match()/replace()"
fi

hits=$(regex_hits '(match|replace)\(.*\(\?:')
if [ -n "$hits" ]; then
	bad "non-capturing group (?:...) in match()/replace(): $(printf '%s' "$hits" | head -1)"
else
	ok "no non-capturing group in match()/replace()"
fi

hits=$(regex_hits '(match|replace)\(.*\\[sdwSDW]')
if [ -n "$hits" ]; then
	bad "PCRE-only escape in match()/replace(): $(printf '%s' "$hits" | head -1)"
else
	ok "no PCRE-only escapes in match()/replace()"
fi

# ------------------------------------------------ connection check parity
# 「服务状态 → 连接检查」必须与 passwall 同口径，否则同一个网络下两边的
# 数字没法比（曾出现 homeproxy 明显偏低）：
#   1. 端点用 favicon.ico / generate_204，不用站点首页
#      —— www.aliyun.com 的 HEAD 会被 WAF 直接回 403；
#   2. curl 不带 -L
#      —— 跟随重定向后 time_pretransfer / time_starttransfer 变成整条
#         重定向链的累计值，算出的「请求延迟」不是同一个量；
#   3. 指标仍是 (time_starttransfer - time_pretransfer) * 1000。
section "connection check parity (passwall)"

if grep -q -- '-skL' "$HP_UC"; then
	bad "connection_check follows redirects (curl -L); Passwall does not"
else
	ok "connection_check does not follow redirects (matches Passwall)"
fi

for probe in 'www.aliyun.com/favicon.ico' \
             'www.google.com/generate_204' \
             'github.com/favicon.ico' \
             'www.youtube.com/generate_204'; do
	if grep -q "$probe" "$HP_UC"; then
		ok "probe endpoint $probe"
	else
		bad "probe endpoint missing or changed: $probe"
	fi
done

if grep -q 'time_pretransfer' "$HP_UC" && grep -q 'time_starttransfer' "$HP_UC"; then
	ok "connection_check uses pretransfer/starttransfer metric"
else
	bad "connection_check metric changed (time_pretransfer/time_starttransfer)"
fi

if grep -q "'/usr/sbin/curl'" "$HP_UC"; then
	ok "curl lookup includes /usr/sbin/curl"
else
	bad "curl lookup misses /usr/sbin/curl (iStoreOS)"
fi

# ------------------------------------------ dns test ICMP fallback contract
# 端口探测失败后会回退 ICMP。这时必须把「为什么失败」一起带回前端：
# 只回 { result:true, kind:'ping' } 的话，界面就是一个绿色毫秒数 +
# tooltip 里的 ICMP 字样，和「该协议握手正常」在视觉上完全一样 ——
# 0.1.21 现场三个 DoH 全部回退 ICMP 却没人察觉，就是这么发生的。
section "dns test ICMP fallback is labelled"

if grep -q 'probe_failed' "$HP_UC"; then
	ok "rpcd marks the ICMP fallback with probe_failed"
else
	bad "rpcd drops the reason when falling back to ICMP (probe_failed missing)"
fi

if grep -q 'error: probe_error' "$HP_UC"; then
	ok "rpcd returns the humanized probe error on ICMP fallback"
else
	bad "ICMP fallback does not return a humanized error"
fi

if grep -q 'hp-lat-warn' "$PKG/htdocs/luci-static/resources/view/homeproxy/client.js" \
   && grep -q 'hp-lat-warn' "$PKG/htdocs/luci-static/resources/homeproxy.js"; then
	ok "client renders (and styles) a marker for the ICMP fallback"
else
	bad "client does not distinguish an ICMP fallback from a real handshake result"
fi

# ------------------------------------------- core timezone (Go vs POSIX)
# sing-box is Go: it only understands a TZif path or an IANA name. OpenWrt's
# /etc/TZ holds a POSIX rule ("CST-8"), which Go silently rejects, so the core
# logged in UTC — eight hours behind every other source and, because the merged
# timeline sorts on the stamp text, in the wrong order too. init.d must hand it
# a zone Go can read and record the outcome for the log view.
section "core timezone (Go needs TZif, not POSIX)"

INITD="$PKG/root/etc/init.d/homeproxy"

if grep -q 'tz_setup_core' "$INITD" && ! grep -q 'TZ"=$tz_value' "$INITD"; then
	ok "init.d resolves a zone Go can actually use"
else
	bad "init.d still passes a POSIX TZ string (Go ignores it => core logs in UTC)"
fi

# procd keeps one "env" object per instance: a second procd_set_param env call
# would silently drop the first one's variables (TZ or QUIC_GO_DISABLE_GSO).
if [ "$(grep -c '^[[:space:]]*procd_set_param env' "$INITD")" = 4 ] \
   && ! grep -qF '&& procd_set_param env' "$INITD"; then
	ok "TZ and QUIC_GO_DISABLE_GSO share a single env call"
else
	bad "TZ / QUIC_GO_DISABLE_GSO are passed in two env calls (procd keeps only the last)"
fi

TZDIR="$WORK/tz"
mkdir -p "$TZDIR"
sed -n '/^tz_local_offset()/,/^}/p;/^tz_be32()/,/^}/p;/^tz_write_fixed()/,/^}/p;/^tz_is_tzif()/,/^}/p' "$INITD" > "$TZDIR/fn.sh"

tz_wrote=0
sh -c ". '$TZDIR/fn.sh'; tz_write_fixed '$TZDIR/zone' 28800" 2>/dev/null && tz_wrote=1
if [ "$tz_wrote" = 1 ] && [ "$(wc -c < "$TZDIR/zone" 2>/dev/null)" = 54 ] \
   && [ "$(head -c 4 "$TZDIR/zone" 2>/dev/null)" = TZif ]; then
	ok "fixed-offset TZif is generated (54 bytes, valid magic)"
else
	bad "fixed-offset TZif generation failed (printf escapes not expanded?)"
fi

# The bytes have to be a real TZif, not just the right length: feed them back
# into an independent parser and compare the offset.
tz_off="$("$PY" - "$TZDIR/zone" <<'PY_TZ'
import datetime, sys, zoneinfo
with open(sys.argv[1], 'rb') as handle:
    zone = zoneinfo.ZoneInfo.from_file(handle, key='core')
ref = datetime.datetime(2026, 7, 1, 12, 0, tzinfo=datetime.timezone.utc)
print(int(zone.utcoffset(ref).total_seconds()))
PY_TZ
)" 2>/dev/null
# Windows python writes CRLF even to a pipe; command substitution only strips
# the LF, so the offset would arrive as "28800\r" and never compare equal.
tz_off=$(printf '%s' "$tz_off" | tr -d '\r')
case "$tz_off" in
	28800) ok "generated TZif parses back as +08:00" ;;
	'')    skip "cannot validate TZif (python zoneinfo unavailable)" ;;
	*)     bad "generated TZif parses back as '$tz_off' (expected 28800)" ;;
esac

# /etc/localtime is normally a symlink into /tmp. On raw OpenWrt images without
# tzdata it is left dangling, and on some vendor images it is a zero-byte
# placeholder. Either way "-f" alone is not enough: Go would reject the file,
# fall back to UTC, and the marker would still say "local" — the 8-hour bug
# coming back with no warning at all.
tz_chk() { sh -c ". '$TZDIR/fn.sh'; tz_is_tzif '$1' && echo yes || echo no" 2>/dev/null; }
if [ "$(tz_chk "$TZDIR/zone")" = yes ]; then
	ok "TZif check accepts the generated zone"
else
	bad "TZif check rejects the zone file it just generated"
fi
printf 'CST-8' > "$TZDIR/posix"
: > "$TZDIR/empty"
if [ "$(tz_chk "$TZDIR/posix")" = no ] && [ "$(tz_chk "$TZDIR/empty")" = no ] \
   && [ "$(tz_chk "$TZDIR/missing")" = no ]; then
	ok "TZif check rejects POSIX-string / empty / missing zone paths"
else
	bad "a bogus /etc/localtime would be accepted (core silently goes back to UTC)"
fi

# A bare IANA name is NOT a safe fallback: this core carries no time/tzdata, so
# Go would land on UTC while the marker says "local" and the log view stops
# shifting. Only the ":<path>" form may be exported.
if grep -qF 'CORE_TZ="$zn"' "$INITD"; then
	bad "init.d falls back to a bare IANA name (marker would lie: local vs real UTC)"
else
	ok "no bare IANA-name fallback (marker always matches the core's clock)"
fi

LOG_JS="$PKG/htdocs/luci-static/resources/view/homeproxy/log.js"
if grep -q 'core_tz' "$LOG_JS" && grep -q 'shiftTs' "$LOG_JS" \
   && grep -q 'core: true' "$LOG_JS"; then
	ok "log view puts the core's stamps on the local clock"
else
	bad "log view would keep two clocks (core_tz marker not consumed)"
fi

# ------------------------------------------------ unified log view (levels)
# All four levels share ONE poll registration, so the 5 s cadence cannot vary
# by level. Two things around it are easy to break: the level has to reach
# BOTH the client and server config sections (each generator reads its own),
# and a rebuild of the scroller must not throw the reader back to line 1.
section "unified log view (levels + refresh)"

lv="$(sed -n '/const log_level_choices = {/,/};/p' "$LOG_JS" \
	| sed -n 's/^[[:space:]]*\([a-z]*\)[[:space:]]*:.*/\1/p' | sort | tr '\n' ' ')"
if [ "$lv" = "debug error info warn " ]; then
	ok "level choices are exactly debug/info/warn/error"
else
	bad "level choices are '$lv' (sing-box accepts debug/info/warn/error)"
fi

if [ "$(grep -c "hp.pollAdd('log-refresh', refresh)" "$LOG_JS")" = 1 ] \
   && ! grep -qE "pollAdd\('log-refresh', refresh, *[0-9]" "$LOG_JS"; then
	ok "one poll registration, no per-level interval"
else
	bad "log refresh interval differs by level (or poll registered twice)"
fi

if grep -q "uci.set('homeproxy', 'config', 'log_level'" "$LOG_JS" \
   && grep -q "uci.set('homeproxy', 'server', 'log_level'" "$LOG_JS"; then
	ok "level change commits to both client and server sections"
else
	bad "level change misses a section (client or server keeps old verbosity)"
fi

if grep -q 'function scrollState' "$LOG_JS" && grep -q 'restoreScroll(scroll)' "$LOG_JS"; then
	ok "reader keeps their scroll position across a rebuild"
else
	bad "every rebuild jumps back to the oldest line (new lines are at the bottom)"
fi

if grep -q 'refresh(true)' "$LOG_JS"; then
	ok "level switch re-filters even with auto refresh paused"
else
	bad "level switch is ignored while auto refresh is off"
fi

# The dropdown only offers four levels, but uci can carry anything (hand-edit,
# restored backup). sing-box rejects an unknown "log.level" at check time and
# then the whole service refuses to start — so both generators whitelist it.
for gen in generate_client.uc generate_server.uc; do
	path="$PKG/root/etc/homeproxy/scripts/$gen"
	if grep -q "log_level_uci == 'debug'" "$path" \
	   && grep -q "log_level_uci == 'error'" "$path" \
	   && grep -q "? log_level_uci : 'info'" "$path"; then
		ok "$gen whitelists log level before it reaches sing-box"
	else
		bad "$gen passes log_level verbatim (a stray value stops the core from starting)"
	fi
done

# A source that simply has no file yet (service never started, panel never
# updated) is the normal state of half the sources. It used to add one
# "Log file does not exist." row per missing file — indistinguishable from a
# real log line and useless because it never named the file. Now: absent is
# silent, a genuine read failure names the file.
if grep -q "missing ? null" "$LOG_JS" && grep -q "src.file + '.log'" "$LOG_JS"; then
	ok "missing log files are silent; real read errors name the file"
else
	bad "missing log files still render as rows (or errors are unnamed)"
fi

# "Clean log" walks the frontend's log_sources, but the rpcd call has its own
# whitelist. When a source is added to the view and not to the whitelist the
# call rejects with 'illegal type' and L.resolveDefault() hides it — the
# button looks fine while one file is never cleared. Keep the two lists equal.
UCODE="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
log_srcs="$(sed -n '/const log_sources = \[/,/\];/p' "$LOG_JS" \
	| sed -n "s/.*{ file: '\(.*\)'.*/\1/p" | sort | tr '\n' ' ')"
clean_wl="$(sed -n "/log_clean: {/,/return { result: true }/p" "$UCODE" \
	| sed -n "s/.*in \[\(.*\)\].*/\1/p" | tr -d "'" | tr ',' '\n' \
	| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ' ')"
if [ -n "$log_srcs" ] && [ "$log_srcs" = "$clean_wl" ]; then
	ok "log_clean whitelist matches the merged log sources"
else
	bad "log_clean whitelist '$clean_wl' != log sources '$log_srcs' (Clean log no-ops on one)"
fi

# Notices (UTC shift, oldest/newest span) are one record with several lines.
# Keeping "the first row" on truncation silently dropped the second notice,
# which is the one that explains a log line dated days ago.
if grep -qF 'while (keep < flat.length && flat[keep].note)' "$LOG_JS"; then
	ok "truncation keeps every leading notice line"
else
	bad "truncation keeps only the first notice line (second notice is lost)"
fi

# Download logs are event logs: a handful of lines per run, never big enough
# for the size-based rotation of the main logs, so entries from weeks ago sat
# in the file and showed up below today's lines — which reads as "the date is
# wrong". They now rotate on their own (smaller) budget.
CL_LOG="$PKG/root/etc/homeproxy/scripts/clean_log.sh"
if grep -q "core_download.log" "$CL_LOG" \
   && grep -q "panel_download.log" "$CL_LOG" \
   && grep -q "ruleset_download.log" "$CL_LOG"; then
	ok "download logs are rotated as well (no month-old lines in today's view)"
else
	bad "download logs never rotate (old downloads linger in /var/run)"
fi

# ----------------------------------------------------------------- catalog
section "gettext catalog"
"$PY" "$ROOT/tools/tests/pocheck.py" > "$WORK/po.out" 2>&1
case $? in
	0)  ok "po/zh_Hans/homeproxy.po consistent with JS sources"; sed 's/^/       /' "$WORK/po.out" | tail -8 ;;
	2)  skip "polib unavailable (pip install polib)" ;;
	*)  bad "po/zh_Hans/homeproxy.po has problems"; sed 's/^/       /' "$WORK/po.out" | tail -25 ;;
esac

# ---------------------------------------------------------------- conffiles
section "Makefile conffiles"
awk '/^define Package\/luci-app-homeproxy\/conffiles/{on=1; next} on && /^endef/{exit} on && /^\//{print}' \
	"$PKG/Makefile" > "$WORK/conffiles.list" 2>/dev/null
if [ -s "$WORK/conffiles.list" ]; then
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		if [ -e "$PKG/root$p" ]; then
			ok "conffiles $p"
		else
			bad "conffiles $p does not exist in the package tree"
		fi
	done < "$WORK/conffiles.list"
else
	skip "no conffiles block found"
fi

# ------------------------------------------------- same_scripts --check contract
# fetch_rulesets.sh 的 --check 输出是 init.d 依赖的契约（见需求书十.13）。
# 用 stub uci 跑真实脚本，确认段名扫描、排除原因、统计行都正确。
# 这一项能直接抓到两类曾经把现场变成黑洞的回归：
#   · awk 里写 /* */ 注释 → "unterminated regexp" → 输出为空（伪装成「没有规则集」）
#   · 依赖 awk -F'[.=]' 正则 FS → 某些 BusyBox 构建下一条段名都提取不到
section "Ruleset --check contract"
RS="$PKG/root/etc/homeproxy/scripts/fetch_rulesets.sh"
# stub 目录必须用 POSIX 路径：Git Bash 下 mktemp 与 $TMPDIR 都会给出
# "C:/.../Temp/xxx" 这种带盘符的路径，放进 PATH 后命令查找直接失败
# （uci: command not found），于是 --check 输出为空、看起来像「扫描不到
# 规则集」——测试自己先踩一次坑。优先用 /tmp，不存在时才回落到 TMPDIR。
rs_tmp=/tmp
[ -d "$rs_tmp" ] || rs_tmp="${TMPDIR:-/tmp}"
RS_STUB="$rs_tmp/hp-rs-stub.$$"
RS_CONF="$rs_tmp/hp-rs-conf.$$"
rm -rf "$RS_STUB" "$RS_CONF" 2>/dev/null
mkdir -p "$RS_STUB" 2>/dev/null

# 固定样本：4 段启用且远程（其中 1 段没写 enabled，应当按「启用」算）、
# 1 段显式 enabled=0、1 段 type=local。
RS_DATA='homeproxy.config=homeproxy
homeproxy.rs_cn=ruleset
homeproxy.rs_cn.enabled=1
homeproxy.rs_cn.type=remote
homeproxy.rs_gfw=ruleset
homeproxy.rs_gfw.enabled=1
homeproxy.rs_gfw.type=remote
homeproxy.rs_legacy=ruleset
homeproxy.rs_legacy.type=remote
homeproxy.rs_off=ruleset
homeproxy.rs_off.enabled=0
homeproxy.rs_off.type=remote
homeproxy.rs_local=ruleset
homeproxy.rs_local.enabled=1
homeproxy.rs_local.type=local'

if [ -f "$RS" ]; then
	cat > "$RS_STUB/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
show)
	[ "${STUB_SHOW_EMPTY:-0}" = "1" ] && exit 0
	printf '%s\n' "$STUB_DATA"
	;;
get)
	[ "${STUB_GET_EMPTY:-0}" = "1" ] && exit 1
	case "${1:-}" in
	*.enabled)
		case "${1:-}" in
		*rs_cn.enabled|*rs_gfw.enabled|*rs_local.enabled) echo 1 ;;
		*rs_off.enabled) echo 0 ;;
		*) exit 1 ;;
		esac
		;;
	*.type)
		case "${1:-}" in
		*rs_local.type) echo local ;;
		*) echo remote ;;
		esac
		;;
	*.tag)
		case "${1:-}" in
		*rs_cn.tag) echo geosite-cn ;;
		*rs_gfw.tag|*rs_legacy.tag) echo geosite-gfw ;;
		*) echo geosite-x ;;
		esac
		;;
	*.format) echo binary ;;
	*.url) echo https://example.com/x.srs ;;
	*) exit 1 ;;
	esac
	;;
esac
STUB
	chmod +x "$RS_STUB/uci"

	# 文件兜底用的 /etc/config/homeproxy 等价物
	{
		echo "config homeproxy 'config'"
		# 与真实配置同形的一段：libuci 支持多行单引号值（parse.c 里
		# "Multi-line str value"），订阅用量 subinfo_* 就是以这种形式落盘的。
		# 文件兜底解析必须原样扛住——否则一段订阅用量就会让它后面的
		# 规则集全部扫不到，而那恰恰是线上最常见的配置形态。
		echo "config homeproxy 'subscription'"
		echo "	option user_agent 'Wget/1.21 (HomeProxy, like v2rayN)'"
		echo "	option subinfo_xdefault '{"
		echo '	"upload": 1, "download": 2,'
		echo '	"total": 3'
		echo "}'"
		echo "config ruleset 'rs_cn'"
		echo "	option enabled '1'"
		echo "	option type 'remote'"
		echo "config ruleset 'rs_gfw'"
		echo "	option enabled '1'"
		echo "	option type 'remote'"
		echo "config ruleset 'rs_legacy'"
		echo "	option type 'remote'"
		echo "config ruleset 'rs_off'"
		echo "	option enabled '0'"
		echo "	option type 'remote'"
		echo "config ruleset 'rs_local'"
		echo "	option enabled '1'"
		echo "	option type 'local'"
	} > "$RS_CONF"

	run_rs_check() {
		PATH="$RS_STUB:$PATH" STUB_DATA="$RS_DATA" CONF_FILE="$RS_CONF" \
			STUB_SHOW_EMPTY="${1:-0}" STUB_GET_EMPTY="${2:-0}" \
			HP_RULESET_DIR="$WORK/rs.ruleset" \
			sh "$RS" --check 2>"$WORK/rs.err"
	}

	rs_out="$(run_rs_check 0 0)"
	rs_rc=$?
	rs_one="$(printf '%s' "$rs_out" | tr '\n' '|')"

	if [ -s "$WORK/rs.err" ]; then
		bad "ruleset --check writes nothing to stderr  <- $(tr '\n' ' ' < "$WORK/rs.err" | head -c 200)"
	else
		ok "ruleset --check writes nothing to stderr"
	fi

	case "$rs_out" in
	*sections=5*) ok "ruleset --check reports sections=5" ;;
	*) bad "ruleset --check reports sections=5  <- got: $rs_one" ;;
	esac
	# rs_legacy 没写 enabled，必须算「启用」（与界面 Flag 的 default 一致），
	# 于是应纳入下载的段是 rs_cn / rs_gfw / rs_legacy 三段。
	case "$rs_out" in
	*total=3\ missing=3*) ok "ruleset --check treats unset enabled as enabled" ;;
	*) bad "ruleset --check treats unset enabled as enabled  <- got: $rs_one" ;;
	esac
	case "$rs_out" in
	*"skip rs_local reason=type=local"*) ok "ruleset --check explains local type" ;;
	*) bad "ruleset --check explains local type  <- got: $rs_one" ;;
	esac
	case "$rs_out" in
	*"skip rs_off reason=enabled=0"*) ok "ruleset --check explains disabled section" ;;
	*) bad "ruleset --check explains disabled section  <- got: $rs_one" ;;
	esac
	if [ "$rs_rc" -eq 1 ]; then
		ok "ruleset --check exits 1 when copies are missing"
	else
		bad "ruleset --check exits 1 when copies are missing  <- rc=$rs_rc"
	fi

	# uci 完全读不出来时（show 空、get 失败）必须靠 /etc/config 兜底，
	# 且结论与正常路径完全一致 —— 这条防的是「接口改版/输出异常 ⇒ 一条
	# 规则集都扫不到 ⇒ 日志谎报『没有已启用的远程规则集』」。
	rs_out2="$(run_rs_check 1 1)"
	rs_two="$(printf '%s' "$rs_out2" | tr '\n' '|')"
	case "$rs_out2" in
	*sections=5\ total=3\ missing=3*)
		ok "ruleset --check falls back to /etc/config when uci is unusable" ;;
	*)
		bad "ruleset --check falls back to /etc/config when uci is unusable  <- got: $rs_two" ;;
	esac

	# 多行单引号值（subinfo_*）不得把兜底解析带偏：上面这些 sections=5
	# 断言是在带多行值的 fixture 上跑出来的，这里再单独断言一次，避免以后
	# 有人「简化」fixture 时把这条覆盖悄悄弄丢。
	case "$rs_out2" in
	*sections=5*) ok "ruleset --check survives multi-line option values" ;;
	*) bad "ruleset --check survives multi-line option values  <- got: $rs_two" ;;
	esac

	# PATH 里彻底没有 uci（不是「有但报错」）：必须只留一行 warn 当证据，
	# 结论仍来自 /etc/config，且不得刷满屏 command not found。
	# 0.1.19 现场最可能就是这一类：init.d 从不设置 PATH，uci 找不到，
	# 所有调用又都带 2>/dev/null，于是「21 条规则集」变成「一条都没有」。
	rs_out3="$(PATH=/usr/bin:/bin STUB_DATA="$RS_DATA" CONF_FILE="$RS_CONF" \
		HP_RULESET_DIR="$WORK/rs.ruleset" \
		sh "$RS" --check 2>"$WORK/rs3.err")"
	rs_three="$(printf '%s' "$rs_out3" | tr '\n' '|')"
	case "$rs_out3" in
	*"warn uci_missing source=file"*)
		ok "ruleset --check reports uci_missing when PATH has no uci" ;;
	*)
		bad "ruleset --check reports uci_missing when PATH has no uci  <- got: $rs_three" ;;
	esac
	case "$rs_out3" in
	*sections=5\ total=3\ missing=3*)
		ok "ruleset --check still resolves sections without uci" ;;
	*)
		bad "ruleset --check still resolves sections without uci  <- got: $rs_three" ;;
	esac
	if [ -s "$WORK/rs3.err" ]; then
		bad "no uci must not spam stderr  <- $(tr '\n' ' ' < "$WORK/rs3.err" | head -c 160)"
	else
		ok "no uci must not spam stderr"
	fi

	# --only 的价值在于「现场照着界面按」：界面上看到的是 tag（geosite-cn），
	# 段名却是 ruleset_geosite_cn。0.1.21 现场照 tag 敲，在解析阶段就被判成
	# 「缺少参数」exit 2（旧模式串只放行 [A-Za-z0-9_]），根本走不到 tag 反查。
	# log_msg 非 tty 时不回显，写入 $RUN_DIR/ruleset_download.log，所以断言
	# 同时看 stdout 和日志两种落点。
	#
	# 每次调用都给一个**全新的运行目录**（HP_RUN_DIR）：CI 里 stdout 是管道，
	# 这些消息只会进日志；而如果去共用 /var/run/homeproxy 或 /tmp/homeproxy
	# 里那份历史日志，开发机上只要跑过一次就永远为真，全新机器上却必然拿不到
	# —— 这正是「本地 92 全过、CI 挂 3 项」的那 3 项。
	RS_SEQ=0
	rs_log=""
	# 注意：rs_only 必须放在 $( ) 里调用，子 shell 的变量不会回传，所以
	# 「本次调用的日志路径」在父 shell 里推进（rs_next），rs_only 只读它。
	rs_next() {
		RS_SEQ=$((RS_SEQ + 1))
		rs_log="$WORK/run.$RS_SEQ/ruleset_download.log"
		mkdir -p "${rs_log%/*}"
	}
	rs_only() {
		PATH="$RS_STUB:$PATH" STUB_DATA="$RS_DATA" CONF_FILE="$RS_CONF" \
			HP_RUN_DIR="${rs_log%/*}" HP_RULESET_DIR="${rs_log%/*}/ruleset" sh "$RS" "$@" 2>&1
	}
	rs_saw() {
		printf '%s' "$1" | grep -q -- "$2" && return 0
		[ -f "$rs_log" ] && grep -q -- "$2" "$rs_log" 2>/dev/null && return 0
		return 1
	}

	rs_next
	rs_o="$(rs_only --check --only geosite-cn)"
	if rs_saw "$rs_o" 'sections=5'; then
		ok "--only accepts a hyphenated tag (arg parser)"
	else
		bad "--only accepts a hyphenated tag (arg parser)  <- got: $(printf '%s' "$rs_o" | tr '\n' '|' | head -c 160)"
	fi

	rs_next
	rs_o="$(rs_only --only geosite-cn --budget 0)"
	rs_rc=$?
	if rs_saw "$rs_o" "是 tag，对应段名 rs_cn"; then
		ok "--only resolves a unique tag to its section"
	else
		bad "--only resolves a unique tag to its section  <- got: $(printf '%s' "$rs_o" | tr '\n' '|' | head -c 200)"
	fi
	if [ "$rs_rc" -eq 0 ]; then
		ok "--only with --budget 0 returns 0 without any download"
	else
		bad "--only with --budget 0 returns 0 without any download  <- rc=$rs_rc"
	fi

	rs_next
	rs_o="$(rs_only --only geosite-gfw --budget 0)"
	rs_rc=$?
	if rs_saw "$rs_o" "命中 2 个规则集段"; then
		ok "--only rejects a tag matching several sections"
	else
		bad "--only rejects a tag matching several sections  <- got: $(printf '%s' "$rs_o" | tr '\n' '|' | head -c 200)"
	fi
	if [ "$rs_rc" -eq 2 ]; then
		ok "--only ambiguous tag exits 2"
	else
		bad "--only ambiguous tag exits 2  <- rc=$rs_rc"
	fi

	rs_next
	rs_o="$(rs_only --only no-such-rule --budget 0)"
	rs_rc=$?
	if rs_saw "$rs_o" "段名与 tag 都对不上"; then
		ok "--only says both section and tag were tried"
	else
		bad "--only says both section and tag were tried  <- got: $(printf '%s' "$rs_o" | tr '\n' '|' | head -c 200)"
	fi

	rs_next
	rs_o="$(rs_only --only --force)"
	rs_rc=$?
	if [ "$rs_rc" -eq 2 ]; then
		ok "--only without a value still exits 2"
	else
		bad "--only without a value still exits 2  <- rc=$rs_rc"
	fi

	rm -rf "$RS_STUB" "$RS_CONF" 2>/dev/null
else
	bad "fetch_rulesets.sh is missing from the package tree"
fi


# ------------------------------------------------- section enable semantics
section "Section enable semantics"

# 「界面勾选 ⇒ 后端必须当成启用」这条语义只有一个实现点：homeproxy.uc 的
# isSectionEnabled()。任何脚本再自己写 `enabled === '1'`，只要 UCI 里没有
# 这个键（旧版本建的段、备份还原、手工编辑），就会出现「界面显示启用、
# 后端当成关闭」——规则集一条都不下载、出站不进生成配置，日志里却没有
# 任何异常。下面的断言就是为了不再退回去。
HP_UC="$PKG/root/etc/homeproxy/scripts/homeproxy.uc"
GC_UC="$PKG/root/etc/homeproxy/scripts/generate_client.uc"
RS_SH="$PKG/root/etc/homeproxy/scripts/fetch_rulesets.sh"

case "$(grep -c 'export function isSectionEnabled' "$HP_UC" 2>/dev/null)" in
1) ok "homeproxy.uc exports isSectionEnabled" ;;
*) bad "homeproxy.uc exports isSectionEnabled" ;;
esac

case "$(grep -c 'isSectionEnabled' "$GC_UC" 2>/dev/null)" in
''|0) bad "generate_client.uc uses isSectionEnabled" ;;
*) ok "generate_client.uc uses isSectionEnabled" ;;
esac

gc_strict="$(grep -cE "\.enabled (===|!==) '1'" "$GC_UC" 2>/dev/null)"
case "$gc_strict" in
0) ok "generate_client.uc has no strict enabled gate" ;;
*) bad "generate_client.uc has no strict enabled gate  <- found $gc_strict" ;;
esac

case "$(grep -c 'section_enabled' "$RS_SH" 2>/dev/null)" in
''|0) bad "fetch_rulesets.sh gates on section_enabled" ;;
*) ok "fetch_rulesets.sh gates on section_enabled" ;;
esac

# 旧的严格门（正文里写成 enabled 必须等于 "1"）不得再出现：用固定串匹配，
# 避免把引号逃进模式里。
rs_strict="$(grep -cF '"$CONF.$sec.enabled")" = "1"' "$RS_SH" 2>/dev/null)"
case "$rs_strict" in
0) ok "fetch_rulesets.sh has no strict enabled gate" ;;
*) bad "fetch_rulesets.sh has no strict enabled gate  <- found $rs_strict" ;;
esac

# -------------------------------------------------------------- poll registry
section "Poll registry (hp.pollAdd)"
"$NODE" "$ROOT/tools/tests/poll_registry.test.cjs" > "$WORK/poll.out" 2>&1
if [ $? -eq 0 ]; then
	ok "poll_registry.test.cjs"
else
	bad "poll_registry.test.cjs"
	sed 's/^/       /' "$WORK/poll.out" | tail -20
fi

# -------------------------------------------------------------- DOM behaviour
# The four dropdown levels, exercised against a real log slice: the pure part of
# log.js is sliced out and evaluated (log.js cannot be require'd).
section "Log level filtering (frontend)"
"$NODE" "$ROOT/tools/tests/log_level.test.cjs" > "$WORK/loglevel.out" 2>&1
if [ $? -eq 0 ]; then
	ok "log_level.test.cjs"
	sed 's/^/       /' "$WORK/loglevel.out" | tail -4
else
	bad "log_level.test.cjs"
	sed 's/^/       /' "$WORK/loglevel.out" | tail -25
fi

section "Routing-node table DOM"
"$NODE" "$ROOT/tools/tests/routing_pin.test.cjs" > "$WORK/dom.out" 2>&1
case $? in
	0)  ok "routing_pin.test.cjs"; sed 's/^/       /' "$WORK/dom.out" | tail -6 ;;
	*)  if grep -q '^SKIP' "$WORK/dom.out"; then
			skip "jsdom unavailable (npm install jsdom)"
		else
			bad "routing_pin.test.cjs"; sed 's/^/       /' "$WORK/dom.out" | tail -30
		fi
		;;
esac

# ------------------------------------------------------ unified log rendering
# Renders the real log view under jsdom and fires one poll tick. This is the
# only check that would have caught a `shift` that fell out of scope between two
# .then callbacks: the promise chain rejected at request time, the box kept its
# "Collecting data..." spinner, and the page looked permanently unloaded.
section "Unified log rendering (jsdom)"
"$NODE" "$ROOT/tools/tests/logview_render.test.cjs" > "$WORK/logview.out" 2>&1
case $? in
	0)  ok "logview_render.test.cjs"; sed 's/^/       /' "$WORK/logview.out" | tail -3 ;;
	*)  if grep -q '^SKIP' "$WORK/logview.out"; then
			skip "jsdom unavailable (npm install jsdom)"
		else
			bad "logview_render.test.cjs"; sed 's/^/       /' "$WORK/logview.out" | tail -30
		fi
		;;
esac

# ------------------------------------------- CI 环境本身能否真跑这两个 DOM 测试
# 两个 jsdom 测试都有「装不上就 SKIP、退出码 0」的自我保护，这本来是防止 npm
# 抽风把 Lint 变红；但也意味着 **CI 上可能一次都没跑过而面板全绿**。jsdom >= 27
# 依赖 undici 7，undici 7 用到 node 22.15+ 才有的 zlib zstd 接口 —— Node 20 上
# require('jsdom') 直接抛 "Cannot read properties of undefined (reading 'bind')"，
# 于是两个 DOM 测试静默跳过（0.1.24 那个 `shift` 掉出作用域的 bug 正是靠它们才
# 抓到的）。反过来，jsdom 不钉版本时 npm 会自动升到新版，某个版本的 DOM 行为
# 差异又能把 Lint 变红（jsdom 26 的 InvalidCharacterError 就是这么来的）。
# 所以这两件事必须写死并被断言守住。
section "CI 环境（jsdom DOM 测试真的会跑）"

LINT_YML="$ROOT/.github/workflows/lint.yml"
if [ -f "$LINT_YML" ]; then
	if grep -qE "jsdom@[0-9]+\.[0-9]+" "$LINT_YML"; then
		ok "lint.yml pins the jsdom version"
	else
		bad "lint.yml installs an unpinned jsdom (a version bump can turn Lint red)"
	fi

	nv=$(grep -oE "node-version: *'[0-9]+'" "$LINT_YML" | grep -oE "[0-9]+" | head -1)
	if [ -n "$nv" ] && [ "$nv" -ge 22 ]; then
		ok "lint.yml runs Node >= 22"
	else
		bad "lint.yml runs Node ${nv:-?}: jsdom >= 27 cannot load there, both DOM tests silently skip"
	fi
else
	skip "lint.yml not present"
fi

# ------------------------------------------------ detached launcher (no nohup)
# iStoreOS 等精简 BusyBox **不带 nohup**（现场 `nohup: not found`，前台 shell
# 得到 Done(127)）。规则集下载曾用 `nohup ... &` 启动，于是 ubus 返回成功、
# 后台进程根本不存在：日志里一行规则集都没有，ruleset_download.log 也从未
# 生成。必须守住：
#   1. rpcd / init.d / 下载脚本里不得再出现裸 nohup 启动；
#   2. fetch_rulesets.sh 必须自带 --detach（忽略 SIGHUP + 后台 + 重定向）；
#   3. --detach 必须「启动器立刻返回，子进程继续跑」；
#   4. 日志写不进文件时必须降级到 stderr，不许静默。
section "detached launcher (no nohup)"

RS="$PKG/root/etc/homeproxy/scripts/fetch_rulesets.sh"
INITD="$PKG/root/etc/init.d/homeproxy"

hits=$(grep -nE 'nohup[[:space:]]+"?/(bin|usr/bin)/sh' "$HP_UC" 2>/dev/null | head -1)
if [ -n "$hits" ]; then
	bad "ucode starts background job via nohup (absent on iStoreOS): $hits"
else
	ok "ucode does not start background jobs via nohup"
fi

# update_core_async.sh 是有 `command -v nohup` 守卫的例外，其余脚本不许出现。
hits=$(grep -rn 'nohup' "$PKG/root/etc/init.d/homeproxy" "$RS" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -vE '不依赖|不能用|没有 nohup|no nohup|not found' | head -1)
if [ -n "$hits" ]; then
	bad "shell launches background job via nohup: $hits"
else
	ok "shell scripts do not launch background jobs via nohup"
fi

if grep -q -- '--detach' "$RS" && grep -q "trap '' HUP" "$RS"; then
	ok "fetch_rulesets.sh self-detaches (--detach + HUP ignored)"
else
	bad "fetch_rulesets.sh lacks --detach self-detach support"
fi

if grep -q "trap '' HUP" "$INITD"; then
	ok "init.d background ruleset pass ignores SIGHUP"
else
	bad "init.d background ruleset pass may be killed by SIGHUP"
fi

# 功能性验证：启动器必须立刻返回（0 秒级），下载在后台继续。
t0=$(date +%s)
/bin/sh "$RS" --detach --check >/dev/null 2>&1
rc=$?
t1=$(date +%s)
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -le 3 ]; then
	ok "--detach returns immediately (rc=0, $((t1 - t0))s)"
else
	bad "--detach did not return promptly (rc=$rc, $((t1 - t0))s)"
fi

if grep -q '>&2' "$RS"; then
	ok "log_msg falls back to stderr when the log file is unwritable"
else
	bad "log_msg can fail silently (no stderr fallback)"
fi

# ------------------------------------------- save&apply ruleset sync audit
# 0.1.22 现场教训：「保存并应用」触发规则集下载的整条链路曾有四个静默点，
# 任何一个断掉，用户看到的现象都一模一样 —— 点了没反应、两处日志都空白：
#   ① rpcd 的 ruleset_sync 带 --quiet，脚本跑没跑 logread 无从知晓；
#   ② ruleset_download.log 不在日志页的来源列表里，rpcd 脱管下载的明细
#      只有 SSH 能看；
#   ③ ruleset_download.log 不在 ACL 读名单里，就算挂上来源也读不到；
#   ④ 前端对 callRulesetSync 的拒绝 .catch(() => {}) 一吞（升级后 rpcd
#      未重启 → Method not found 正是最常见形态），界面毫无提示。
section "save&apply ruleset sync audit"

RPCD="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-homeproxy.json"
CJS="$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"
LOGJS="$PKG/htdocs/luci-static/resources/view/homeproxy/log.js"

if grep -q 'fetch_rulesets.sh --detach --quiet' "$RPCD"; then
	bad "rpcd ruleset_sync runs the download with --quiet (syslog stays blind)"
else
	ok "rpcd ruleset_sync drops --quiet (every step reaches logread)"
fi

if grep -q 'logger -t homeproxy ruleset_sync' "$RPCD"; then
	ok "rpcd ruleset_sync leaves a syslog audit line with its rc"
else
	bad "rpcd ruleset_sync is invisible in logread (no audit line)"
fi

if grep -q '"/var/run/homeproxy/ruleset_download.log"' "$ACL"; then
	ok "ACL grants read on ruleset_download.log"
else
	bad "ACL lacks ruleset_download.log (log page would show it as missing)"
fi

if grep -q "file: 'ruleset_download'" "$LOGJS"; then
	ok "log page reads ruleset_download.log directly"
else
	bad "log page cannot show the ruleset download log (detached path invisible)"
fi

if grep -A9 'callRulesetSync().then' "$CJS" | grep -q 'catch((e)'; then
	ok "frontend surfaces ruleset_sync request failures"
else
	bad "frontend swallows ruleset_sync rejections (.catch(() => {}))"
fi

# 0.1.23 现场：整段「保存并应用 → 规则集同步」其实从未执行过。
# 它被写成 `m.handleSaveApply = ...`（m 是 form.Map），外面还套了
# `typeof m.handleSaveApply === 'function'`；而 handleSaveApply 只存在于
# **view** 上（luci.js 的 view 基类，footer 按钮 createHandlerFn(this, ...)
# 绑的也是 view），form.Map 没有这个方法 → 判断恒假。
if grep -qE '^[[:space:]]*m\.handleSaveApply[[:space:]]*=' "$CJS"; then
	bad "Save&Apply hook is attached to form.Map (dead code: Map has no handleSaveApply)"
else
	ok "Save&Apply hook is not attached to form.Map"
fi

if grep -qE "^	handleSaveApply: function\(" "$CJS"; then
	ok "Save&Apply hook lives on the view definition"
else
	bad "view has no handleSaveApply override (Save&Apply cannot trigger anything)"
fi

if grep -q 'view.prototype.handleSaveApply' "$CJS"; then
	ok "view hook still runs the stock save+apply"
else
	bad "view hook would skip save+apply (base implementation not called)"
fi

# apply 成功、页面 reload 之前 LuCI 会派发 uci-applied；这是唯一能保证
# 「commit 已完成」的时机。轮询 uci.changes() 会与页面 reload 赛跑。
if grep -q "addEventListener('uci-applied'" "$CJS"; then
	ok "ruleset sync waits for the uci-applied event"
else
	bad "ruleset sync does not wait for apply to finish (reads stale config)"
fi

# 0.1.24 现场：uci-applied **不是每次保存并应用都派发**。ui.js 的 apply()
# POST admin/uci/apply_rollback，rpcd 侧「没有任何待提交变更」时回 204，
# LuCI 走 "There are no changes to apply" 分支 —— 不派发事件、不触发
# luci-reload、页面也不刷新。于是「SSH 里删了规则集文件、界面什么都没改、
# 想靠保存并应用补回来」这个最常见场景两条腿全不动，与 0.1.23 的死代码
# 表现完全一致。必须有定时兜底。
if grep -q 'rulesetSyncNet = setTimeout' "$CJS"; then
	ok "ruleset sync has a timer fallback (no uci-applied when there is nothing to apply)"
else
	bad "ruleset sync depends on uci-applied alone: LuCI skips it on a no-change apply (HTTP 204)"
fi

# 75 = 脚本让路（另一个下载在跑）。把它当失败弹红色警告是假警报。
if grep -q 'ret.rc === 75' "$CJS"; then
	ok "ruleset sync treats \"already running\" (rc=75) as success"
else
	bad "ruleset sync reports rc=75 (another download in progress) as a failure"
fi

# init.d 侧自登记：postinst 被跳过或 ucitrack 被清空时，服务启动一次就能补回。
INIT="$PKG/root/etc/init.d/homeproxy"
if grep -q 'hp_ucitrack_register' "$INIT" \
   && grep -A12 '^start_service()' "$INIT" | grep -q 'hp_ucitrack_register'; then
	ok "init.d re-registers ucitrack on every start (idempotent)"
else
	bad "init.d never self-heals the ucitrack entry"
fi

# 后端兜底：没有 procd 实例时 procd_add_reload_trigger 不生效，
# 只能靠 ucitrack 让 /sbin/luci-reload 主动调 init 脚本。
TRACK_UCI="$PKG/root/etc/uci-defaults/luci-homeproxy"
if grep -q 'ucitrack' "$TRACK_UCI" && grep -q 'ucitrack' "$PKG/Makefile"; then
	ok "ucitrack entry is registered (install + uci-defaults)"
else
	bad "no ucitrack entry: Save&Apply cannot reload the service without a procd instance"
fi

# 面板供应商卡片的「更新」按钮（PUT /providers/proxies/{name}）最终落到
# update_provider.sh。内核执行它时只要 /bin/sh 起来了就立刻回 204，脚本内部
# 任何提前退出都不会反馈给面板 —— 现象就是「按钮点了没反应」。所以：一不许
# 依赖外部 lock/flock（不是「没有」——iStoreOS 上 /bin/lock、/usr/bin/flock 都有，
# 而是这套写法既不释放锁、也保护不到后续步骤），二不许用 set -e 把失败变成静默
# 退出，三必须每步写主日志。
PROV="$PKG/root/etc/homeproxy/scripts/update_provider.sh"
if grep -vE '^[[:space:]]*#' "$PROV" | grep -qE '(^|[;[:space:]&|])(lock|flock)[[:space:]]'; then
	bad "update_provider.sh calls the external lock/flock command (absent on BusyBox, wrong syntax anyway)"
else
	ok "update_provider.sh never shells out to lock/flock"
fi

if grep -q 'mkdir "$LOCK_DIR"' "$PROV"; then
	ok "update_provider.sh serialises updates with an atomic mkdir lock"
else
	bad "update_provider.sh has no mkdir lock (two updates can clobber each other)"
fi

if grep -qE '^set -e' "$PROV"; then
	bad "update_provider.sh runs under set -e (a failure exits silently; the panel already got 204)"
else
	ok "update_provider.sh keeps failures visible (no blanket set -e)"
fi

if grep -q '机场更新完成' "$PROV" && grep -q '机场更新失败' "$PROV"; then
	ok "update_provider.sh logs both outcomes to the main log"
else
	bad "update_provider.sh does not log success/failure (a dead update looks identical to a working one)"
fi

if grep -q 'command -v ucode' "$PROV"; then
	ok "update_provider.sh runs the ucode updater through ucode (no exec bit needed)"
else
	bad "update_provider.sh execs the .uc file directly (a 644 script fails with Permission denied after the kernel already returned 204)"
fi

# 内置资源（china_ip4 / china_ip6 / gfw_list / china_list）走的是
# update_resources.sh，它和 update_provider.sh 犯过同一个错：用 `if ! lock -n …`
# 当互斥，而且**从不释放**（没有 `lock -u`、没有任何清理）。注意 `lock` 在这台
# 机器上是存在的（/bin/lock + /usr/bin/flock），`lock -n <新路径>` 也确实返回 0，
# 所以失败不是「命令不存在」也不是语法错 —— 是**锁文件残留**：只要某一次拿锁后
# 中途失败（curl 取不到 release tag、下载失败就 return 1），锁文件就永久留在
# /var/run 里，此后每次都是 rc=2「A task is already running.」，再也跑不动。
# 现场证据：/etc/homeproxy/resources/ 下文件 mtime 一直是打包日期（Mar 3 2026），
# 四份列表从来没更新过；`ls /var/run/homeproxy/*.lock` 能看到残留。反过来 grep
# 日志查不到这一句**不能证伪**：/var/run 是内存盘，重启即清空。
RES="$PKG/root/etc/homeproxy/scripts/update_resources.sh"
if grep -vE '^[[:space:]]*#' "$RES" | grep -qE '(^|[;[:space:]&|])(lock|flock)[[:space:]]'; then
	bad "update_resources.sh shells out to lock/flock (geodata never updates, log says \"A task is already running\")"
else
	ok "update_resources.sh never shells out to lock/flock"
fi

if grep -q 'mkdir "$LOCK_DIR"' "$RES"; then
	ok "update_resources.sh uses an atomic mkdir lock"
else
	bad "update_resources.sh has no mkdir lock (or still relies on the external lock command)"
fi

# 升级兼容（0.1.25 现场）：旧版用 **同名文件** 当锁（`lock -n` 创建、从不释放），
# 新版用的是 **同名目录**。升级后那个文件还留在 /var/run（内存盘，重启才清）里
# 挡路 → mkdir 恒失败 → 日志照样是「A task is already running.」，用户会以为
# 修复没生效，只能靠重启。两个脚本都必须先识别「存在但不是目录」再删掉。
for f in "$PROV" "$RES"; do
	if grep -q '\[ ! -d "\$LOCK_DIR" \]' "$f"; then
		ok "$(basename "$f") clears the stale lock FILE left by <= 0.1.24"
	else
		bad "$(basename "$f") cannot recover from the old lock file: the fix only works after a reboot"
	fi
done

# 供应商卡片左上角的「测速」按钮 = GET /providers/proxies/{name}/healthcheck，
# 由补丁内核实现（补丁 002）。原实现按顺序逐个测、每个节点等 10 秒：一个机场
# 几十个节点，只要几个连不通，整条请求就超过 zashboard 的 15 秒 axios 超时，
# 表现为「按钮转圈→报错→节点延迟一片空白」。必须并发测 + 整批封顶。
PATCH="$ROOT/tools/sing-box-patches/002-support-clash-proxy-providers-1.14.3-reF1nd.patch"
if grep -q 'providerHealthCheckConcurrency' "$PATCH" && grep -q 'sync\.WaitGroup' "$PATCH"; then
	ok "provider health check runs its nodes concurrently"
else
	bad "provider health check is serial (a 30-node airport blows past the panel's 15s timeout)"
fi

if grep -q 'time\.After(providerHealthCheckBudget)' "$PATCH" \
   && grep -q 'providerHealthCheckTimeout     = 3 \* time\.Second' "$PATCH"; then
	ok "provider health check is bounded (3s per node, 10s per batch)"
else
	bad "provider health check has no batch budget: one dead node can hold the whole reply"
fi

if grep -q '10\*time\.Second' "$PATCH"; then
	bad "provider health check still waits 10s per node"
else
	ok "provider health check no longer waits 10s per node"
fi

# 定时更新（cron → update_crond.sh → update_subscriptions.uc）必须在主日志里
# 留下可检索的痕迹，否则「到点了到底跑没跑」只能靠猜。
CRON="$PKG/root/etc/homeproxy/scripts/update_crond.sh"
if grep -q '^export PATH=' "$CRON"; then
	ok "update_crond.sh exports a usable PATH (cron has no login shell)"
else
	bad "update_crond.sh relies on cron's minimal PATH (curl/md5sum may be missing)"
fi

if grep -q '\[SCHEDULE\]' "$CRON" && grep -q '定时任务开始' "$CRON" && grep -q '定时任务结束' "$CRON"; then
	ok "update_crond.sh brackets a scheduled run with [SCHEDULE] lines"
else
	bad "update_crond.sh leaves no trace in the main log when cron fires"
fi

if grep -q 'ucode "$SCRIPTS_DIR/update_subscriptions.uc"' "$CRON"; then
	ok "update_crond.sh invokes the subscription updater through ucode"
else
	bad "update_crond.sh execs update_subscriptions.uc directly (silent Permission denied under cron)"
fi

if grep -q 'schedule-run' "$CRON" && grep -q "schedule-run" "$PKG/root/etc/homeproxy/scripts/update_subscriptions.uc"; then
	ok "scheduled runs are tagged so the log can tell cron from a manual click"
else
	bad "the subscription updater cannot tell a scheduled run from a manual one"
fi

SUB_UC="$PKG/root/etc/homeproxy/scripts/update_subscriptions.uc"
if grep -q '订阅更新开始：来源' "$SUB_UC" && grep -q '订阅更新完成' "$SUB_UC"; then
	ok "update_subscriptions.uc logs a readable start/finish banner"
else
	bad "update_subscriptions.uc logs neither a start nor a finish banner"
fi

INITD="$PKG/root/etc/init.d/homeproxy"
if grep -q '订阅自动更新已登记' "$INITD" && grep -q '未登记 cron' "$INITD"; then
	ok "init.d reports whether the subscription cron entry was registered"
else
	bad "init.d registers the subscription cron silently (an invalid time leaves no clue)"
fi

# ----------------------------------------------------------------- summary
printf '\n----------------------------------------\n'
if [ "$FAILED" -eq 0 ]; then
	printf 'ALL CHECKS PASSED (%d checks)\n' "$CHECKS"
	exit 0
fi

printf 'FAILED: %d of %d checks\n' "$FAILED" "$CHECKS"
printf 'Failed checks:%s\n' "$FAILLIST"

# A failing step's stdout is buried in a log that needs a login to read; the
# step summary is one click away on the run page, so repeat the list there.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		printf '### %d of %d checks failed\n\n' "$FAILED" "$CHECKS"
		printf '| failed check |\n|---|\n'
		printf '%s\n' "$FAILLIST" | sed -n 's/^  - //p' | sed 's/|/\\|/g; s/^/| /; s/$/ |/'
	} >> "$GITHUB_STEP_SUMMARY" 2>/dev/null
fi

exit 1
