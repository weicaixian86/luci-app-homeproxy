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
# 括号平衡必须单独查，不能只依赖 node --check：0.2.4 就是从这里漏出去的。
# `update_subscriptions.uc:1583` 多了一个 `)`（删掉「手动（经代理）」分支时
# 开括号少了、结尾的 `)` 没跟着删），设备上 ucode 直接
# `Syntax error: Unexpected token / Expecting ';'`，整个订阅脚本跑不起来。
# node 之所以没报，是因为文件里的 `import {` 是多行的、ucparse 当时只剥单行
# import，残留的 import 让 Node 把整份文件当 ESM —— 于是这个语句级错误
# 从头到尾没被检查。ucbalance.py 用词法级扫描，不看任何解析器的模式。
if "$PY" "$ROOT/tools/tests/ucbalance.py" \
	"$PKG/root/etc/homeproxy/scripts/"*.uc \
	"$PKG/root/usr/share/rpcd/ucode/"* \
	>"$WORK/ucbal.out" 2>"$WORK/ucbal.err"; then
	ok "balanced delimiters in every ucode source"
else
	bad "unbalanced delimiters  <- $(head -1 "$WORK/ucbal.err")"
fi

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

# ------------------------------------------------- ucode 方言（JS 惯性的雷）
# ucode 不是 JS：没有 Math/JSON/Object/Array/String/Number 这些包装对象
#（用了报 "left side of . operator is not an object"，rpcd 再折叠成
# Command failed: Unknown error）。这类写法在 JS 里完全合法，ucparse/node
# --check 一定放行，只能在这里剥掉注释与字符串后整篇扫一遍（注释里允许
# 出现这些词作警示文字，所以要先剥再扫）。
#
# 2026-10-26 真机（iStoreOS）实测四条：
#   * **`undefined` 不是关键字**，只是一个普通标识符；在 **.uc 模块**（有
#     import、按闭包编译）里读它直接抛 `access to undeclared variable
#     undefined`。0.2.03 在 packet_encoding 归一函数里写了
#     `value === undefined` 与 `config.packet_encoding === undefined`，异常
#     被 parse_uri 每节点的 try/catch 吞成一行 `Skipping unparsable node
#     entry`，**vless + vmess 整批消失**（hy2/trojan/anytls 不经过该函数，
#     毫发无损）。设备日志实证：`Successfully fetched 14 nodes of total 31`
#     而 vless 计数为 0。
#     ⚠️ `ucode -e` 探针验不出这条：`-e` 在全局作用域跑，读 `undefined`
#     不抛（`o.missing === undefined` 返回 true），会给出**假阴性**。当日
#     就是被这个假阴性误导，把已经正确的修复撤回了一轮。
#   * `var a = 1` => `Syntax error: Unexpected token`（报错位置指向 `var`
#     后面那个标识符）—— 这台设备的 ucode 只认 let/const。后果最彻底：
#     整份文件编译不过、一个节点都更新不了，而静态校验看不出来。
#   * `lc("AB")` => ab、`uc("ab")` => AB —— 这两个**都存在可用**（原记录
#     说「lc 不是全局函数」是错的）。仍然一并禁掉：项目里没人需要它们。
#   * `"xudp" in ["xudp","XUDP"]` => true —— `in` 对数组是**值匹配**，不是
#     JS 的键匹配，白名单可以放心写（generate_client.uc 的
#     `routing_mode in [...]` 一直有效）。
section "ucode dialect (no JS habits, no var)"
if "$PY" - "$PKG" <<'PYUC' 2>"$WORK/ucdialect.err"; then
import re, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'root'
BAD = re.compile(r'\b(lc|uc|var|undefined|Math|JSON|Object|Array|String|Number)\b')
hits = []
for f in sorted(root.rglob('*.uc')) + sorted((root / 'usr/share/rpcd/ucode').glob('*')):
    if not f.is_file():
        continue
    src = f.read_text(encoding='utf-8', errors='replace')
    out = []
    i, n, in_blk, in_line, q = 0, len(src), False, False, None
    while i < n:
        c = src[i]
        nxt = src[i+1] if i + 1 < n else ''
        if q:
            if c == '\\': i += 2; continue
            if c == q: q = None
            i += 1; continue
        if in_blk:
            if c == '*' and nxt == '/': in_blk = False; i += 2; continue
            i += 1; continue
        if in_line:
            if c == '\n': in_line = False; out.append(c)
            i += 1; continue
        if c == '/' and nxt == '*': in_blk = True; i += 2; continue
        if c == '/' and nxt == '/': in_line = True; i += 2; continue
        if c in ('\'', '"', '`'): q = c; i += 1; continue
        out.append(c); i += 1
    code = ''.join(out)
    for ln, line in enumerate(code.split('\n'), 1):
        if BAD.search(line):
            hits.append('%s (code line %s): %s' % (f.name, ln, line.strip()[:70]))
if hits:
    print('\n'.join(hits[:10]), file=sys.stderr)
    sys.exit(1)
PYUC
	ok "ucode files contain no JS-only globals (lc/uc/var/undefined/Math/JSON/…)"
else
	bad "ucode uses JS habits that throw on device ($(head -1 "$WORK/ucdialect.err" | cut -c1-80))"
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

# /etc/localtime 是 → /tmp/localtime 的符号链接时，jail 里的 /tmp 是另一份
# tmpfs：只挂链接本身等于挂了一条断链，Go 打不开就静默回 UTC，而标记仍写
# local。链接目标必须一起挂进去。
if grep -q 'readlink -f /etc/localtime' "$INITD" \
   && [ "$(grep -c 'LOCALTIME_TARGET' "$INITD")" -ge 3 ]; then
	ok "the /etc/localtime symlink target is mounted into the jail too"
else
	bad "jail mounts only the /etc/localtime symlink (its target is invisible => UTC)"
fi

LOG_JS="$PKG/htdocs/luci-static/resources/view/homeproxy/log.js"
# 0.1.28 把读文件 / 切记录 / 合并 / 渲染搬进了共用模块：运行日志、插件日志、
# 内核日志三个面板各传一份来源清单，解析和渲染只有这一份实现。
LOGVIEW="$PKG/htdocs/luci-static/resources/homeproxy/logview.js"
# LuCI 的 L.require() 用 Class.isSubclass() 校验工厂的返回值：必须是
# baseclass.extend() 出来的构造器，普通对象在新版 LuCI 上直接抛
# `TypeError: "<name>" factory yields invalid constructor`，日志页整页打不开
# （0.1.28 就是这么挂的）。
# 导出必须走 HP_CLASS（注入的 baseclass，取不到时退回 L.Class）：包里的 JS
# 是压缩过的单行，`'require baseclass';` 这条字符串指令不一定还留在源码里，
# 所以不能只认 baseclass 一条路。typeof 守卫也不能省——没被注入时直接引用
# 未声明的 baseclass 会抛 ReferenceError。
if grep -q '^return HP_CLASS.extend({$' "$LOGVIEW" \
   && grep -q "typeof baseclass !== 'undefined'" "$LOGVIEW" \
   && grep -q 'L.Class' "$LOGVIEW"; then
	ok "logview.js exports a LuCI class (require() rejects a plain object)"
else
	bad "logview.js returns a plain object: newer LuCI refuses it, the log page never opens"
fi

if grep -q 'core_tz' "$LOGVIEW" && grep -q 'shiftTs' "$LOGVIEW" \
   && grep -q 'core: true' "$LOG_JS"; then
	ok "log view puts the core's stamps on the local clock"
else
	bad "log view would keep two clocks (core_tz marker not consumed)"
fi

# 标记文件与六个日志都靠 fs.read_direct 读，而它走 /cgi-bin/cgi-download ——
# 和 ubus 的 file.read **同一套 ACL**。名单里漏一个就是 403，前端
# `.catch(() => 0)` 会把它当成「老版本没有标记」：偏移 0 → 内核日志停在 UTC，
# 比其它五个源整整差 8 小时，界面上却一句提示都没有（而且测试里的 fs 是桩，
# 永远读得到，只有 ACL 这一层是桩测不到的）。core_tz 就是这么漏的。
ACL_JSON="$PKG/root/usr/share/rpcd/acl.d/luci-app-homeproxy.json"
acl_missing=""
for acl_f in $(sed -n "s/.*{ file: '\([^']*\)'.*/\1/p" "$LOG_JS"); do
	grep -q "\"/var/run/homeproxy/$acl_f.log\"" "$ACL_JSON" || acl_missing="$acl_missing $acl_f.log"
done
grep -q '"/var/run/homeproxy/core_tz"' "$ACL_JSON" || acl_missing="$acl_missing core_tz"
if [ -z "$acl_missing" ]; then
	ok "ACL grants read on every file the log view opens (six logs + core_tz)"
else
	bad "ACL does not grant read on:$acl_missing (403 → blank box / core clock 8h off)"
fi

# fs.read_direct 走 /cgi-bin/cgi-download，而 cgi-io 的下载小应用有**两道**
# 授权：先查会话有没有 scope=cgi-io / object=download / function=read 的授权
# （缺了回 403 "Download permission denied"），**之后**才轮到上面那份 file
# 名单（缺路径回的是另一句 "Access to path denied by ACL"）。只配文件路径、
# 不配 cgi-io:download 时六个日志全部 403——0.1.28 现场正是这句报错；之前
# 一直没被发现是因为更早的 bug（页面根本打不开）把它盖住了。上游的惯例
# 是各 app 在自己的 ACL 里声明（luci-mod-status 就带 "cgi-io": [ "exec" ]）。
if "$PY" - "$ACL_JSON" <<'PYACL' 2>/dev/null; then
import json, sys
acl = json.load(open(sys.argv[1], encoding='utf-8'))['luci-app-homeproxy']
assert acl['read'].get('cgi-io') == ['download'], 'read.cgi-io != [download]'
PYACL
	ok "ACL grants cgi-io download (fs.read_direct needs it BEFORE the file list)"
else
	bad "ACL lacks cgi-io:download — every read_direct 403s with 'Download permission denied'"
fi

# ------------------------------------------------ unified log view (levels)
# All four levels share ONE poll registration, so the 5 s cadence cannot vary
# by level. Two things around it are easy to break: the level has to reach
# BOTH the client and server config sections (each generator reads its own),
# and a rebuild of the scroller must not throw the reader back to line 1.
section "unified log view (levels + refresh)"

lv="$(sed -n '/const level_choices = {/,/};/p' "$LOG_JS" \
	| sed -n 's/^[[:space:]]*\([a-z]*\)[[:space:]]*:.*/\1/p' | sort | tr '\n' ' ')"
if [ "$lv" = "debug error info warn " ]; then
	ok "level choices are exactly debug/info/warn/error"
else
	bad "level choices are '$lv' (sing-box accepts debug/info/warn/error)"
fi

# 两个日志面板（插件日志 / 内核日志）各注册自己的轮询，间隔都来自日志设置。
# 间隔写死在前端就等于「设置页改了没反应」。
if [ "$(grep -c "key: 'log-" "$LOG_JS")" = 2 ] \
   && grep -q 'callSettings' "$LOGVIEW" \
   && ! grep -qE "pollAdd\('log-[a-z-]*', refresh, *[0-9]" "$LOG_JS"; then
	ok "each log panel registers one poll, interval comes from 日志设置"
else
	bad "log refresh interval is hardcoded (or a panel registers twice)"
fi

if grep -q "uci.set('homeproxy', 'config', 'log_level'" "$LOG_JS" \
   && grep -q "uci.set('homeproxy', 'server', 'log_level'" "$LOG_JS"; then
	ok "level change commits to both client and server sections"
else
	bad "level change misses a section (client or server keeps old verbosity)"
fi

# 「内核日志级别：」要 save + apply，就得拿到 form.Map。LuCI 调 `o.render()`
# 时**不保证**把 map 带在参数里（jsdom 里 ctx 干脆是 undefined），而面板自己
# 也拿不到 view 实例 —— 只写 `ctx.map.save()` 会在真改级别时抛
# `Cannot read properties of undefined (reading 'save')`。所以由 renderTabs
# 从 `L.bind(renderTabs, this)` 绑进来的 view 上取，再显式传给面板。
if grep -q 'const map = (ctx && ctx.map) ? ctx.map : (this && this.map)' "$LOG_JS" \
   && grep -q 'build(ctx, retune, map)' "$LOG_JS" \
   && grep -q 'function renderCorePanel(ctx, onSaved, map)' "$LOG_JS"; then
	ok "the core level switch can reach form.Map (renderTabs passes it down)"
else
	bad "the core level switch relies on ctx.map alone (undefined => save throws)"
fi

if grep -q 'function scrollState' "$LOGVIEW" && grep -q 'restoreScroll(scroll)' "$LOGVIEW"; then
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
if grep -q "missing ? null" "$LOGVIEW" && grep -q "src.file + '.log'" "$LOGVIEW"; then
	ok "missing log files are silent; real read errors name the file"
else
	bad "missing log files still render as rows (or errors are unnamed)"
fi

# "Clean log" walks the frontend's log_sources, but the rpcd call has its own
# whitelist. When a source is added to the view and not to the whitelist the
# call rejects with 'illegal type' and L.resolveDefault() hides it — the
# button looks fine while one file is never cleared. Keep the two lists equal.
UCODE="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
log_srcs="$(sed -n "s/^[[:space:]]*{ file: '\([^']*\)'.*/\1/p" "$LOG_JS" \
	| sort | tr '\n' ' ')"
clean_wl="$(sed -n "/log_clean: {/,/return { result: true }/p" "$UCODE" \
	| sed -n "s/.*in \[\(.*\)\].*/\1/p" | tr -d "'" | tr ',' '\n' \
	| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ' ')"
if [ -n "$log_srcs" ] && [ "$log_srcs" = "$clean_wl" ]; then
	ok "log_clean whitelist matches the merged log sources"
else
	bad "log_clean whitelist '$clean_wl' != log sources '$log_srcs' (Clean log no-ops on one)"
fi

# 0.1.28：显示不再按条数截断。以前是「最多 1000 行 + 一句红字」——文件里
# 明明有更早的记录、界面上却看不到，而且「能看多少」和「文件能长多大」是两个
# 互不相干的数字。现在只有一个上限：日志文件本身的大小（日志设置里可改）。
if ! grep -q 'LOG_MAX_LINES' "$LOGVIEW" && ! grep -q 'flat.splice' "$LOGVIEW" \
   && ! grep -q 'only the last %s lines' "$LOGVIEW"; then
	ok "the log box shows every line in the file (no line-count cap)"
else
	bad "the log box still truncates by line count (size limit should be the only cap)"
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

# ── 日志页：四个选项卡 + 日志设置（0.1.28）──────────────────────────────────
# 需求：页面本身是「运行日志」，页面里再挂三个二级选项卡（日志设置 /
#   插件日志 / 内核日志），排成一行灰色按钮，点中的那个高亮（参考用户给的结构图）；
#   日志设置能改刷新时间与日志文件大小上限（数字 1–999 + 单位 KB / MB）；
#   显示不再限制条数，改为限制文件大小；
#   插件日志 / 内核日志不分级别、全部显示。
section "log tabs + log settings (0.1.28)"

RPCD="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
MENU="$PKG/root/usr/share/luci/menu.d/luci-app-homeproxy.json"

# 侧栏/顶部页签里只剩「运行日志」一项：LuCI 的菜单只有两级，挂第三级侧栏
# 根本不渲染，所以三个二级选项卡画在页面里。0.1.28 初版做成了三个平级菜单项，
# 用户看到的正是这个问题（三个选项卡跟运行日志并排，而不是在它下面）。
if ! grep -q 'homeproxy/log_settings\|homeproxy/log_plugin\|homeproxy/log_core' "$MENU"; then
	ok "sidebar has one log entry: the other three are tabs, not menu items"
else
	bad "the three tabs are separate menu entries (they must live under 运行日志)"
fi

for f in log_settings log_plugin log_core; do
	if [ -e "$PKG/htdocs/luci-static/resources/view/homeproxy/$f.js" ]; then
		bad "view $f.js still exists (the four tabs live in log.js)"
	fi
done
ok "the three old log views are gone (one page, three sub-tabs)"

tabs="$(sed -n '/^const TABS = \[/,/^\];/p' "$LOG_JS" \
	| sed -n "s/.*id: '\([a-z]*\)'.*/\1/p" | tr '\n' ' ')"
if [ "$tabs" = "settings plugin core " ]; then
	ok "panel order is 日志设置 → 插件日志 → 内核日志"
else
	bad "panel order is '$tabs' (0.1.28 末版：三个二级选项卡，没有 runtime 面板)"
fi

# 这一排就是这一页的全部内容：页面本身（顶部那个「运行日志」页签）**没有**
# 自己的面板。0.1.28 末版把「六个文件合并 + 两个下拉」那一屏去掉了 —— 它和
# 下面三屏重复，而把默认面板改成插件日志之后它就没有任何入口了。
# 判据：不能有 base: true / SUB_TABS（那是「运行日志 = 页面本身」的旧写法），
# 而且要显式声明 DEFAULT_TAB 并默认激活它。
if ! grep -q 'base: true' "$LOG_JS" && ! grep -q 'SUB_TABS' "$LOG_JS" \
   && [ "$(grep -c 'TABS\.forEach' "$LOG_JS")" = 1 ] \
   && grep -q "DEFAULT_TAB = 'plugin'" "$LOG_JS" \
   && grep -q 'activate(DEFAULT_TAB)' "$LOG_JS"; then
	ok "the strip holds the three sub-tabs and opens on 插件日志"
else
	bad "the log page does not open on 插件日志 (or 运行日志 still has its own panel)"
fi

# 两个日志面板都是 lazy：只有当前显示的那个轮询。否则每点过一个选项卡就多
# 一个定时器，六个日志文件每轮被读两遍 —— /var/run 是内存盘。
if [ "$(grep -c 'lazy: true' "$LOG_JS")" = 2 ] \
   && grep -q 'typeof prev.page.stop' "$LOG_JS"; then
	ok "only the visible tab polls (hidden panels are stopped)"
else
	bad "every panel keeps polling after its tab is left (wasted reads on tmpfs)"
fi

# 两个日志面板都**不许有任何过滤器**（0.1.28 末版：插件日志的「显示：」下拉
# 也删了）。一旦哪个面板开始过滤，「文件里有、界面上没有」就又出现了。
PLUGIN_FN="$(sed -n '/^function renderPluginPanel/,/^}/p' "$LOG_JS")"
CORE_FN="$(sed -n '/^function renderCorePanel/,/^}/p' "$LOG_JS")"
case "$PLUGIN_FN$CORE_FN" in
	*filter:*|*log_view*|*hp_log_view*) bad "a log panel filters by view or level (rows would disappear)" ;;
	*) ok "both log panels pass no filter: every level is shown" ;;
esac

# 用户要求：插件日志 / 内核日志 框底下那行「每 N 秒刷新。· 先点击日志区域…」
# 不要。两个面板都得显式传 hint: false；运行日志页不传（保持有提示）。
if [ "$(printf '%s' "$PLUGIN_FN$CORE_FN" | grep -c 'hint: false')" = 2 ] \
   && grep -q "o.hint === false" "$LOGVIEW"; then
	ok "plugin/core panels drop the refresh hint line"
else
	bad "the refresh/Ctrl+A hint still shows under the plugin or core log"
fi

# 唯一剩下的下拉是「内核日志级别：」，它必须在内核日志那一屏（会改配置并
# 重启内核）。插件日志顶栏一个 select 都不许有。
if printf '%s' "$CORE_FN" | grep -q "_('Core log level:')" \
   && ! printf '%s' "$CORE_FN" | grep -q "_('Show:')" \
   && ! printf '%s' "$PLUGIN_FN" | grep -qE "_\('Core log level:'\)|<select|E\('select'" ; then
	ok "内核日志级别 sits on 内核日志; the plugin panel has no dropdown at all"
else
	bad "a dropdown is on the wrong panel (or the plugin panel grew one)"
fi

# 顶栏的孩子必须是**一维**数组：LuCI 的 E() 不会摊平嵌在 children 里的数组，
# 不是节点就一律 createTextNode(child) —— Array.toString() 把每个元素都变成
# `[object HTMLDivElement]`，界面上就多出一串
# `[object HTMLDivElement],[object HTMLDivElement]`（0.1.28 现场：o.head 是
# 两个 div）。判据：head 必须先 concat 成一维，且不能再原样嵌进 children。
if grep -q 'const topbar = \[\].concat(o.head || \[\])' "$LOGVIEW" \
   && ! grep -q '(o.head || \[\]),' "$LOGVIEW"; then
	ok "the log top bar gets a flat child list (a nested array becomes [object …])"
else
	bad "o.head is nested inside E() children: LuCI prints [object HTMLDivElement]"
fi

# 用户 0.1.28 现场（红框）：选项卡与内容之间那片空白。顶栏原来单独是一个
# cbi-section、日志框是另一个 —— section 自带的外边距/边框叠在中间，没传
# head 时顶栏还整条空着。现在两者在同一个 .hp-log-panel 里，容器自己不是
# cbi-section，顶栏只在真有控件时才建。jsdom 那两个测试是同一判据的运行期
# 版本（负例实测：容器 class 加回 cbi-section → 立刻红）。
if ! grep -q "class': 'cbi-section" "$LOGVIEW" \
   && grep -q "E('div', { 'class': 'hp-log-panel' }, panel)" "$LOGVIEW" \
   && grep -q 'if (topbar.length)' "$LOGVIEW"; then
	ok "the top bar and the log box share one container (no blank strip)"
else
	bad "the log top bar is a separate cbi-section again (a blank strip appears)"
fi

# 用户 0.1.28：警告 / 错误行要上色。判定与过滤器共用 isWarnRecord /
# isErrorRecord，所以「错误视图里看到的那几条」在「全部」里也一定是红的。
if grep -q 'recordSeverity' "$LOGVIEW" && grep -q 'hp-log-warn' "$LOGVIEW" \
   && grep -q 'hp-log-error' "$LOGVIEW"; then
	ok "warning/error rows are coloured (same predicate as the filter)"
else
	bad "warning/error rows have no colour class"
fi

# 用户 0.1.28：插件日志 / 内核日志里的**每一行**都要有时间戳，还要有
# [INFO] / [ERROR] 这样的标记。内核原本写裸的 `INFO router: …`，插件那四份
# 日志连 token 都没有 —— 所以两者都在渲染时补：`时间戳 [级别] 正文`。
# 三条一起检，缺一条就会退化成「有的行有标记、有的行没有」：
#   ① 首行由 firstLineOf() 统一拼（时间戳 + 级别 + 正文）；
#   ② 级别标记与颜色/过滤同源（recordTag 走 recordSeverity，不另写一套正则）；
#   ③ 正文里那个裸 token 与 "+0000 " 前缀必须被掐掉，否则 `INFO [INFO] …`。
if grep -q 'function firstLineOf' "$LOGVIEW" && grep -q 'firstLineOf(rec)' "$LOGVIEW" \
   && grep -q 'function recordTag' "$LOGVIEW" && grep -qF 'tail.slice(lm ? lm[0].length : 0)' "$LOGVIEW" \
   && ! grep -q 'body = line.replace' "$LOGVIEW"; then
	ok "every row gets a timestamp and a bracketed level tag (one source of truth)"
else
	bad "log rows do not carry a uniform '<ts> [LEVEL] ' prefix"
fi

# 刷新间隔 2–120 秒：注册轮询、设置页夹取、rpcd 夹取必须是同一个范围，
# 否则「界面填 300」会在下一层被悄悄改成别的值。
if grep -q 'refresh_min: 2, refresh_max: 120' "$RPCD" \
   && grep -q 'REFRESH_MIN = 2' "$LOGVIEW" && grep -q 'REFRESH_MAX = 120' "$LOGVIEW" \
   && [ "$(grep -c 'REFRESH_MIN, REFRESH_MAX' "$LOGVIEW")" -ge 2 ]; then
	ok "the refresh interval is 2–120 s in the UI, the poller and rpcd"
else
	bad "the refresh interval range differs between UI, poller and rpcd"
fi

# 设置必须写在 /etc/homeproxy/log.conf，不能进 uci：uci commit 会改
# /etc/config/homeproxy 的 mtime → procd 的 config.change → reload_service，
# 也就是「为了改个刷新间隔把隧道重启一次」。所以只切出设置面板来检。
printf '%s\n' "$(sed -n '/^function renderSettingsPanel/,/^}/p' "$LOG_JS")" > "$WORK/logset.fn.js"
if ! grep -q 'uci\.' "$WORK/logset.fn.js" && grep -q 'logview.saveSettings' "$WORK/logset.fn.js"; then
	ok "log settings never touch uci (a commit would restart the core)"
else
	bad "log settings go through uci: saving them reloads (stop+start) the service"
fi

# 用户 0.1.28：「日志大小上限」被拆成了两行（数字一行、单位一行），中间夹着
# 别的行时看不出是一件事。现在同一个 .hp-logset-row 里既有数字框也有单位下拉。
if [ "$(grep -c 'hp-logset-row' "$WORK/logset.fn.js")" = 2 ] \
   && ! grep -q 'Log size limit unit' "$LOG_JS"; then
	ok "size limit + unit share one row (no separate unit row)"
else
	bad "the size limit is still split over two rows"
fi

if grep -q 'log_settings_save' "$RPCD" && grep -q '/log.conf' "$RPCD" \
   && grep -q 'mv -f' "$RPCD"; then
	ok "rpcd writes log.conf atomically (no half-written file at the 180s boundary)"
else
	bad "rpcd has no log_settings_save / writes log.conf in place"
fi

# 单位只有 KB / MB 两档（GB 已按用户要求移除），三处必须同时认识：前端下拉、
# rpcd 的换算表、轮转脚本的 case 分支。少一处就是「界面选 1 MB、实际按 1 KiB 轮转」。
# 同时断言 GB 已经彻底消失，没人能把它偷偷加回来。
if grep -q "UNIT_BYTES" "$LOGVIEW" && grep -q "KB:" "$LOGVIEW" && grep -q "MB:" "$LOGVIEW" \
   && ! grep -q "GB:" "$LOGVIEW" \
   && grep -q "LOG_UNITS" "$RPCD" && grep -q "KB:" "$RPCD" \
   && ! grep -q "LOG_UNITS.GB" "$RPCD" \
   && grep -q 'KB|kb' "$CL_LOG" && ! grep -q 'GB|gb' "$CL_LOG" \
   && grep -q 'logSizeRange' "$RPCD" && grep -q 'size_max: 999' "$RPCD"; then
	ok "only KB / MB remain (GB is gone from the UI, rpcd and clean_log.sh)"
else
	bad "the unit list drifted: GB is still present somewhere, or KB/MB is missing"
fi

if grep -q 'LOG_CONF' "$CL_LOG" && grep -q 'resolve_limit' "$CL_LOG" \
   && [ "$(grep -c 'resolve_limit' "$CL_LOG")" -ge 2 ]; then
	ok "clean_log.sh re-reads the size limit on every round (no restart needed)"
else
	bad "clean_log.sh reads the limit once: a new value only applies after a restart"
fi

# 功能性验证：把三个函数切出来，按真实的 log.conf 计算阈值。这一项防的是
# 「写的是 1 MB、实际按 1 KB 轮转」这种只在设备上才看得见的偏差。
CL_FN="$WORK/cleanlog.fn.sh"
sed -n '/^log_conf_get()/,/^}/p;/^resolve_limit()/,/^}/p' "$CL_LOG" > "$CL_FN"
cat > "$WORK/cleanlog.probe.sh" <<'PROBE'
NAME=homeproxy
RUN_DIR=/var/run/homeproxy
LOG_CONF="$1"
MIN_SIZE=1
MAX_SIZE=999
uci() { return 1; }
. "$CL_FN"
resolve_limit
printf '%s' "$log_max_bytes"
PROBE

cl_probe() {
	printf '%s\n' "$2" > "$WORK/cleanlog.conf"
	CL_FN="$CL_FN" sh "$WORK/cleanlog.probe.sh" "$WORK/cleanlog.conf" 2>/dev/null | tr -d '\r'
}

case "$(cl_probe mb 'size=1
unit=MB')" in
	1048576) ok "log.conf size=1 unit=MB means 1 MiB (what the UI shows)" ;;
	*) bad "log.conf size=1 unit=MB does not become 1 MiB" ;;
esac

case "$(cl_probe kb 'size=512
unit=KB')" in
	524288) ok "log.conf size=512 unit=KB means 512 KiB" ;;
	*) bad "the KB unit is ignored (threshold would be 512 MiB)" ;;
esac

case "$(cl_probe kbmax 'size=1200
unit=KB')" in
	1022976) ok "anything past 999 KB is clamped to the 999 ceiling (1200 -> 999 KiB)" ;;
	*) bad "size=1200 unit=KB is not clamped to 999 (the field allows 1-999)" ;;
esac

case "$(cl_probe mbmax 'size=2048
unit=MB')" in
	1047527424) ok "anything past 999 MB is clamped to 999 MiB" ;;
	*) bad "size=2048 unit=MB is not clamped (a tmpfs log would eat the RAM)" ;;
esac

case "$(cl_probe legacy_gb 'size=2
unit=GB')" in
	2097152) ok "a legacy unit=GB in log.conf is read as MB (2 -> 2 MiB)" ;;
	*) bad "a legacy GB value is still treated as GiB (GB was removed from the UI)" ;;
esac

case "$(cl_probe zero 'size=0
unit=MB')" in
	1048576) ok "a zero size is clamped to 1 MB (the number floor is 1)" ;;
	*) bad "size=0 would leave the log with no room at all" ;;
esac

: > "$WORK/cleanlog.conf"
case "$(CL_FN="$CL_FN" sh "$WORK/cleanlog.probe.sh" "$WORK/cleanlog.conf" 2>/dev/null | tr -d '\r')" in
	1048576) ok "an install without log.conf falls back to 1 MiB" ;;
	*) bad "no log.conf and no uci value does not fall back to 1 MiB" ;;
esac


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

# ---------------------------------------------------------- config guard
section "config guard (config wiped on upgrade)"
# 0.2.5 装机实测：apk 用包内默认模板覆盖了 /etc/config/homeproxy（72242 字节、
# 90 个节点 → 2795 字节、0 个节点），5 条订阅一次丢光。Makefile 的 conffiles
# 只声明了 /etc/config/homeproxy，apk 侧本应留成 .apk-new，实际没有；根因未定位。
# 所以加一道与包管理器行为无关的保险，三条要求：
#   ① start_service 每次成功启动刷新备份（/etc/homeproxy/config.uci.bak）；
#   ② postinst 末尾：当前配置没有任何 node 段、备份里有 → 还原并留 .apk-new；
#   ③ **没有节点的配置永远不能覆盖备份**——否则第一次被覆盖时备份也跟着变默认
#      模板，保险反过来变成帮凶。这一条是整段测试里最要紧的。
GUARD="$PKG/root/etc/homeproxy/scripts/config_guard.sh"
if [ -f "$GUARD" ]; then
	GC="$WORK/guard"; rm -rf "$GC"; mkdir -p "$GC"
	printf "config homeproxy 'config'\n\toption main_node 'n1'\n\nconfig node 'n1'\n\toption type 'vless'\n" >"$GC/good"
	printf "config homeproxy 'config'\n\toption main_node 'n1'\n" >"$GC/default"
	gc() { env HP_CONFIG="$GC/homeproxy" HP_CONFIG_BAK="$GC/config.uci.bak" HP_LOG="$GC/log" sh "$GUARD" "$1"; }

	cp "$GC/good" "$GC/homeproxy"
	gc backup
	if [ -f "$GC/config.uci.bak" ] && grep -q "^config node" "$GC/config.uci.bak"; then
		ok "backup: a config that has node sections is saved"
	else
		bad "backup: nothing saved although the config has node sections"
	fi

	cp "$GC/default" "$GC/homeproxy"
	gc backup
	if grep -q "^config node" "$GC/config.uci.bak"; then
		ok "backup: a config without nodes never overwrites the good backup"
	else
		bad "backup: the default template overwrote the good backup (the guard becomes the accomplice)"
	fi

	gc restore
	if [ "$(grep -c '^config node' "$GC/homeproxy")" = "1" ] && [ -f "$GC/homeproxy.apk-new" ]; then
		ok "restore: a wiped config is restored, the wiped copy kept as .apk-new"
	else
		bad "restore: the wiped config was not restored from the backup"
	fi

	gc restore
	if [ "$(grep -c '^config node' "$GC/homeproxy")" = "1" ]; then
		ok "restore: running twice is harmless"
	else
		bad "restore: a second run damaged the restored config"
	fi

	# 用 mv 而不是 rm：某些环境把 rm 换成了安全删除的壳，路径判定失败时会静默
	# 不删，于是「没有备份」这一条变成假通过。
	mv -f "$GC/config.uci.bak" "$GC/config.uci.bak.off"
	gc restore
	if [ "$(grep -c '^config node' "$GC/homeproxy")" = "1" ]; then
		ok "restore: no backup means no change"
	else
		bad "restore: it touched the config although there was no backup"
	fi
else
	bad "scripts/config_guard.sh is missing: an apk upgrade can wipe /etc/config/homeproxy silently"
fi

if grep -q 'config_guard.sh restore' "$PKG/Makefile" 2>/dev/null \
   && grep -q 'config_guard.sh" backup' "$PKG/root/etc/init.d/homeproxy" 2>/dev/null; then
	ok "config guard is wired into postinst (restore) and start_service (backup)"
else
	bad "config guard is not wired: postinst never restores, or start_service never backs up"
fi

# 备份必须排在 start_service 的早退判定之前。现场就有这种配置：custom 路由
# 模式、91 个节点，但 default_outbound 为空 → outbound_node=nil → start_service
# 直接 return。备份若留在函数末尾，这种配置永远不会有备份，装包时
# config_guard restore 也无从还原。同理，内核校验失败那一次同样需要备份。
BAK_LINE=$(grep -n 'config_guard.sh" backup' "$PKG/root/etc/init.d/homeproxy" | head -1 | cut -d: -f1)
EARLY_LINE=$(grep -n 'local outbound_node' "$PKG/root/etc/init.d/homeproxy" | head -1 | cut -d: -f1)
if [ -n "$BAK_LINE" ] && [ -n "$EARLY_LINE" ] && [ "$BAK_LINE" -lt "$EARLY_LINE" ]; then
	ok "the config backup happens before start_service can return early"
else
	bad "the config backup sits after the early return: a config with nodes but no outbound would never be backed up"
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

# 四个选项卡是同一页里的东西：切走要停轮询、切回来不能变成空白。0.1.28 初版
# 把它们做成了三个独立菜单项（跟运行日志平级），这里真跑一遍 log.js 的
# renderTabs()，只有运行期才能验证「节点复用 / 轮询开关」这两件事。
section "Log tabs (jsdom)"
"$NODE" "$ROOT/tools/tests/logtabs_render.test.cjs" > "$WORK/logtabs.out" 2>&1
case $? in
	0)  ok "logtabs_render.test.cjs"; sed 's/^/       /' "$WORK/logtabs.out" | tail -3 ;;
	*)  if grep -q '^SKIP' "$WORK/logtabs.out"; then
			skip "jsdom unavailable (npm install jsdom)"
		else
			bad "logtabs_render.test.cjs"; sed 's/^/       /' "$WORK/logtabs.out" | tail -30
		fi
		;;
esac

# ------------------------------------------- CI 环境本身能否真跑这两个 DOM 测试
# 三个 jsdom 测试都有「装不上就 SKIP、退出码 0」的自我保护，这本来是防止 npm
# 抽风把 Lint 变红；但也意味着 **CI 上可能一次都没跑过而面板全绿**。jsdom >= 27
# 依赖 undici 7，undici 7 用到 node 22.15+ 才有的 zlib zstd 接口 —— Node 20 上
# require('jsdom') 直接抛 "Cannot read properties of undefined (reading 'bind')"，
# 于是 DOM 测试静默跳过（0.1.24 那个 `shift` 掉出作用域的 bug 正是靠它们才
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

# 审计行两处都要写：syslog（logread / 系统级排查）+ ruleset_download.log
# （日志页读的就是它）。0.2.2 把原来裸的 `logger -t homeproxy ruleset_sync`
# 换成了 rulesetLog()，所以这里判据也跟着改为「rulesetLog 的实现里同时有
# logger 与 ruleset_download.log」——只判其中一处会让另一种退化溜过去。
if sed -n '/function rulesetLog/,/^}/p' "$RPCD" | grep -q 'logger -t homeproxy' \
   && sed -n '/function rulesetLog/,/^}/p' "$RPCD" | grep -q 'ruleset_download.log'; then
	ok "rpcd ruleset audit line reaches both syslog and ruleset_download.log"
else
	bad "rpcd ruleset audit line is half-blind (needs logread AND ruleset_download.log)"
fi

# 0.2.2 现场：用户手工在 /etc/config/homeproxy 里加了 3 条规则集，点「保存
# 并应用」后插件日志一行规则集都没有、核心仍「未在进行」。原因有两层：
#   ① 审计行只进 syslog（logger），日志页读的 ruleset_download.log 里没有，
#      于是「rpcd 没被调用」与「脚本没起来」在界面上完全一样；
#   ② LuCI 的 apply 只看它自己页面里的表单：手工改配置文件时页面与磁盘一致
#      → rpcd 回 204 → 不派发 uci-applied、不触发 luci-reload，服务根本不重载。
# 现在的口径（用户定稿）：不管配置有没有变更，「保存并应用」都必须
# 重载服务 + 重新检查内核/面板/规则集。
if grep -q 'function rulesetLog' "$RPCD" \
   && grep -q 'ruleset_download.log.*rulesetLog\|rulesetLog(' "$RPCD" \
   && sed -n '/function rulesetLog/,/^}/p' "$RPCD" | grep -q 'ruleset_download.log'; then
	ok "rpcd ruleset audit line lands in ruleset_download.log (log page sees it)"
else
	bad "the ruleset audit line only goes to syslog: the log page stays empty"
fi

# 「保存并应用」必须无条件「提交配置 + 规则集同步 + reload 服务」，而且
# **每个能点保存并应用的页面都要有**。0.2.2 现场：这三步只写在 client.js，
# node.js / server.js 完全没有钩子 —— 用户在节点页/服务端页点保存并应用，
# 照样什么都不发生。现在统一由 hp.afterSaveApply()（homeproxy.js）提供。
HPJS="$PKG/htdocs/luci-static/resources/homeproxy.js"
AFTER_SAVE="$(sed -n '/\tafterSaveApply(ctx/,/^\t},/p' "$HPJS")"
if sed -n '/\tafterSaveApply(ctx/,/^\t},/p' "$HPJS" | grep -q "callRcInit('homeproxy', 'reload')" \
   && sed -n '/\tafterSaveApply(ctx/,/^\t},/p' "$HPJS" | grep -q 'ruleset_sync'; then
	ok "hp.afterSaveApply does both steps: ruleset sync + unconditional reload"
else
	bad "hp.afterSaveApply misses one of the two steps (sync / reload)"
fi

# 三个可保存的页面都必须挂上这个钩子，少一个就有一页「点了没反应」。
missing_views=""
for v in client node server; do
	# 各 view 的 `return view.extend({` 都在行首、无缩进；从这里截到文件尾再找钩子。
	sed -n '/^return view.extend({/,$p' "$PKG/htdocs/luci-static/resources/view/homeproxy/$v.js" \
		| grep -q 'hp\.afterSaveApply' || missing_views="$missing_views $v.js"
done
if [ -z "$missing_views" ]; then
	ok "client / node / server all route save&apply through hp.afterSaveApply"
else
	bad "these views have no save&apply hook:$missing_views (clicking it does nothing)"
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

if printf '%s' "$AFTER_SAVE" | grep -q 'catch((e)'; then
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

if grep -q 'hp.afterSaveApply(this, view.prototype' "$CJS"; then
	ok "view hook delegates to hp.afterSaveApply (stock save+apply still runs)"
else
	bad "view hook would skip save+apply (base implementation not called)"
fi

# apply 成功、页面 reload 之前 LuCI 会派发 uci-applied；这是唯一能保证
# 「commit 已完成」的时机。轮询 uci.changes() 会与页面 reload 赛跑。
# 公共方法里必须先拿到配置提交的结果，再往下同步规则集与 reload：
# 顺序反了就会读着旧配置去下载。
if printf '%s' "$AFTER_SAVE" | grep -q 'const saved = base' \
   && printf '%s' "$AFTER_SAVE" | grep -q 'Promise.resolve(saved)'; then
	ok "ruleset sync waits for the config commit before it runs"
else
	bad "ruleset sync does not wait for apply to finish (reads stale config)"
fi

# 0.1.24 现场：uci-applied **不是每次保存并应用都派发**。ui.js 的 apply()
# POST admin/uci/apply_rollback，rpcd 侧「没有任何待提交变更」时回 204，
# LuCI 走 "There are no changes to apply" 分支 —— 不派发事件、不触发
# luci-reload、页面也不刷新。于是「SSH 里删了规则集文件、界面什么都没改、
# 想靠保存并应用补回来」这个最常见场景两条腿全不动，与 0.1.23 的死代码
# 表现完全一致。必须有定时兜底。
# 0.2.2 定稿：**完全不依赖 uci-applied**。LuCI 在「无待提交变更」时压根不派发
# 它（手工改配置文件后最常见），现在点保存并应用就直接做完同步 + reload。
if printf '%s' "$AFTER_SAVE" | grep -q 'ruleset_sync' \
   && ! printf '%s' "$AFTER_SAVE" | grep -q "addEventListener('uci-applied'"; then
	ok "save&apply no longer waits for uci-applied (fires unconditionally)"
else
	bad "ruleset sync depends on uci-applied alone: LuCI skips it on a no-change apply (HTTP 204)"
fi

# 75 = 脚本让路（另一个下载在跑）。把它当失败弹红色警告是假警报。
if printf '%s' "$AFTER_SAVE" | grep -q 'ret.rc === 75'; then
	ok "ruleset sync treats \"already running\" (rc=75) as success"
else
	bad "ruleset sync reports rc=75 (another download in progress) as a failure"
fi

# 包安装后的菜单刷新：LuCI 的菜单树缓存在 /tmp/luci-modulecache（**目录**）里，
# 只 `rm -f /tmp/luci-indexcache*` 删不掉它；uhttpd 不重启也不会重扫 menu.d。
# 少任一步，apk/opkg 装完侧栏里就没有本插件（deploy/install.sh 走的是
# rm -rf + uhttpd restart，所以这条路径长期没人踩到）。
# 判据只用**非注释行**：说明文字里也会出现这两个词，按行号比顺序会被注释带偏。
POSTINST="$(sed -n '/^define Package\/luci-app-homeproxy\/postinst$/,/^endef$/p' "$PKG/Makefile")"
POST_CMDS="$(printf '%s\n' "$POSTINST" | sed 's/^[[:space:]]*//' | grep -v '^#')"
POST_RM_LINE="$(printf '%s\n' "$POST_CMDS" | grep -n 'rm -rf /tmp/luci-indexcache' | head -1 | cut -d: -f1)"
POST_UH_LINE="$(printf '%s\n' "$POST_CMDS" | grep -n 'init.d/uhttpd restart' | head -1 | cut -d: -f1)"

if printf '%s\n' "$POST_CMDS" | grep -q 'rm -rf /tmp/luci-indexcache.*luci-modulecache' \
   && [ -n "$POST_UH_LINE" ]; then
	ok "postinst drops /tmp/luci-modulecache and restarts uhttpd"
else
	bad "postinst leaves LuCI's menu cache stale: no HomeProxy entry after apk/opkg install"
fi

if [ -n "$POST_RM_LINE" ] && [ -n "$POST_UH_LINE" ] && [ "$POST_RM_LINE" -lt "$POST_UH_LINE" ]; then
	ok "postinst clears the cache before restarting uhttpd (rescan on start)"
else
	bad "postinst restarts uhttpd before dropping the cache (the old menu tree is re-read)"
fi


# init.d 侧自登记：postinst 被跳过或 ucitrack 被清空时，服务启动一次就能补回。
# 判据不用「前 N 行」——那几个行数是随着注释增减而漂的（改一次顺序就假红），
# 而是取 start_service() 里**第一个 return 之前**的全部内容。
INIT="$PKG/root/etc/init.d/homeproxy"
SS_HEAD="$(sed -n '/^start_service()/,/^}/p' "$INIT" | awk '/^[[:space:]]*return/{exit} {print}')"
if grep -q 'hp_ucitrack_register' "$INIT" \
   && printf '%s\n' "$SS_HEAD" | grep -q 'hp_ucitrack_register'; then
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

# ── 时区继承（0.1.25 现场：修 Go 时区时引入的副作用）────────────────────────
# 内核为了让 Go 拿到正确时区，给自己设了 `TZ=:/var/run/homeproxy/core.zone`
# —— 那是 Go 认得的「冒号 + TZif 文件路径」。被内核 exec 出来的子进程会**继承**
# 它，而 ucode 是 C 程序跑在 musl 上，musl 只认 POSIX 串（CST-8）和 IANA 名，
# **不支持任意路径的 TZif**，解析失败会静默回退 UTC。于是面板触发的 [SUBSCRIBE]
# 日志比 [DAEMON] 整整早 8 小时（现场：19:51:52 的 [DAEMON] 后面跟着 11:51:52
# 的 [SUBSCRIBE]；手动在 shell 里跑则是对的，因为那种环境没有 TZ，musl 会读
# /etc/TZ）。「只有面板触发的日志时间错」就是这条继承链的标志。
# 凡是被内核 exec / 被 cron 拉起、且会用 date 或 ucode 写日志的脚本，都必须在
# 用它们之前把 TZ 改回系统时区（优先 /etc/TZ 的 POSIX 串）。
CROND="$PKG/root/etc/homeproxy/scripts/update_crond.sh"
for f in "$PROV" "$CROND" "$RES"; do
	if grep -q 'hp_tz' "$f" && grep -q 'export TZ' "$f" && grep -q '/etc/TZ' "$f"; then
		ok "$(basename "$f") resets the inherited TZ before logging (Go's TZif path is invalid for musl)"
	else
		bad "$(basename "$f") inherits the core's TZ=:<core.zone>; ucode/C logs fall back to UTC (8h behind)"
	fi
done

# 「取不到最新版本号」必须说清原因，不能只有一句 please retry later。四种成因
# （GitHub 未认证限流 / 网络不通 / 仓库不存在 / 返回体结构变了）的处置完全不同，
# 现场连跑四次就撞上限流（60 次/小时/IP），日志却只说「请稍后重试」，只能手工
# curl 才知道真相。日志里必须能看到 API 的 message 与响应片段。
if grep -q 'rate limit' "$RES" && grep -q 'jsonfilter -e "@.message"' "$RES"; then
	ok "update_resources.sh explains why it could not read the latest version"
else
	bad "update_resources.sh still logs a bare 'Failed to get the latest version' (rate limit vs network is indistinguishable)"
fi

# ── 日志框里只放日志（0.1.26：删掉顶部那条「最早/最新/设备当前时间」note）──────
# 0.1.24~0.1.25 在日志框最前面插了一条说明：「日志文件是追加写入的、只按大小轮转…
# 最早 X，最新 Y（设备当前时间 Z）· 点清空日志可清除历史记录」。用户明确要求删掉：
# 日志框是看日志的地方，不是读说明书的地方。而且那句「设备当前时间」在现场比日志行
# 快 8 小时（rpcd 的 system.info.localtime 语义不一致），留着反而误导读者以为日志
# 或设备时钟坏了。只保留 UTC→本地 的换算说明——那是读懂内核行必需的。
# 删 note 后后端 device_time 没有调用者，一并删掉：别留下没人用的死代码（本项目在
# handleSaveApply 上已经踩过一次，那次死了四个版本）。
# 匹配 msgid 原文（而不是日志框里任何一段文字）：正文注释里也会提到这条 note，
# 用宽泛的模式只会把注释本身判成失败。
if grep -q "Log lines stay in write order\|oldest %s, newest" "$LOGJS" \
   || grep -q "Log lines stay in write order\|oldest %s, newest" "$LOGVIEW"; then
	bad "log.js still prints the oldest/newest/device-time note above the log lines"
else
	ok "the log box holds log lines only (no oldest/newest/device-time note)"
fi

# 0.1.28：用户要求删掉「内核日志时间戳原为 UTC（本机没有时区数据），已按本地
# 时区（+08:00）换算显示。」这条说明行。**换算照做**（core_tz + shiftTs 仍在，
# 由上面那条断言守住），但不许再把任何说明插进日志框：note 记录、note 分支、
# .hp-log-note 样式、msgid 原文四样都不该留下——留下任何一样，这段话就会在
# 某个分支里重新冒出来。
if ! grep -q 'hp-log-note' "$LOGVIEW" && ! grep -q 'note: true' "$LOGVIEW" \
   && ! grep -q 'rec\.note' "$LOGVIEW" \
   && ! grep -q 'Kernel log timestamps were in UTC' "$LOGVIEW" \
   && ! grep -q 'Kernel log timestamps were in UTC' "$PKG/po/zh_Hans/homeproxy.po"; then
	ok "the UTC→local note is gone (conversion still happens, silently)"
else
	bad "the core log still prepends the UTC→local explanation"
fi

if grep -q 'device_time' "$RPCD" || grep -q 'device_time' "$LOGVIEW" || grep -q 'device_time' "$LOGJS"; then
	bad "device_time survives without a caller; delete it instead of leaving dead code"
else
	ok "the device_time rpcd method is gone with its only consumer (no dead code)"
fi

# ── 日志页：不再有任何「显示过滤器」（0.1.28 末版） ─────────────────────────
# 旧版有一个「日志级别」下拉（装 sing-box 四级），后来改成「显示：」（全部/
# 事件/警告/错误）。0.1.28 末版两个都删了：插件日志与内核日志一样「原样看
# 全部」，唯一剩下的下拉是内核日志屏那个「内核日志级别：」（它改的是内核
# 写多少，不是这里显示多少）。filterByView / normalizeView / isEventRecord
# 随下拉一起从源码删掉。
if ! grep -qE 'filterByView|normalizeView|isEventRecord|EVENT_LINE_RE|VIEW_KEYS' "$LOGJS" \
   && ! grep -qE 'filterByView|normalizeView|isEventRecord|EVENT_LINE_RE|VIEW_KEYS' "$LOGVIEW" \
   && ! grep -q "log_view" "$LOGJS"; then
	ok "no display filter is left anywhere (both log panels show everything)"
else
	bad "a display filter survived the 0.1.28 末版 cleanup"
fi

# 内核级别的显示名必须是纯中文，界面上不出现 debug/info/warn/error 这些英文。
# 只靠 _() 不够：homeproxy 的 .lmo 没加载时 _() 原样返回英文 msgid，界面就又
# 变回 Debug / Info / Warn / Error —— 所以四个都走 zh(en, _('X'), '中文')
# 兜底，en 与 msgid 逐字一致。括号形式的「调试（debug）」也被否掉（用户要求
# 只看中文，配置里存的原值对操作者没有意义）。
lv_cn=0
for pair in "Debug:调试" "Info:信息" "Warn:警告" "Error:错误"; do
	en="${pair%%:*}"; cn="${pair##*:}"
	if grep -qE "zh\('$en',[[:space:]]*_\('$en'\),[[:space:]]*'$cn'\)" "$LOGJS"; then
		lv_cn=$((lv_cn + 1))
	fi
done
if [ "$lv_cn" = 4 ] && ! grep -qE '（debug）|（info）|（warn）|（error）' "$LOGJS"; then
	ok "core level labels are plain Chinese, no English original appended"
else
	bad "core level labels can fall back to English (Debug / Info / Warn / Error)"
fi

# 顶栏所有控件一律左对齐：「清空日志 / 复制日志」紧跟在「自动刷新」后面，
# 不许用 auto 外边距或右浮动把按钮推到右边（用户明确要求往左靠）。
if ! grep -qE 'margin-left:[[:space:]]*auto|float:[[:space:]]*right' "$LOGVIEW" \
   && awk '/^\.hp-log-topbar \{/,/^\}/' "$LOGVIEW" | grep -q 'justify-content: flex-start'; then
	ok "every control in the log top bar stays left-aligned"
else
	bad "a log top-bar control is pushed to the right (should follow 'auto refresh')"
fi

if ! grep -q "_('Show:')" "$LOGJS" && grep -q "_('Core log level:')" "$LOGJS"; then
	ok "core verbosity is the only dropdown left; 显示 is gone"
else
	bad "the removed 显示 filter is still referenced (or the level dropdown vanished)"
fi

# 插件日志没有级别 token，只认 token 会让插件告警永远染不上色（0.1.28 末版起
# 这套判定只用于上色与 [级别] 标记）。
if grep -q '错误\[:：\]|失败(?!' "$LOGVIEW"; then
	ok "warnings/errors also match the Chinese severity words the scripts actually write"
else
	bad "severity matching ignores the plugin's own 错误/失败 wording"
fi

# 「…已缓存 0，失败 0」是统计不是错误：不加负向前瞻会把每次成功的预下载都
# 标成错误，「错误」视图反而被成功记录淹没。
if grep -q '失败(?!\\s\*\\d)' "$LOGVIEW"; then
	ok "the \"failed 0\" counter in a summary banner is not treated as an error"
else
	bad "a plain 失败 match would mark every successful run as an error"
fi

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

# ── ACL 里声明了 "exec" 的脚本，必须真的可执行 ──────────────────────────────
# 0.2.4–0.2.6 的「更新 N 个订阅」按钮是 fs.exec_direct('/etc/homeproxy/scripts/
# update_subscriptions.uc', [...]) —— 直接把脚本当可执行文件交给 rpcd。而
# rpcd 的 file.exec 是 fork + execv：文件没有可执行位时 execv 失败 EACCES，
# 但 **ubus 调用本身仍然成功**（返回 code 127 + stderr），前端拿到的是
# resolve 而不是 reject，于是只走 location.reload()，屏幕上一个字都不报。
# 现场表现就是「点了按钮，转一会儿，页面刷新，节点其实没更新」。
# 0.2.7 起按钮改走 rpcd 的 subscription_update（后台脱管，不再 exec 这个
# 文件），但执行位仍然要保留：update_subscriptions_async.sh 在环境里没有
# ucode 时会退化成直接执行它。两道保险都不许丢。
# git 索引里记的 mode 就是打包后的 mode（luci.mk 用 cp -p 保留）。
ACL_JSON="$PKG/root/usr/share/rpcd/acl.d/luci-app-homeproxy.json"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	SUB_MODE=$(git -C "$ROOT" ls-files -s luci-app-homeproxy/root/etc/homeproxy/scripts/update_subscriptions.uc 2>/dev/null | cut -d' ' -f1)
	if grep -q 'update_subscriptions\.uc": \[ "exec" \]' "$ACL_JSON" 2>/dev/null \
	   && [ "$SUB_MODE" = "100755" ]; then
		ok "the subscription updater carries the exec bit that its ACL entry promises"
	else
		bad "the ACL grants exec on update_subscriptions.uc but git records mode ${SUB_MODE:-unknown}: rpcd's execv hits EACCES, the ubus call still succeeds, and the button silently does nothing"
	fi
fi

if grep -q '订阅更新开始：来源' "$SUB_UC" && grep -q '订阅更新完成' "$SUB_UC"; then
	ok "update_subscriptions.uc logs a readable start/finish banner"
else
	bad "update_subscriptions.uc logs neither a start nor a finish banner"
fi

# 每个订阅必须留下「按协议的解析明细」（Node types from <url>: vless=N ...）。
# 0.2.03 现场：「某个协议整批拉不到」时，日志只有「拿到 M 行、解析出 N 个」，
# 谁都看不出是没解析出来还是被过滤了，最后只能一轮一轮装机数 uci 反推。
if grep -q "Node types from %s" "$SUB_UC" && grep -q 'type_tally' "$SUB_UC"; then
	ok "update_subscriptions.uc logs a per-protocol parse breakdown for every subscription"
else
	bad "no per-protocol parse breakdown: a whole protocol can vanish without a trace"
fi

# 抓不到正文时必须留下「为什么」（exit code / 字节数 / stderr 首段）。
# 0.2.03 现场：五个订阅在 25 秒内全部失败，日志里只有五行
# `Failed to fetch resources from <url>.`，DNS 失败、TLS 失败、服务器 4xx
# 被 curl -f 吞掉正文、环境里没有下载器（127）四种情况长得一模一样，
# 只能让用户在设备上手动重敲 curl 才能反推 —— 排查纪律 §8：诊断内建。
if grep -q 'exit=%d, bytes=%d, stderr=%s' "$SUB_UC" \
   && grep -q 'response\.exitcode' "$SUB_UC" \
   && grep -q 'size: output\.size' "$PKG/root/etc/homeproxy/scripts/homeproxy.uc"; then
	ok "a failed fetch records exit code, byte count and stderr"
else
	bad "a failed fetch is still a bare 'Failed to fetch': DNS/TLS/4xx/127 are indistinguishable"
fi

# 「通过代理更新订阅」必须真的生效，且顺序是**直连优先、失败才走代理**。
# 0.2.4 之前它是**死开关**：界面上有这一项，但脚本只把 via_proxy 拼进日志
# 文案（`手动（经代理）`），全项目没有一处为它设 http_proxy 或传 -x，勾上和
# 不勾完全一样。而用户现场正是「5 个订阅里 4 个要海外网络」，这条需求一直没
# 被满足。开发中先做过「先代理、失败回退直连」，0.2.4 首发前把顺序反过来：
# 节点全坏时「先代理」等于每条订阅都先撞一次坏节点，而节点坏掉恰恰是最需要
# 重新拉订阅的时候（homeproxy_output_redir 会劫持路由器自身出站）——死锁。
# 要求：① via_proxy=1 时走本地 mixed 入口（infra.mixed_port，现场 5330；
#          mixed-in 在 generate_client.uc 里是无条件创建的，无认证）；
#       ② **直连这一跳先发**，它的调用不带 proxy 参数；拿不到正文才用代理
#           重试（海外机场直连不通就是走这条路）；
#       ③ 两跳都失败时，失败原因要能分别看见，不能只剩一行 `Failed to fetch`；
#       ④ 开关关闭（proxy_url 为 null）时抓取路径与旧版逐字相同（默认路径
#          不许有任何变化，否则连 vless 的验证都会被污染）。
HP_LIB="$PKG/root/etc/homeproxy/scripts/homeproxy.uc"
DIRECT_LINE=$(grep -n 'const direct = fetch_with_dns_retry(url, ua);' "$SUB_UC" | cut -d: -f1)
PROXY_LINE=$(grep -n 'const proxied = fetch_with_dns_retry(url, ua, proxy_url);' "$SUB_UC" | cut -d: -f1)
if grep -q 'function httpFetch(url, ua, timeout, proxy)' "$HP_LIB" \
   && grep -q -e "--proxy', proxy" "$HP_LIB" \
   && grep -q "proxy_url = (via_proxy === '1')" "$SUB_UC" \
   && grep -q "uci.get(uciconfig, 'infra', 'mixed_port')" "$SUB_UC" \
   && [ -n "$DIRECT_LINE" ] && [ -n "$PROXY_LINE" ] && [ "$DIRECT_LINE" -lt "$PROXY_LINE" ]; then
	ok "update_via_proxy is wired to the local mixed inbound, direct hop first"
else
	bad "update_via_proxy is still a dead switch, or the proxy hop goes before the direct one"
fi

if grep -q 'Direct fetch failed for %s (%s).' "$SUB_UC" \
   && grep -q 'Retrying %s via %s.' "$SUB_UC" \
   && grep -q 'Proxy fetch failed for %s (%s).' "$SUB_UC" \
   && grep -q 'response.via_proxy === true ? proxy_url : null' "$SUB_UC" \
   && grep -q 'Fetch mode: %s.' "$SUB_UC"; then
	ok "a failed direct fetch falls back to the proxy, and both hops are logged"
else
	bad "no proxy fallback when the direct hop fails: the 4 overseas airports can never be updated"
fi

# exit=6（域名解析失败）要重试一次。现场：点完「保存并应用」立刻更新，正好
# 撞上 stop→start 重启 dnsmasq、缓存清空，两条订阅报 Could not resolve host，
# 两分钟后的下一轮同样的域名全部正常 —— 说明失败是那一两秒的时序，不是订阅。
# 要求：① 只在 exitcode === 6 且正文为空时才重试（其它失败照旧走代理回退）；
#       ② 等 1 秒用 busybox 的 sleep（不是 ucode 的 sleep()，单位没有明确写死）；
#       ③ 重试成功/失败都要留一行，否则日志里会看到「失败→成功」但没有重试痕迹。
if grep -q 'function fetch_with_dns_retry' "$SUB_UC" \
   && grep -q 'response?.exitcode !== 6' "$SUB_UC" \
   && grep -q "system('sleep 1')" "$SUB_UC" \
   && grep -q 'Retry after DNS failure succeeded for %s.' "$SUB_UC" \
   && grep -q 'DNS lookup failed for %s (%s), retrying once in 1s.' "$SUB_UC"; then
	ok "a DNS hiccup (curl exit 6) is retried once instead of failing the airport"
else
	bad "a transient DNS failure still fails the whole airport, and the log gives no hint that it was transient"
fi

# 一条订阅都没成功时不许重启内核，也不许说 Successfully。
# 旧行为：`need_restart` 恒为 true，机场全挂 / 家里断网时照样 stop+start 一次
# —— 用户看到代理无缘无故断流几秒，节点还一个没变；日志末尾仍然写
# `Successfully updated subscriptions.`，把「一条都没拉到」伪装成成功。
FAIL_LINE=$(grep -n 'if (succeeded === 0)' "$SUB_UC" | cut -d: -f1)
RESTART_LINE=$(grep -n "init_action('homeproxy', 'stop')" "$SUB_UC" | cut -d: -f1)
if [ -n "$FAIL_LINE" ] && [ -n "$RESTART_LINE" ] && [ "$FAIL_LINE" -lt "$RESTART_LINE" ] \
   && grep -q 'All %d subscriptions failed, keeping the running configuration' "$SUB_UC" \
   && grep -q 'Updated %s of %s subscriptions, %s failed' "$SUB_UC" \
   && grep -q 'succeeded++' "$SUB_UC"; then
	ok "a run where every subscription failed leaves the core alone and says so"
else
	bad "an all-failed run still restarts the core and still claims success"
fi


# 读 /proc/net/tcp(6) 的 LISTEN 项（不起子进程、不发包），跳过时留一行原因。
# ⚠️ 同时挡住另一种退化：`--max-time` 必须是整条请求的上限，不是 300 秒。
if grep -q 'function local_proxy_listening' "$SUB_UC" \
   && grep -q 'proxy retry skipped' "$SUB_UC" \
   && grep -q '/proc/net/tcp6' "$SUB_UC" \
   && grep -q 'fields\[3\] !== .0A.' "$SUB_UC"; then
	ok "a dead local proxy port is detected and the blind retry is skipped"
else
	bad "the proxy retry is fired at a port nobody listens on: 'kernel is off' is logged as 'proxy is broken'"
fi

if grep -q 'httpFetch(url, ua, 60, proxy)' "$HP_LIB"; then
	ok "one stalled subscription can no longer hold the whole update for five minutes"
else
	bad "the per-request max-time is not 60: a stalled airport can block the update for minutes"
fi

# 「更新 N 个订阅」必须后台执行。脚本要依次抓 N 个订阅、成功后 stop+start
# 一次内核：现场 5 条约 21 秒（抓取 13 + 重启 8），已经贴着 rpcd/ubus 约 30 秒
# 的上限。同步等待的后果是「转很久 → 报一句英文错误 → 页面刷新，而脚本还在
# 后台跑」。要求：① 有脱管包装脚本且带执行位；② 它用 `ucode <脚本>` 起
# update_subscriptions.uc 并传 --source；③ 按钮改走 rpcd 的两个方法 +
# hp.pollAdd 轮询；④ 不再有同步的 exec_direct 调用。
ASYNC_SH="$PKG/root/etc/homeproxy/scripts/update_subscriptions_async.sh"
NODE_JS="$PKG/htdocs/luci-static/resources/view/homeproxy/node.js"
if [ -f "$ASYNC_SH" ] && [ -x "$ASYNC_SH" ] \
   && grep -q 'LuCI「更新全部订阅」按钮' "$ASYNC_SH" \
   && grep -q 'ucode "\$UPDATER_UC"' "$ASYNC_SH" \
   && grep -q 'subscription_update.pid' "$ASYNC_SH"; then
	ok "the subscription updater is launched detached and records pid/rc"
else
	bad "update_subscriptions.uc is still run inline: rpcd's ~30 s ceiling turns a slow airport into a bogus error"
fi

if grep -q "method: 'subscription_update'" "$NODE_JS" \
   && grep -q "method: 'subscription_update_progress'" "$NODE_JS" \
   && grep -q "hp.pollAdd('subscription-update'" "$NODE_JS" \
   && ! grep -q "exec_direct('/etc/homeproxy/scripts/update_subscriptions.uc'" "$NODE_JS"; then
	ok "the update button starts the job and polls its progress instead of blocking"
else
	bad "the update button still blocks on fs.exec_direct, or no longer polls the background job"
fi

if grep -q 'subscription_update:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'subscription_update_progress:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"; then
	ok "rpcd exposes subscription_update / subscription_update_progress"
else
	bad "the backend has no subscription_update method: the button's rpc.declare would 404"
fi

# 改订阅地址必须迁移机场哈希。URL 是分组身份的来源（md5(URL) 写进节点段的
# grouphash 和每个分组的 subscription_groups），只换地址不换这两处，节点会
# 照常导入、照常出现在「订阅 (X)」页签里，却永远不进任何 outbound 组 ——
# 现场表现是 Clash 面板上那个机场显示 0/0「HTTP」，有流量数据、有节点列表，
# 但一个节点都用不上，且没有任何报错。0.2.7 现场：给 NB 加 ?flag=singbox
# 后正是这个状态（内核的 provider 里 18 个 tag 全部 resolved=0）。
if grep -q 'function migrateSubscriptionHash' "$NODE_JS" \
   && grep -q 'migrateSubscriptionHash(section_id, value)' "$NODE_JS" \
   && grep -q "uci.sections('homeproxy', 'node'" "$NODE_JS" \
   && grep -q "uci.sections('homeproxy', 'routing_node'" "$NODE_JS" \
   && grep -q 'hp.calcStringMD5(cleanUrl(oldUrl))' "$NODE_JS" \
   && grep -q "'subinfo_' + substr(from, 0, 16)" "$NODE_JS"; then
	ok "editing a subscription URL rewrites the old group hash on nodes and groups"
else
	bad "a changed subscription URL leaves nodes orphaned: the dashboard shows the airport as 0/0 with no error"
fi

# ── UDP 编码（packet_encoding）：节点自己的声明优先于全局默认值 ──────────────
# 0.2.2 现场：vless 节点「拉下来了却用不了」（UDP Blocked）。查下来是解析层
# 的 vless URI 分支**根本没读 packetEncoding**，一律被全局默认值覆盖成 xudp；
# 机场显式写 packetEncoding=none 的节点于是被改成 xudp —— xray 服务端对
# xudp / none 的 UDP 行为不同，TCP 能连、UDP 不通。
# 要求：① 有一套归一函数（表单只认 none / packetaddr / xudp 三档）；
#       ② 四个协议分支（vless URI / vmess JSON / mihomo vless / mihomo vmess）
#          都必须用它读节点自己的声明；
#       ③ 兜底必须区分「没声明」与「显式 none」—— 显式 none 归一后是空串，
#          用 isEmpty() 判会把它当成没声明再覆盖回 xudp（等于没修）。
if grep -q 'function normalize_packet_encoding' "$SUB_UC" \
   && [ "$(grep -c 'normalize_packet_encoding(params.packetEncoding\|normalize_packet_encoding(uri.packetEncoding\|normalize_packet_encoding(proxy\[' "$SUB_UC")" -ge 4 ]; then
	ok "every parser honours the node's own packetEncoding (vless/vmess × uri/mihomo)"
else
	bad "a parser drops packetEncoding: the node falls back to the global xudp (UDP breaks)"
fi

if grep -q "config.packet_encoding === null" "$SUB_UC" \
   && ! sed -n '/config.type in \[.vless., .vmess.\]/,/packet_encoding = packet_encoding/p' "$SUB_UC" | grep -q 'isEmpty(config.packet_encoding)'; then
	ok "the global packet_encoding default cannot overwrite an explicit none"
else
	bad "an explicit packetEncoding=none is overwritten by the global default (isEmpty('') is true)"
fi

INITD="$PKG/root/etc/init.d/homeproxy"
if grep -q '订阅自动更新已登记' "$INITD" && grep -q '未登记 cron' "$INITD"; then
	ok "init.d reports whether the subscription cron entry was registered"
else
	bad "init.d registers the subscription cron silently (an invalid time leaves no clue)"
fi

# ── 下载日志必须写明「谁触发的」（0.1.27） ──────────────────────────────────
# 现场（0.1.26 装机）：ruleset_download.log 只有「共 21 条，预算 600s」，来源
# 只能靠预算秒数反推（600=面板、240=服务启动、900=cron、90=页面按钮）——手动
# 执行撞同一个默认值，而且预算一改这条隐式契约就断，此后没有任何第二条线索。
# 现在由调用方显式传 --source，写进开始/结束横幅。
RS="$PKG/root/etc/homeproxy/scripts/fetch_rulesets.sh"
if grep -q -- '--source' "$RS" && grep -q 'SOURCE=' "$RS" \
   && grep -q '来源=「${SOURCE}」' "$RS"; then
	ok "fetch_rulesets.sh records who triggered the run in its banner (--source)"
else
	bad "fetch_rulesets.sh has no --source: the trigger is only inferable from the budget"
fi

if grep -q -- '--autostart' "$RS" && grep -q 'AUTOSTART' "$RS"; then
	ok "fetch_rulesets.sh can start the service after a pass (--autostart)"
else
	bad "no --autostart: a filled rule-set cache still leaves the plugin not running"
fi

# 判断服务在不在跑不能用 kill -0：某些 shell 对兄弟进程恒失败，会得出
# 「一直没跑完」的错判。
# 只看探测函数本身：脚本里另外用 `kill -0 <pid>` 判**陈旧锁的持有进程是否
# 存活**是标准做法（那是任意 pid，不是后台兄弟 job），不能一概禁止。
probe_body="$(sed -n '/^hp_service_running()/,/^}/p' "$RS")"
if printf '%s' "$probe_body" | grep -q 'ubus call service list' \
   && printf '%s' "$probe_body" | grep -q 'ps ' \
   && ! printf '%s' "$probe_body" | grep -q 'kill -0'; then
	ok "the auto-start probe asks ubus then ps, never kill -0"
else
	bad "the auto-start probe uses kill -0 (unreliable for a sibling job) or has no fallback"
fi

HPUC="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
if grep -q -- '--autostart' "$HPUC" && grep -q 'LuCI 保存并应用' "$HPUC"; then
	ok "rpcd names the trigger (LuCI save & apply) and asks for --autostart"
else
	bad "rpcd no longer tells the fetcher that LuCI save & apply triggered it"
fi

if grep -q '规则集页面「立即更新」' "$HPUC"; then
	ok "the per-rule-set update button names itself in the log"
else
	bad "ruleset_update does not pass --source"
fi

if grep -q -- '--source "服务启动预取' "$INIT"; then
	ok "init.d names the start-up pre-fetch as the trigger"
else
	bad "init.d sync_rulesets does not pass --source"
fi

if grep -q -- '--source "定时更新' "$PKG/root/etc/homeproxy/scripts/update_rulesets.sh"; then
	ok "the cron rule-set refresh names itself in the log"
else
	bad "update_rulesets.sh (cron) does not pass --source"
fi

FP="$PKG/root/etc/homeproxy/scripts/fetch_panel.sh"
if grep -q -- '--source' "$FP" && grep -q '来源=「$SOURCE」' "$FP"; then
	ok "fetch_panel.sh records the trigger in panel_download.log"
else
	bad "fetch_panel.sh has no --source"
fi

if [ "$(grep -c -- '--source' "$INIT")" -ge 2 ] && grep -q 'LuCI「更新面板」按钮' "$HPUC"; then
	ok "every panel download caller names itself"
else
	bad "some panel download caller still runs without --source"
fi

UC="$PKG/root/etc/homeproxy/scripts/update_core.sh"
if grep -q -- '--source' "$UC" && grep -q '来源=${source}' "$UC"; then
	ok "update_core.sh records the trigger in core_download.log"
else
	bad "update_core.sh has no --source"
fi

if grep -q 'LuCI「更新内核」按钮' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh"; then
	ok "the LuCI core-update button names itself in the log"
else
	bad "update_core_async.sh does not pass --source"
fi

# 「默认出站（漏网之鱼）」下拉里那个 nil 选项其实是整个插件的总开关：选它
# start_service 直接 return 1，插件完全不运行。旧文案 `Disable (the service)`
# 被读成「禁用漏网之鱼这条规则」，于是用户配好一堆规则却发现插件不起来。
CJS2="$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"
if grep -q "'nil', _('Stop the plugin')" "$CJS2" \
   && grep -q 'stops the service entirely' "$CJS2"; then
	ok "the default-outbound nil option says plainly that it stops the whole plugin"
else
	bad "the \"Disable\" default-outbound option still hides that it stops the service"
fi

# 订阅：批量按钮、单个机场按钮、定时任务，以前在日志里都只写「手动」。
SUB="$PKG/root/etc/homeproxy/scripts/update_subscriptions.uc"
if grep -q 'exists(ARGV)' "$SUB" && grep -q "argv\[i\] === '--source'" "$SUB" \
   && grep -q 'cli_source ||' "$SUB"; then
	ok "update_subscriptions.uc accepts --source from its caller (ARGV)"
else
	bad "update_subscriptions.uc ignores argv: the trigger cannot be told apart"
fi

# 0.2.7 起按钮不再自己 exec 脚本（改成 rpcd 起脱管进程），触发来源的字符串
# 随之搬进 update_subscriptions_async.sh —— 判据跟着实现走，否则会假红。
if grep -q 'LuCI「更新全部订阅」按钮' "$PKG/root/etc/homeproxy/scripts/update_subscriptions_async.sh"; then
	ok "the \"update N subscriptions\" button names itself in the log"
else
	bad "the batch subscription update button still logs as a bare 手动"
fi

if grep -q -- '--source "定时任务' "$PKG/root/etc/homeproxy/scripts/update_crond.sh" \
   && grep -q -- '--source "面板单个机场' "$PKG/root/etc/homeproxy/scripts/update_provider.sh"; then
	ok "cron and the per-airport button both name themselves"
else
	bad "subscription triggers are not all named in the log"
fi

# ── 订阅更新：成功才允许碰服务（0.2.2 用户定稿） ────────────────────────────
# 「更新成功应该会重载服务，更新不成功不应该影响当前服务」。旧版两处违反：
#   · 下载前就 stop（所谓绕过自身代理），失败再 start 回来——失败也断流一次；
#   · [FATAL ERROR] 兜底无条件 stop+start——更新崩了还把正在跑的代理重启一遍。
# 现在服务必须全程活着：main() 里只许成功路径末尾那一处 stop+start；下载前
# 的 stop 与失败路径里的 start/stop 全部不允许出现。
SUB_STOP_HITS=$(grep -c "init_action('homeproxy', 'stop')" "$SUB")
SUB_START_HITS=$(grep -c "init_action('homeproxy', 'start')" "$SUB")
if [ "$SUB_STOP_HITS" = 1 ] && [ "$SUB_START_HITS" = 1 ] \
   && ! grep -q "log('Stopping service...')" "$SUB" \
   && ! grep -q "log('Starting service...')" "$SUB" \
   && sed -n '/^\tif (need_restart)/,/^\t}/p' "$SUB" | grep -q "init_action"; then
	ok "subscription update touches the service only on success (stop+start once)"
else
	bad "a failed subscription update can stop or restart the running service ($SUB_STOP_HITS stop / $SUB_START_HITS start)"
fi

# ── 订阅更新：没有主节点时自动挑一个（0.2.5 现场实测） ───────────────────────
# 两种配置会走到这里：
#   ① 从备份恢复的旧配置：`config` 段里连 main_node 这个选项都不存在。
#   ② 全新安装：出厂模板里是显式的 `option main_node 'nil'`，客户端页那个
#      ListValue 的 default 也是 'nil'，用户一保存表单就会被写进去。
# 第 90 行 `|| 'nil'` 把两者都归一成 'nil'，而 isEmpty('nil') 为真 —— 整个
# if 块被跳过，日志里没有 'Main node is gone' 也没有 'No available node'，
# 直接就是 Restarting service。结果是节点全拉到了、内核也起来了，但 client
# 配置里没有代理出站，流量还是直连。
# 判据必须看 uci 原始值；显式 'nil' 只在「更新前一个节点都没有」时才接管
# —— 那时用户没节点可选，不可能是主动禁用。
SUB_AUTO_LINE=$(grep -n 'No main node was set, selecting' "$SUB" | head -1 | cut -d: -f1)
SUB_RAW_LINE=$(grep -n 'const declared_main_node' "$SUB" | head -1 | cut -d: -f1)
SUB_GUARD_LINE=$(grep -n 'if (!isEmpty(main_node))' "$SUB" | head -1 | cut -d: -f1)
SUB_BEFORE_LINE=$(grep -n 'let nodes_before = 0' "$SUB" | head -1 | cut -d: -f1)
if [ -n "$SUB_AUTO_LINE" ] && [ -n "$SUB_RAW_LINE" ] && [ -n "$SUB_GUARD_LINE" ] \
   && [ -n "$SUB_BEFORE_LINE" ] \
   && [ "$SUB_BEFORE_LINE" -lt "$SUB_AUTO_LINE" ] \
   && [ "$SUB_RAW_LINE" -lt "$SUB_AUTO_LINE" ] && [ "$SUB_AUTO_LINE" -lt "$SUB_GUARD_LINE" ] \
   && grep -q "declared_main_node === null || declared_main_node === ''" "$SUB" \
   && grep -q "declared_main_node === 'nil' && nodes_before === 0" "$SUB"; then
	ok "a config with no main_node gets one picked automatically (raw uci value, not the 'nil' fallback)"
else
	bad "main_node is still judged after being folded into 'nil': a fresh install can end up with nodes but no outbound"
fi

# 出厂模板写的是 'nil'，光靠「选项缺失」覆盖不了全新安装，必须单独覆盖。
if grep -q "nodes_before === 0" "$SUB"; then
	ok "a fresh install (template 'nil', zero nodes before) gets a main node on the first import"
else
	bad "the template's explicit 'nil' is never taken over: a fresh install keeps going out directly"
fi

# `uci.get_first(config, section, option)` 取的是「第一个段的某个 option 值」，
# 不是段名；原先只传两个参数，拿不到 node 段名。这段一直没被执行过，现在自动
# 选节点会走到它，所以必须确认已换成 foreach。
if grep -v -e '^[[:space:]]*\*' -e '/\*' "$SUB" | grep -q 'uci\.get_first('; then
	bad "still calling uci.get_first() with two arguments: it returns an option value, not a section name"
else
	ok "the first node section is taken via uci.foreach, not the misused uci.get_first()"
fi

# 规则集的定时更新以前只有 fetch_rulesets.sh 的几行输出，没有自己的首尾横幅，
# 「到底有没有按点跑」只能靠文件 mtime 猜。
RSCRON="$PKG/root/etc/homeproxy/scripts/update_rulesets.sh"
if grep -q '规则集定时更新开始' "$RSCRON" && grep -q '规则集定时更新结束' "$RSCRON" \
   && grep -q 'CRON_EXPR' "$RSCRON"; then
	ok "the cron rule-set refresh writes its own start/end banner with the cron expression"
else
	bad "no banner for the scheduled rule-set refresh: nothing shows it ever ran"
fi

if grep -q "update_rulesets.sh '\$update_time'" "$INIT"; then
	ok "the crontab entry passes the cron expression to the script"
else
	bad "the crontab entry does not pass the expression: the log cannot say which schedule fired"
fi

# 界面上曾并排放着「重载服务」和「重启服务」：本插件的 reload_service() 就是
# stop + start，rc.common 的 restart 也是 stop + start，两者等价（sing-box 不
# 支持热重载配置），留两个只是让人纠结该点哪个 —— 去掉 restart。
if grep -q "'Reload Service'" "$CJS2" \
   && ! grep -q "'Restart Service'" "$CJS2" \
   && ! grep -q "callRCInit('homeproxy', 'restart')" "$CJS2"; then
	ok "only one service action button remains (reload), no duplicate restart"
else
	bad "the panel still offers a restart button that does exactly what reload does"
fi

# ── 服务启停事件必须可追溯（0.1.27） ────────────────────────────────────────
# 以前主日志只有「sing-box x 已启动 / 服务已停止」，看不出是开机自启、LuCI
# 保存并应用、界面按钮、cron 还是脚本内部调用的 —— 而这些场景排查方向完全
# 不同（「保存并应用没重载」和「启动失败」表面一模一样）。
if grep -q 'hp_caller()' "$INIT" && grep -q 'hp_event()' "$INIT"; then
	ok "init.d can name the caller of a start/stop/reload"
else
	bad "no caller attribution: service start/stop lines cannot say who asked"
fi

if grep -q 'hp_event "服务启动"' "$INIT" && grep -q 'hp_event "服务停止"' "$INIT" \
   && grep -q 'hp_event "服务重载"' "$INIT"; then
	ok "start, stop and reload each write a [DAEMON] event line"
else
	bad "service lifecycle events are not all logged"
fi

# 启动被拒（没配节点/内核缺失/配置校验失败）也必须留下痕迹，否则
# 「启动被拒」和「根本没人启动」在主日志里长得一样。
if printf '%s\n' "$SS_HEAD" | grep -q 'hp_event "服务启动"'; then
	ok "the start event is written before any early return"
else
	bad "the start event comes after early returns: a refused start leaves no trace"
fi

# rc.common 在 source 本文件之前已经 shift 2，顶层 $1 是动作后面多带的参数
# （通常为空），动作本身在它的 $action 里。只读 $1 的现场表现：每条事件行都
# 写成「命令=未标注」，于是「开机自启」和「保存并应用」又变得一模一样。
if grep -q 'HP_ACTION="${action' "$INIT"; then
	ok "the action is read from rc.common's \$action, not the shifted \$1"
else
	bad "HP_ACTION reads \$1, which rc.common already shifted away: every event says 未标注"
fi

# 时钟必须在第一行日志之前校正。现场故障：开机后主日志第一条写成 6 天前的
# 17:15:04（RTC 停在上次关机），NTP 几秒后才把时间改对，日志里留下一道断崖。
ss_pos_wait=$(sed -n '/^start_service()/,/^}/p' "$INIT" | grep -n 'wait_for_time_sync' | head -1 | cut -d: -f1)
ss_pos_evt=$(sed -n '/^start_service()/,/^}/p' "$INIT" | grep -n 'hp_event "服务启动"' | head -1 | cut -d: -f1)
if [ -n "$ss_pos_wait" ] && [ -n "$ss_pos_evt" ] && [ "$ss_pos_wait" -lt "$ss_pos_evt" ]; then
	ok "the clock is corrected before the first startup line is stamped"
else
	bad "the startup line is written before the clock is corrected"
fi

# 只按年份判「离谱」抓不到「年份正常、差几天」的 RTC 时间，所以开机窗口内
# （uptime 小）必须无条件试一次校时。
if grep -q 'uptime_seconds()' "$INIT" && grep -q 'booted_ago" -lt 300' "$INIT" \
   && grep -q 'ntp_kick' "$INIT"; then
	ok "a fresh boot re-syncs even when the year looks plausible"
else
	bad "a plausible-looking but stale boot clock is never corrected"
fi

# 事件行必须带开机时长：时间戳不可信时，它是唯一能把日志换算回真实时刻的线索。
if grep -qF '开机 $((booted / 60))' "$INIT"; then
	ok "the event line names the uptime, so a wrong timestamp can be converted"
else
	bad "the event line cannot be placed in time when the clock is wrong"
fi

# ── 重载风暴防护 ────────────────────────────────────────────────────────────
# 现场（iStoreOS x86）：面板在「未运行 / 运行中」之间每 3~5 秒跳一次，主日志
# 连着几分钟不间断地「服务重载 → 停止 → 启动」。这些 reload 一次都不是用户点
# 的 —— 是 service_triggers() 注册的 procd 触发器在反复调用（config.change /
# WAN 口 up），而每次 reload 里的 fw4 reload 与 dnsmasq restart 又会把触发器
# 点着，自己踩自己。判定只能靠「这次重载有没有带来新配置」。
if sed -n '/^start_service()/,/^}/p' "$INIT" | grep -q 'last-start'; then
	ok "start stamps when it finished, so a later reload can tell it is redundant"
else
	bad "no start stamp: every trigger-driven reload looks legitimate"
fi

if sed -n '/^reload_service()/,/^}/p' "$INIT" | grep -q '跳过重复重载' \
   && grep -q 'stat -c %Y "/etc/config/$CONF"' "$INIT" \
   && grep -q '\.reload-skips' "$INIT"; then
	ok "reload skips a repeat that carries no config change (storm guard)"
else
	bad "reload storms are unguarded: stop/start can loop forever"
fi

# 0.2.1 现场（3500+ 次/分钟的事件风暴）：旧守卫带「距上次启动 ≤30 秒才跳过」
# 的时间窗，窗口一过就放行一次真重载，面板于是每 30~40 秒「未运行/运行中」
# 循环一次、永不收敛。无配置变更的触发器重载必须**不限时**地跳过——带新配置
# 的重载靠 mtime > last-start 判定，不靠时间，所以去掉窗口不会误伤保存并应用。
# 判据只看跳过条件那一小段（`if [ "$force" = "0" ] … then`）：里面不许再出现
# 30 秒窗或 now-last_start 比较。别用宽泛的 grep——重入保护的 300 秒陈旧判定
# 和日志文案里的「距上次启动 X 秒」都会误中。
SKIP_COND="$(sed -n '/^reload_service()/,/^}/p' "$INIT" | sed -n '/if \[ "\$force" = "0" \]/,/then/p')"
case "$SKIP_COND" in
	*"-le 30"*|*"now - last_start"*)
		bad "the storm guard has a time window: a long storm still leaks real reloads" ;;
	*)	ok "a no-change reload is skipped no matter how long ago the start was" ;;
esac

# 界面按钮 / SSH 手敲必须永远执行，否则用户点「重载服务」会被自己的防护吞掉。
if sed -n '/^reload_service()/,/^}/p' "$INIT" | grep -q 'force=1'; then
	ok "a user-requested reload is never suppressed by the storm guard"
else
	bad "the storm guard can swallow a manual reload"
fi

# 重入标记必须写时刻而不是空文件：空标记读不出数字，会被判成「刚重载过」，
# 把服务永久锁死在「点了重载也不动」。
if grep -q 'date +%s >"$RUN_DIR/.reloading"' "$INIT"; then
	ok "the reload marker carries a timestamp, so it cannot lock the service"
else
	bad "the reload marker is empty: a leftover file would skip every later reload"
fi

# procd 既负责开机拉起，也负责按触发器调 reload。以前两种都写「系统启动」，
# 一个每 4 秒重载一次的循环在日志里看起来就像「设备在反复重启」。
if sed -n '/^hp_caller()/,/^}/p' "$INIT" | grep -q 'uptime_seconds' \
   && grep -q 'procd 触发器' "$INIT"; then
	ok "a procd-triggered reload is named as such, not reported as a boot"
else
	bad "procd trigger reloads are still reported as 系统启动（procd/开机自启）"
fi

# 接口触发器带上区分参数，日志才说得出「是 WAN 口 up 还是配置变更」。
if grep -q 'reload wan-up' "$INIT"; then
	ok "the WAN trigger marks the reload, so the log names the trigger"
else
	bad "interface and config triggers are indistinguishable in the log"
fi

# NTP 在服务跑起来之后才同步上时，日志里会出现一道时间断崖；不解释一句就会被
# 当成「混进了旧日志」。
if grep -q '系统时钟在运行中被校正' "$INIT"; then
	ok "a runtime clock correction is called out instead of looking like stale rows"
else
	bad "a clock jump is silent: old-dated rows look like leftover log content"
fi

if grep -q '内核进程已退出' "$INIT"; then
	ok "a core exit (including a crash) is recorded in the main log"
else
	bad "nothing is written when the core process exits"
fi

if grep -q '已注册实例' "$INIT"; then
	ok "the start line says which instances registered (client / server / both)"
else
	bad "the start line does not say which core instances came up"
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
