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

# 自检脚本自己必须能被 dash 解析。CI 与 OpenWrt 上 /bin/sh 是 dash/ash，本地
# Git Bash 的 sh 是 bash —— bash 专属语法（进程替换 <(...)、[[ ]]、数组）在
# 本地一路绿灯，到 CI 却在校验到那一行时 `Syntax error: "(" unexpected`，
# 前面已经打印的 200 多条 OK 全部作废，还容易误以为是某条断言跑了没通过。
# dash 的解析在子进程里进行，自己解析失败不影响父进程继续跑，所以这条能报出来。
if [ "$SHN" = "dash" ]; then
	if dash -n "$0" 2>"$WORK/dashself"; then
		ok "tools/tests/run.sh parses under dash (what CI actually runs)"
	else
		bad "tools/tests/run.sh uses bash-only syntax and cannot run under dash: $(head -2 "$WORK/dashself" | tr '\n' ' ')"
	fi
else
	skip "dash is unavailable, so run.sh cannot verify itself against CI's shell"
fi

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
	# 工具栏里的脚本（run.sh 自己、以及临时排查用的 *.sh）同样会跑在
	# dash / busybox ash 下，必须一起过 -n；漏掉自己正是 0.2.12 那次
	# 「本地全绿、CI 解析期报 Syntax error」的直接原因。
	find "$ROOT/tools/tests" -type f -name '*.sh' 2>/dev/null
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

# ------------------------------------------- urltest probe URL default
# urltest 的探测地址决定「哪些节点算可用」。旧默认是
# https://www.gstatic.com/generate_204，而 www.gstatic.com 恰好在本项目的
# china_list（直连域名表）里，且实测有节点能通 google.com/generate_204 却
# 对 gstatic 失败/超时 —— 这些节点在面板上就一直显示「不通」，用户以为
# 节点坏了（0.2.9 现场）。默认改成 google 的 generate_204，并让生成器在
# 段里没有 urltest_url 时也显式写这一条，避免内核默认值与 UI 默认值分岔。
section "urltest probe URL default"

CLIENT_JS="$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"
GEN_UC="$PKG/root/etc/homeproxy/scripts/generate_client.uc"

if grep -q "so.default = 'https://www.google.com/generate_204'" "$CLIENT_JS" \
   && grep -q "so.placeholder = 'https://www.google.com/generate_204'" "$CLIENT_JS"; then
	ok "the Test URL field defaults to www.google.com/generate_204"
else
	bad "the Test URL field still defaults to gstatic: nodes that fail it look dead in the panel"
fi

if grep -q "length(cfg.urltest_url ?? '') ? cfg.urltest_url : 'https://www.google.com/generate_204'" "$GEN_UC"; then
	ok "generate_client falls back to the same URL when a group has no urltest_url"
else
	bad "a group without urltest_url silently inherits the core default, so the two defaults can drift apart"
fi

if grep -q 'https://www.gstatic.com/generate_204' "$CLIENT_JS" "$GEN_UC"; then
	bad "gstatic is back as the urltest URL (it is in china_list and misjudges nodes)"
else
	ok "no gstatic URL left in the urltest defaults"
fi

# 改默认值只对「新建的段」生效 —— 老配置升级后仍是 gstatic/180，等于修复
# 根本没送到用户手上。迁移脚本必须在安装/升级时把**仍然是旧默认值**的段搬过来，
# 而用户自己填过的地址/间隔一律不动（按值匹配，不按段名猜）。
MIG_UC="$PKG/root/etc/homeproxy/scripts/migrate_config.uc"
if grep -q "old_urltest_url = 'https://www.gstatic.com/generate_204'" "$MIG_UC" \
   && grep -q "cfg.urltest_interval === '180'" "$MIG_UC" \
   && grep -q "uci.get(uciconfig, ucimain, 'main_urltest_interval')\|main_urltest_interval', 'main_udp_urltest_interval'" "$MIG_UC"; then
	ok "upgrade migrates the old gstatic/180 defaults, and only those"
else
	bad "existing configs keep the gstatic URL and 180 s interval after upgrade"
fi

# 探测间隔 180 → 300 秒：面板一次测速就对 48 个节点做完整 TLS+HTTP，7 个分组
# 每 180 秒再各来一轮（92 个成员），两批叠在一起会互相挤占、把延迟抬上去。
# 三处 interval 都要是 300：主出站 TCP / 主出站 UDP / 每个路由分组。
if [ "$(grep -c "= '300'" "$CLIENT_JS")" -ge 3 ] \
   && ! grep -q "= '180'" "$CLIENT_JS"; then
	ok "every Test interval default is 300 s (main TCP, main UDP, per-group)"
else
	bad "a Test interval still defaults to 180 s: probe bursts will overlap the panel's own test"
fi

# ------------------------------------------------- pinSHA256 证书指纹
# 链接里的 `pinSHA256` 是**证书**指纹，机场用它正因为自己发的是旧式 CN 证书；
# Go 1.15+ 直接拒绝这种证书（x509: certificate relies on legacy Common Name
# field），而 sing-box 只有 `certificate_public_key_sha256`（**公钥**指纹），
# 两者数值不同、无法映射。不处理 → 这类节点在 homeproxy 上永远连不上
# （0.2.9 现场：[YU] 香港专线01/02 全部失败，mihomo 验指纹所以正常）。
section "hy2 pinSHA256 maps to insecure, with a log line"

SUB_UC="$PKG/root/etc/homeproxy/scripts/update_subscriptions.uc"
if grep -q 'function tls_insecure_param' "$SUB_UC" \
   && grep -q 'params?.pinSHA256' "$SUB_UC" \
   && [ "$(grep -c 'tls_insecure: tls_insecure_param(params),' "$SUB_UC")" -ge 6 ]; then
	ok "every URI branch routes tls_insecure through tls_insecure_param()"
else
	bad "a URI branch still reads params.insecure directly: pinSHA256 nodes stay unreachable"
fi

if grep -q 'carry pinSHA256' "$SUB_UC"; then
	ok "nodes that had to skip certificate verification are named in the log"
else
	bad "certificate verification is disabled silently: no way to audit the downgrade"
fi

# mihomo 的裸 `fingerprint` 是 uTLS 指纹，不能当证书引脚用。
if grep -q "proxy.fingerprint" "$SUB_UC" \
   && ! grep -q "!isEmpty(proxy.fingerprint)" "$SUB_UC"; then
	ok "mihomo fingerprint (uTLS) is not mistaken for a certificate pin"
else
	bad "mihomo fingerprint is treated as a certificate pin: normal nodes get marked insecure"
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
	0)  ok "po/zh_Hans/homeproxy.po consistent with JS sources"; sed 's/^/       /' "$WORK/po.out" | tail -9 ;;
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
   && grep -q 'providerHealthCheckTimeout     = 6 \* time\.Second' "$PATCH" \
   && grep -q 'providerHealthCheckBudget      = 12 \* time\.Second' "$PATCH"; then
	ok "provider health check is bounded (6s per node, 12s per batch)"
else
	bad "provider health check has no batch budget: one dead node can hold the whole reply"
fi

# 单节点 3 秒是 0.2.10 之前的取值，实测不够：hysteria2 的 QUIC + TLS 冷启动要
# 4 秒以上（SNY 巴西-03 一次 4.26 s），被砍掉的节点在面板上就是「没有延迟」，
# 用户看到的「整批 0 结果」有一半是它造成的。
if grep -q 'providerHealthCheckTimeout     = 3 \* time\.Second' "$PATCH"; then
	bad "provider health check still gives each node only 3s (slow hysteria2 nodes time out)"
else
	ok "provider health check gives each node more than 3s"
fi

# 探测地址必须跟 client.js 的 urltest_url 默认值一致，并且尊重 Clash 原生的
# ?url= 参数。补丁里曾硬编码 gstatic：用户把 urltest_url 改成 google 之后，
# 按钮测速仍然走 gstatic，两边口径对不上，看起来就像改动没生效。
if grep -q 'testURL := "https://www\.google\.com/generate_204"' "$PATCH" \
   && grep -q 'r\.URL\.Query()\.Get("url")' "$PATCH"; then
	ok "provider health check defaults to google's generate_204 and honours ?url="
else
	bad "provider health check ignores the configured probe URL"
fi

if grep -q 'www\.gstatic\.com/generate_204' "$PATCH"; then
	bad "provider health check still probes gstatic while urltest_url defaults to google"
else
	ok "provider health check no longer hardcodes the gstatic probe"
fi

# 补丁是手写的 unified diff：往 + 区加了行却忘了改 hunk 头，git apply 会报
# "corrupt patch"，本地看不出任何问题，等 CI 编译才炸。
if "$PY" "$ROOT/tools/tests/patch_hunks.py" "$ROOT"/tools/sing-box-patches/*.patch >"$WORK/hunks.out" 2>&1; then
	ok "patch hunk headers match their contents ($(tail -1 "$WORK/hunks.out"))"
else
	bad "$(grep -m1 FAIL "$WORK/hunks.out" || tail -1 "$WORK/hunks.out")"
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

# 临时性失败要重试一次，且只重试**这一秒的事**：
#   · exit=6 域名解析失败 —— 点完「保存并应用」立刻更新，正好撞上 stop→start
#     重启 dnsmasq、缓存清空（0.2.6 现场：两条订阅 Could not resolve host，
#     两分钟后的下一轮同样的域名全通）；
#   · HTTP 5xx —— 机场前面的 CDN 或面板抽风（0.2.9 现场：SNY 先报 error: 504
#     / x-cache: Error from cloudfront，随后几轮报 error: 500）。
# 429 绝不能重试：那是机场限流，再打只会把封禁拖长。所以只认 exitcode 6，
# 以及 exitcode 22 且 stderr 里写明 5xx。
# 要求：① 触发条件按上面两种判，不按「所有失败」；② 等 1 秒用 busybox 的
#       sleep（不是 ucode 的 sleep()，单位没有明确写死）；③ 成功/失败都留一行，
#       否则日志里只看到「失败→成功」却不知道中间重试过。
if grep -q 'function transient_failure' "$SUB_UC" \
   && grep -q 'function fetch_with_dns_retry' "$SUB_UC" \
   && grep -q 'exitcode === 6' "$SUB_UC" \
   && grep -q 'exitcode === 22 && match' "$SUB_UC" \
   && grep -q 'error: 50\[0-4\]' "$SUB_UC" \
   && grep -q "system('sleep 1')" "$SUB_UC" \
   && grep -q 'Transient failure for %s (%s: %s), retrying once in 1s.' "$SUB_UC" \
   && grep -q 'Retry after transient failure succeeded for %s.' "$SUB_UC"; then
	ok "a DNS hiccup or a CDN 5xx is retried once instead of failing the airport"
else
	bad "transient failures (DNS / 5xx) still fail the whole airport, or the retry would also fire on 429"
fi

# 分组没有成员时，内核会整个起不来：
#   FATAL: start outbound: start endpoint/urltest[香港自动]: missing outbound and provider tags
# 而启动顺序是「先装防火墙/DNS 劫持、再拉起内核」，于是用户点「清除所有订阅
# 节点」之后（节点 0 个 → 分组空 → 内核 exit 1）整个局域网失去 DNS，连订阅都
# 拉不回来 —— 只能 SSH 进来自救。两道防线：
#   ① generate_client 给空分组兜底一个 direct-out，配置永远合法；
#   ② 启动后用 setsid 拉起 core_guard.sh：15 秒内必须看到内核进程，否则
#      调 /etc/init.d/homeproxy stop 撤掉劫持。三处踩过的坑：不能在启动函数里
#      直接 pgrep（procd 异步拉起，1 秒时进程还没 exec，必然误判）；不能只看
#      内核日志（会被轮转/截断）；不能用 `( … ) &`（init 退出时子 shell 被一起
#      杀掉，检查活不到 15 秒 —— 探针只写到了 start）。
GEN_UC="$PKG/root/etc/homeproxy/scripts/generate_client.uc"
INIT_SH="$PKG/root/etc/init.d/homeproxy"
if grep -q "outbounds: length(urltest_tags) ? urltest_tags : \[ 'direct-out' \]" "$GEN_UC" \
   && grep -q "outbounds: length(selector_tags) ? selector_tags : \[ 'direct-out' \]" "$GEN_UC" \
   && grep -q '^firewall_teardown() {' "$INIT_SH" \
   && [ "$(grep -c 'firewall_teardown' "$INIT_SH")" -ge 2 ] \
   && grep -q 'setsid /bin/sh "$HP_DIR/scripts/core_guard.sh"' "$INIT_SH" \
   && [ -x "$PKG/root/etc/homeproxy/scripts/core_guard.sh" ] \
   && grep -q '内核启动 15 秒后仍未运行' "$PKG/root/etc/homeproxy/scripts/core_guard.sh" \
   && grep -q 'homeproxy stop' "$PKG/root/etc/homeproxy/scripts/core_guard.sh"; then
	ok "an empty group falls back to direct, and a core that dies right after start tears the hijack down"
else
	bad "empty groups can still kill the core, or a dead core leaves the LAN without DNS"
fi

# 真机全功能走查（0.2.9）查出的三个后端问题，各留一条闸门：
#   ① singbox_generator 把空 params 也拼进命令行 → `generate uuid ''` 报
#      `unknown command ""`，uuid / reality-keypair / wg-keypair 三个「生成」
#      按钮全部失效（返回空对象，前端还把字段填成空串）；ech-keypair 反过来
#      缺参数直接失败；
#   ② certificate_write 调用了 ucode 里**不存在**的 is_binary() → 抛异常 →
#      rpcd 折叠成 "Unknown error"，上传证书/私钥从来就没成功过；
#   ③ resources_update 只回一个数字，界面上一句「更新失败」，真正的原因
#      （GitHub API 限流等）只写在日志里。
RPC_UC="$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"
STATUS_JS="$PKG/htdocs/luci-static/resources/view/homeproxy/status.js"
if grep -q "const params = trim(req.args?.params" "$RPC_UC" \
   && grep -q "missing plain server name" "$RPC_UC" \
   && grep -q -e "-----BEGIN PRIVATE KEY-----" "$RPC_UC" \
   && ! grep -q "is_binary(filecontent)" "$RPC_UC" \
   && grep -q 'fh.seek(before)' "$RPC_UC" \
   && grep -q 'res.log' "$STATUS_JS"; then
	ok "key generation, certificate upload and resource updates report like real features"
else
	bad "a ucode builtin that does not exist, an empty argv, or a bare status code still breaks these buttons"
fi

# 一条订阅都没成功时不许重启内核，也不许说 Successfully。
# 旧行为：`need_restart` 恒为 true，机场全挂 / 家里断网时照样 stop+start 一次
# —— 用户看到代理无缘无故断流几秒，节点还一个没变；日志末尾仍然写
# `Successfully updated subscriptions.`，把「一条都没拉到」伪装成成功。
FAIL_LINE=$(grep -n 'if (succeeded === 0)' "$SUB_UC" | cut -d: -f1)
RESTART_LINE=$(grep -n "init_action('homeproxy', 'restart')" "$SUB_UC" | cut -d: -f1)
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
   && grep -q "'subinfo_' + from.slice(0, 16)" "$NODE_JS" \
   && grep -q 'function migrateSubscriptionHashUnsafe' "$NODE_JS" \
   && grep -q 'subscription hash migration skipped' "$NODE_JS"; then
	ok "editing a subscription URL rewrites the old group hash on nodes and groups"
else
	bad "a changed subscription URL leaves nodes orphaned: the dashboard shows the airport as 0/0 with no error"
fi

# 前端 JS 里不许出现 ucode 的全局函数。0.2.9 现场：改订阅地址后点「保存当前
# 设置」一直转圈、配置根本没写进去 —— 因为 SubscriptionList.write() 里的迁移
# 代码写了 `'subinfo_' + substr(from, 0, 16)`。`substr()` 是 ucode 的内置函数，
# 浏览器里只有 String.prototype.substr，于是抛 ReferenceError：保存中断，
# 界面没有任何提示。node --check 抓不到（语法完全合法），只有真的点一下才会
# 暴露。这里挡住表达式位置上的同类调用（`+ substr(` / `= sprintf(` …）。
if ! grep -qE "[+][[:space:]]*(substr|sprintf|strlen|trim)[[:space:]]*\(" "$NODE_JS"; then
	ok "the subscription form does not call ucode builtins from browser JS"
else
	bad "browser JS calls a ucode-only builtin (substr/sprintf/…): saving the form will throw and hang"
fi

# 上面两条只证明「写成什么样」，证明不了「跑起来对不对」。这个用例把函数真
# 执行一遍：改地址后节点段换 grouphash、分组换勾选、userinfo 键跟着搬；同名
# 同地址重存不写任何东西；内部抛异常也不能把保存带崩。
section "Subscription hash migration (frontend)"
"$NODE" "$ROOT/tools/tests/js_migrate_hash.js" "$NODE_JS" > "$WORK/migrate.out" 2>&1
if [ $? -eq 0 ]; then
	ok "js_migrate_hash.js"
else
	bad "js_migrate_hash.js"
	sed 's/^/       /' "$WORK/migrate.out" | tail -12
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

if grep -q -- '--source "服务启动（规则集缺失，后台下载）"' "$INIT"; then
	ok "init.d names the start-up pre-fetch as the trigger"
else
	bad "init.d sync_rulesets does not pass --source"
fi

# ── 启动路径上的三个下载：内核、规则集、面板，一律不许同步跑 ──────────────
# start_service 握着 rc.common 的 procd 锁（lock -w，无超时），任何一次慢下载
# 都会让「启动/重载/装包」整体排队。0.2.14 现场：21 条规则集 4 分 10 秒、
# 9 MB 面板 7 分钟以上，用户看到的就是「装完很久没反应」。
if ! sed -n '/^sync_rulesets()/,/^}/p' "$INIT" | grep -qE 'rs_waited|wait "\$rs_pid"|while \[ -f "\$rs_flag"'; then
	ok "rule-set pre-fetch no longer blocks start (it is handed to a background job)"
else
	bad "sync_rulesets still waits for the download while holding the procd lock"
fi

if grep -q -- '--autostart >>"\$LOG_PATH"' "$INIT" \
   && sed -n '/^sync_rulesets()/,/^}/p' "$INIT" | grep -q 'return 1'; then
	ok "the background rule-set job starts the service itself, and start returns early"
else
	bad "a missing rule-set would neither start the service later nor stop start from running the core"
fi

# 内核起来的前提是规则集齐全（local 文件缺失 → 内核 FATAL），所以 start_service
# 必须认这个返回值，否则会带着空规则集去启动内核。
if sed -n '/^start_service()/,/^}/p' "$INIT" | grep -q 'if ! sync_rulesets; then'; then
	ok "start_service stops when the rule-sets are not ready yet"
else
	bad "start_service ignores sync_rulesets and would start the core with missing rule-sets"
fi

# 面板：真正的下载留在 ensure_panel_worker，对外只暴露「检查 + 转后台」。
if grep -q '^ensure_panel_worker()' "$INIT" \
   && sed -n '/^ensure_panel()/,/^}/p' "$INIT" | grep -q 'ensure_panel_worker' \
   && sed -n '/^ensure_panel()/,/^}/p' "$INIT" | grep -q "pgrep -f '\[f\]etch_panel.sh'"; then
	ok "the panel download is a detached worker, and a second caller does not start a duplicate"
else
	bad "ensure_panel still downloads synchronously on the start path"
fi

if ! sed -n '/^ensure_panel()/,/^}/p' "$INIT" | grep -qE 'sleep 2|seq 1 300|--budget 900'; then
	ok "the fast ensure_panel has no waiting loop of its own"
else
	bad "ensure_panel still polls the clash API / runs the 900s download inline"
fi

# 后台下的面板**绝不能**为了走直连去停服务：面板只是一块静态文件，
# 停了服务等于把全屋网络掐断几分钟。现场实测过一次（0.2.14 验证时，
# 后台面板下载触发「临时停止 homeproxy」，代理直接断掉）。
# FP 在下面几个小节才赋值，这里先兜一个默认值（同一路径）。
FP="${FP:-$PKG/root/etc/homeproxy/scripts/fetch_panel.sh}"
if grep -q -- '--no-stop-service' "$FP" \
   && grep -q 'NO_STOP_SERVICE=1' "$FP" \
   && sed -n '/^stop_service_for_direct()/,/^}/p' "$FP" | grep -q 'NO_STOP_SERVICE'; then
	ok "the panel downloader can refuse to stop the service (background runs must not cut traffic)"
else
	bad "a background panel download can still stop homeproxy and cut the user's network"
fi

if [ "$(grep -c -- 'fetch_panel.sh\" --budget 900 --no-stop-service' "$INIT")" -ge 2 ]; then
	ok "every background panel download passes --no-stop-service"
else
	bad "a background panel download would stop the service for a direct link"
fi

# 这里也只是想知道「服务在不在跑」，同样不许走会拿锁的 init.d running。
if ! sed -n '/^stop_service_for_direct()/,/^}/p' "$FP" | grep -q 'init\.d/homeproxy running' \
   && grep -q '^service_running()' "$FP"; then
	ok "the panel downloader checks the running service with pgrep, not init.d"
else
	bad "the panel downloader asks init.d running and can deadlock on the procd lock"
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

# ── 面板换装不许留「空目录窗口」，否则内核会自己下 34 MB 并卡死 API ────
# 内核在 clash-api 开始监听**之前**检查 external_ui；看到空目录就走自带下载
# （单源、直连、无镜像、无重试）。2026-10-30 现场：fetch_panel.sh 先 mv 走旧
# 目录、再拷 12 MB，空窗十几秒，正好撞上内核启动 → clash-api 卡 1188 秒，
# 面板一律「无法访问」（代理本身是通的）。所以必须「先铺新目录、再 rename」。
if grep -q 'new_dir="$panel_dir.new"' "$FP" \
   && grep -q 'mv "$new_dir" "$panel_dir"' "$FP" \
   && ! grep -q 'cp -a "$stage"/. "$panel_dir"/' "$FP"; then
	ok "the panel swap stages next to the target and renames (no empty-directory window)"
else
	bad "the panel swap empties external_ui while copying, so the core may start its own 34 MB download"
fi

# 面板已经装好时，不许把下载地址写进生成的配置：那条路径会阻塞 clash-api。
GEN="$PKG/root/etc/homeproxy/scripts/generate_client.uc"
if grep -q 'function panel_download_url' "$GEN" \
   && grep -q 'external_ui_download_url: clash_panel_url' "$GEN" \
   && ! grep -q "external_ui_download_url: uci.get(uciconfig, uciclashapi, 'external_ui_download_url')" "$GEN"; then
	ok "the generator only hands external_ui_download_url to the core when the panel is missing"
else
	bad "the core still gets an external_ui_download_url even with the panel installed (it blocks the Clash API)"
fi

# ── 下载顺序：原地址走代理优先，代理不可用才用镜像直连 ─────────────────
# 两个脚本（面板 fetch_panel.sh / 内核 update_core.sh）必须同一套语义：
# 候选条目带 P/D 前缀，P 只在第一轮出现，第二轮 dirct 前先停服务撤掉 tproxy。
UCORE="$PKG/root/etc/homeproxy/scripts/update_core.sh"

# P 必须排在 D 前面 —— 按行号比，别去拼 "printf 'D|%s\n' ..." 这种带引号、
# 反斜杠和 $ 的模式串，转义层数一多就变成匹配 "%sn"，白红一轮。
P_LINE=$(grep -n "printf 'P|%s" "$FP" | head -n1 | cut -d: -f1)
D_LINE=$(grep -n "printf 'D|%s" "$FP" | head -n1 | cut -d: -f1)
if [ -n "$P_LINE" ] && [ -n "$D_LINE" ] && [ "$P_LINE" -lt "$D_LINE" ]; then
	ok "the panel download lists the proxy-first candidate before any mirror"
else
	bad "the panel download still tries mirrors before the proxy"
fi

# 直连轮里镜像必须排在原地址前面：直连 github.com 实测只有 60~80 KB/s 且易断，
# 放前面会把整个预算耗光（真机实测 5 分钟才下到 5 MB）。
MIRROR_D_LINE=$(grep -n "printf 'D|%s" "$FP" | grep 'gh-proxy\.com' | head -n1 | cut -d: -f1)
ORIGIN_D_LINE=$(grep -n "printf 'D|%s" "$FP" | grep 'direct"$' | tail -n1 | cut -d: -f1)
if [ -n "$MIRROR_D_LINE" ] && [ -n "$ORIGIN_D_LINE" ] && [ "$MIRROR_D_LINE" -lt "$ORIGIN_D_LINE" ]; then
	ok "the panel direct round tries the mirror before the bare GitHub URL"
else
	bad "the panel direct round would start with a slow direct GitHub download"
fi

# 代理必须真的传进 curl/wget；只写注释不传参等于没做。
if grep -q -- '--proxy "$via_proxy"' "$FP" && grep -q 'http_proxy="$via_proxy"' "$FP" \
   && grep -q -- '--proxy "$via_proxy"' "$UCORE"; then
	ok "both downloaders actually pass the proxy to curl and wget"
else
	bad "the proxy endpoint is resolved but never passed to the downloader"
fi

# 代理不可用时「直连」必须是真直连：服务在跑时先停掉（tproxy 会把镜像请求
# 也劫持到当前节点，节点坏了等于所有镜像一起坏）。
#
# 这里原写成 `grep -q ... <(sed -n ...)`，进程替换是 bash 语法：本地 Git Bash
# 的 sh 就是 bash，一路绿灯；CI 与设备上是 dash，解析到这一行直接
# `Syntax error: "(" unexpected` 并让整份自检 exit 2 —— 前面 200 多条 OK 全白跑。
# POSIX 写法：先取到文本存进变量，再喂给 grep。
CLEANUP_BODY="$(sed -n '/^cleanup()/,/^}/p' "$FP")"
if grep -q 'stop_service_for_direct' "$FP" \
   && grep -q '/etc/init.d/homeproxy stop' "$FP" \
   && printf '%s\n' "$CLEANUP_BODY" | grep -q 'restore_service_after_direct'; then
	ok "the panel download stops the service for a real direct link and restores it via trap"
else
	bad "the panel direct round is not a real direct connection (or never restores the service)"
fi

# 没配 mixed_port（老配置 / uci 读不到）时必须跳过代理那条，不能卡住。
if grep -qF '[ -z "$via_proxy" ] && continue' "$FP" \
   && grep -qF '[ -z "$via_proxy" ] && continue' "$UCORE"; then
	ok "a missing mixed_port makes both scripts skip the proxy candidate"
else
	bad "a missing mixed_port would stall the download on a dead proxy"
fi

# 内核缺失（服务根本起不来）正是最需要镜像的时刻。0.2.12 现场：core 文件
# 不在 /usr/bin，服务未运行 → core_direct_retry 直接 return 1 → 四个镜像一次
# 都没试，设备在「无内核」状态下每 6 秒重试一轮、12 分钟 41 次全部只打
# github 直连（rc7），只能人工 SSH 传内核。这一轮必须无条件执行。
if grep -q '不停服务，直接走镜像直连再试一轮' "$UCORE" \
   && ! sed -n '/^core_direct_retry()/,/^}/p' "$UCORE" | grep -q '不再重试'; then
	ok "a missing core still falls back to the mirrors (service down is not a reason to give up)"
else
	bad "the core retry still bails out when the service is not running, so nothing can fetch a missing core"
fi

# 「服务在不在跑」**不能**问 `init.d running`：rc.common 的每个动作都要拿
# procd 锁（lock -w，无超时）。0.2.14 现场：内核缺失 → 后台下载 → 去问
# running，恰好有 procd 触发器发起的 start 握着锁，两边永久互等：一个
# `init.d running` 挂了 10 分钟、三个 start 排在后面，内核装好了也起不来。
if ! sed -n '/^core_direct_retry()/,/^}/p' "$UCORE" | grep -q 'init\.d/homeproxy running' \
   && grep -q '^service_running()' "$UCORE" \
   && sed -n '/^service_running()/,/^}/p' "$UCORE" | grep -q 'pgrep'; then
	ok "the retry asks about the running service with pgrep, not via the locked init.d"
else
	bad "the retry calls init.d running, which blocks on the procd lock and deadlocks against start"
fi

# 下载结束后的自动启动也要让路：rc.common 的锁没有超时，两个 start 撞在
# 一起会互相等到天荒地老。
if sed -n '/^core_direct_restore()/,/^}/p' "$UCORE" | grep -q 'other_start_running'; then
	ok "the post-download start yields when another start is already running"
else
	bad "the post-download start can deadlock against a concurrent start"
fi

# 两轮的账必须分开：否则汇总行会把经代理的失败写成「直连：github.com=rc7」，
# 看起来像镜像全挂、实际镜像根本没被测过。
BUCKET_LINE=$(grep -n 'DOWNLOAD_ATTEMPTS_PROXIED="$DOWNLOAD_ATTEMPTS"' "$UCORE" | head -n1 | cut -d: -f1)
DIRECT_LINE=$(grep -n 'download_file "$url" "$out" asset direct' "$UCORE" | head -n1 | cut -d: -f1)
if [ -n "$BUCKET_LINE" ] && [ -n "$DIRECT_LINE" ] && [ "$BUCKET_LINE" -lt "$DIRECT_LINE" ]; then
	ok "the proxied round is filed under its own label before the direct round starts"
else
	bad "the proxied round's failures would be reported as direct-link failures"
fi

# 一个 reality 节点没带 fp 就能让整个客户端实例起不来
# （FATAL initialize outbound[N]: uTLS is required by reality client）。
# 生成器必须补默认指纹，否则「少一个字段」= 整机断网。
if grep -q "node.type === 'anytls' || (node.tls === '1' && node.tls_reality === '1')" \
   "$PKG/root/etc/homeproxy/scripts/generate_client.uc"; then
	ok "a reality node without fp gets a default uTLS fingerprint (one node cannot break the config)"
else
	bad "a reality node without fp would emit reality without utls and the whole core refuses to start"
fi

# last-start 必须在所有早退分支之前写：它是 reload 风暴守卫的判据。只在启动
# 成功那一刻写，启动一失败就永远不前进 → 守卫失效 → procd 每 6 秒重启一轮。
LS_LINE=$(grep -n 'date +%s >"$RUN_DIR/last-start"' "$INIT" | head -n1 | cut -d: -f1)
ENSURE_LINE=$(grep -n 'CORE_SCRIPT" check' "$INIT" | head -n1 | cut -d: -f1)
if [ -n "$LS_LINE" ] && [ -n "$ENSURE_LINE" ] && [ "$LS_LINE" -lt "$ENSURE_LINE" ]; then
	ok "the reload-storm watermark is written before any early return (a failed start still advances it)"
else
	bad "a failed start never advances last-start, so the reload-storm guard stops working"
fi

# 「UI 下载节点」下拉已删除：它只作用于 sing-box 内建的 /upgrade/ui，
# 对 fetch_panel.sh 这条真正在用的路径毫无作用，留着只会误导。
if grep -q 'external_ui_download_detour' "$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"; then
	bad "the dead 'UI download detour' dropdown is still in the panel settings"
else
	ok "the dead 'UI download detour' dropdown is gone from the panel settings"
fi

# 下载地址下拉里每个面板只留一条（GitHub 原地址）。之前同一份 Zashboard
# 列了 gh-proxy / ghproxy.net / 直连三条，看起来像三个不同面板，实际只是
# 同一个文件的三条路径 —— 而这三条现在由脚本自动选。
if grep -q "so.value('https://gh-proxy.com/" "$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"; then
	bad "the UI download list still offers mirror-prefixed duplicates of the same dashboard"
else
	ok "the UI download list offers exactly one entry per dashboard"
fi

# 老配置里存的是带前缀的地址：load 时先剥掉前缀再匹配，否则会退化成「自定义」。
if grep -q 'stripPanelMirror' "$PKG/htdocs/luci-static/resources/view/homeproxy/client.js" \
   && grep -q 'const value = stripPanelMirror(uci.get' "$PKG/htdocs/luci-static/resources/view/homeproxy/client.js"; then
	ok "an old mirror-prefixed panel URL still shows up as its named preset"
else
	bad "an old mirror-prefixed panel URL would fall back to the Custom entry"
fi

# 「终端里敲 reload 就该真的重载」：登录 shell 直接 exec 时 $PPID 就是 shell，
# 之前落到「未识别」→ 按 mtime 判定 → 配置没变就跳过，与约定不符。
if grep -q '终端手动执行（登录 shell）' "$INIT" \
   && grep -q '\*终端手动执行\*' "$INIT"; then
	ok "a reload typed in an interactive shell is treated as a manual request"
else
	bad "a reload typed in an interactive shell may be skipped as unidentified"
fi

# 但被 shell 包一层执行（ash -c '...'）不能算手动：有脚本循环这么调的话，
# force=1 会把服务带成重载风暴。
if grep -q 'shell 包装调用' "$INIT"; then
	ok "a shell-wrapped reload is not forced (storm guard still applies)"
else
	bad "a shell-wrapped reload would be forced and could storm"
fi

# ── 配置文件管理：固定目录、白名单文件名、校验后切换 ─────────────────────
# 需求：/etc/config/ 下只认 homeproxy-* 命名；默认配置改名 homeproxy-default
# 且不进上传列表；切换前必须校验，格式错误不能覆盖当前配置；普通 LuCI
# 保存要写回当前选中的配置文件。
PROFILE_SH="$PKG/root/etc/homeproxy/scripts/config_profile.sh"
PROFILE_VIEW="$PKG/htdocs/luci-static/resources/view/homeproxy/configfile.js"
PROFILE_MENU="$PKG/root/usr/share/luci/menu.d/luci-app-homeproxy.json"

if [ -f "$PROFILE_SH" ] && grep -q 'PROFILE_DIR="/etc/config"' "$PROFILE_SH" \
   && grep -q 'homeproxy-default' "$PROFILE_SH"; then
	ok "configuration profiles live in /etc/config and the default is homeproxy-default"
else
	bad "configuration profiles do not use the fixed /etc/config directory or default name"
fi

# 文件名白名单必须在，且必须挡掉 homeproxy-back（apk 保留的旧文件）。
if grep -qF '*[!A-Za-z0-9._-]*' "$PROFILE_SH" \
   && grep -q 'homeproxy-back' "$PROFILE_SH"; then
	ok "profile names are whitelisted and apk's homeproxy-back is refused"
else
	bad "profile filenames are not whitelisted (path traversal or homeproxy-back would slip through)"
fi

# 切换/上传前都必须先校验：validate_file 被 switch 与 upload 两个分支调用。
if grep -q '^validate_file()' "$PROFILE_SH" \
   && sed -n '/^switch)/,/^;;/p' "$PROFILE_SH" | grep -q 'validate_file' \
   && sed -n '/^upload)/,/^;;/p' "$PROFILE_SH" | grep -q 'validate_file'; then
	ok "switching and uploading both validate the UCI file before touching the active config"
else
	bad "a broken profile could replace the active configuration without being validated"
fi

# 写盘必须是「临时文件 + mv」：BusyBox 上直接覆盖被中断会留下半截配置。
if grep -q 'atomic_copy()' "$PROFILE_SH" \
   && sed -n '/^atomic_copy()/,/^}/p' "$PROFILE_SH" | grep -q 'mv -f'; then
	ok "profile writes go through a temp file and rename (no half-written config)"
else
	bad "profile writes overwrite the target in place and can be left half-written"
fi

for method in config_profile_list config_profile_read config_profile_check \
              config_profile_switch config_profile_upload config_profile_delete; do
	if ! grep -q "${method}:" "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"; then
		bad "rpcd is missing ${method}"
	fi
done
if grep -q 'config_profile_list:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'config_profile_read:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'config_profile_switch:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'config_profile_upload:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'config_profile_delete:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy"; then
	ok "rpcd exposes list / read / check / switch / upload / delete for configuration profiles"
else
	bad "rpcd does not expose the full configuration profile API"
fi

# 上传必须落到固定临时文件（ACL 已授写），名字由 RPC 参数决定而不是路径拼接。
if grep -q "/tmp/homeproxy_profile.tmp" "$PROFILE_SH" \
   && grep -q "/tmp/homeproxy_profile.tmp" "$PKG/root/usr/share/rpcd/acl.d/luci-app-homeproxy.json"; then
	ok "profile uploads land in the ACL-approved fixed temp file"
else
	bad "profile uploads use a path that the ACL does not allow (or an unsanitised one)"
fi

if grep -q 'homeproxy/configfile' "$PROFILE_MENU" \
   && grep -q '切换并应用' "$PROFILE_VIEW" \
   && grep -q 'ui.uploadFile' "$PROFILE_VIEW"; then
	ok "the configuration-file tab exists between Server Settings and Service Status, with its own switch button"
else
	bad "the configuration-file tab or its explicit switch/apply button is missing"
fi

# 普通 LuCI 保存必须写回当前选中的配置文件，否则切过去的配置会被悄悄丢掉。
if grep -q 'config_profile.sh.*sync' "$INIT" \
   && grep -q 'current_profile' "$PROFILE_SH"; then
	ok "ordinary LuCI saves sync the active configuration back to the selected profile"
else
	bad "ordinary LuCI saves are not tied to the selected profile (edits would be lost on switch)"
fi

# 这个脚本与 config_guard.sh 一样是 644、一律用 `sh` 调用。守卫若写成
# `[ -x ... ]`，整条同步会**永远不执行**而且不留任何痕迹（真机踩过）。
if grep -q '\[ -f "$HP_DIR/scripts/config_profile.sh" \] && sh' "$INIT" \
   && ! grep -q '\[ -x "$HP_DIR/scripts/config_profile.sh" \]' "$INIT"; then
	ok "the start-path profile sync is guarded by -f, not -x (a 644 script would never run)"
else
	bad "the profile sync uses -x on a 644 script, so it silently never runs"
fi

# 手工改坏的配置（段名带 `-`、少引号、同名 option）不会让任何一步报错：uci 只是
# 静默跳过坏段，生成出来的配置里一个节点都不剩，而空配置对 `sing-box check` 完全
# 合法 —— 服务照样「已启动」，用户只看到所有节点都连不上，日志一句错误都没有
# （2026-10-30 现场：`config node 'homeproxy-test'` 让整份配置失效）。生成前必须
# 先整份解析一遍，把 uci 的行号写进日志。
if grep -q 'uci show "\$CONF"' "$INIT" \
   && grep -q 'UCI 语法错误' "$INIT" \
   && sed -n '/^start_service()/,/^}/p' "$INIT" | grep -q 'uci show "\$CONF"'; then
	ok "a broken UCI config is reported instead of silently generating an empty one"
else
	bad "a UCI parse error still yields a node-less config: no proxy, no log line"
fi

# 上传名的输入框不能预填示例（`placeholder: homeproxy-123` 看起来就像已经填好
# 的文件名，用户点上传会以为名字已定）；命名规则改由说明文字承担。
if ! grep -q "'placeholder'" "$PROFILE_VIEW" \
   && grep -q 'must be named homeproxy-<your-name>' "$PROFILE_VIEW"; then
	ok "the upload name field carries no pre-filled example; the hint states the homeproxy-* rule"
else
	bad "the upload name field is still pre-filled with an example (or the naming rule is unstated)"
fi

# UCI 配置没有扩展名：文件选择器一旦设 accept，Windows 上「打开」对话框就只剩
# 「自定义文件 (*.conf;*.uci)」，无后缀的 homeproxy 备份直接看不见（`*/*` 会被
# 浏览器折叠掉，放不了行）。所以这里必须不设 accept。
if ! grep -q "'accept'" "$PROFILE_VIEW" \
   && grep -q "'type': 'file'" "$PROFILE_VIEW"; then
	ok "the upload picker accepts every file (UCI configs have no extension)"
else
	bad "the upload picker filters by extension, so extension-less UCI configs are invisible"
fi

# 上传只留一个动作：点「上传文件」打开文件选择框，选完立刻上传，名字取自文件名
# （只切 .conf/.uci 这类真扩展名，homeproxy-0.2.15 的 .15 保留）。页面上不再有
# 名称输入框，也没有第二个「上传」按钮 —— 之前那两个框和两个按钮让人不知道先填谁。
if grep -q "uploadFile.addEventListener('click', () => fileInput.click())" "$PROFILE_VIEW" \
   && grep -q 'uploadProfile(name)' "$PROFILE_VIEW" \
   && ! grep -q 'nameInput' "$PROFILE_VIEW"; then
	ok "one upload button: picking a file uploads it right away, name taken from the file"
else
	bad "upload still needs a separate name box or a second button"
fi

# 上传必须挡大小：真实的 UCI 配置几十 KB，不设上限时误选一个镜像/日志就会被
# 写进 /etc/config（overlay 在 flash 上），写满之后连 uci commit 都会失败。
if grep -q '1048576' "$PROFILE_SH" \
   && grep -q 'size > 1048576' "$PROFILE_VIEW"; then
	ok "uploads are capped at 1 MB on both the page and the script"
else
	bad "upload has no size cap (a mis-picked file would land in /etc/config)"
fi


# 跑 uci show，通过才替换激活配置；失败时下拉必须退回当前生效的那个，
# 否则界面停在一个「看起来已选中、其实没生效」的选项上。
if ! grep -q '检查配置' "$PROFILE_VIEW" \
   && grep -q 'select.value = current' "$PROFILE_VIEW" \
   && sed -n '/^switch)/,/^;;/p' "$PROFILE_SH" | grep -q 'validate_file'; then
	ok "switch-and-apply validates first and rolls the selector back when it fails"
else
	bad "the check button is gone but apply neither validates nor rolls the selector back"
fi

# 删除必须是「按文件行 + 二次确认」，不能再有贴着选下拉的「删除选中配置」：
# 那种按钮一歪手就把另一份配置删了，而且删掉只能重新上传。
# 匹配时带上 `_(`：只禁掉那枚按钮本身，注释里提到它的名字不算犯规。
if ! grep -q "_('删除选中配置')" "$PROFILE_VIEW" \
   && grep -q 'ui.showModal(' "$PROFILE_VIEW" \
   && grep -q 'callDelete' "$PROFILE_VIEW"; then
	ok "delete is a per-file action behind a confirmation dialog"
else
	bad "delete is either missing per-file or still a one-click button next to the selector"
fi

# 每个已上传的配置都要能下载出来（备份/搬机器都用得上）：rpcd 回内容，
# 前端用 Blob + a[download] 落盘，文件名由界面决定。
if grep -q 'config_profile_read:' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && grep -q 'callRead' "$PROFILE_VIEW" \
   && grep -q "download: name" "$PROFILE_VIEW"; then
	ok "each uploaded profile can be downloaded as a file"
else
	bad "uploaded profiles cannot be downloaded (no read RPC or no download link)"
fi

# 删除确认框里的两个按钮也必须用 cbi-button：只写 `btn` 会和页面其它按钮不同高
# （`btn` 是 LuCI 的 bootstrap 基线，cbi-button 自带 padding 与边框）。
if [ "$(grep -c "'class': 'cbi-button" "$PROFILE_VIEW")" -ge 5 ] \
   && ! grep -q "'class': 'btn'" "$PROFILE_VIEW"; then
	ok "dialog buttons share the cbi-button style used by the page buttons"
else
	bad "a dialog button still uses the bare btn class and will not line up"
fi

# 「上传文件」「刷新列表」「下载」统一成蓝色动作按钮（cbi-button-action）：这一页上
# 灰色默认按钮看着不像能点，用户明确要求这三个跟「切换并应用」一样是蓝色。
if [ "$(grep -c "'class': 'cbi-button cbi-button-action'" "$PROFILE_VIEW")" -ge 3 ]; then
	ok "upload / refresh / download share the blue action style"
else
	bad "one of upload / refresh / download is still a grey default button"
fi

# 标题下那段「管理 HomeProxy 配置文件…普通设置仍用右下角保存并应用…」用户要求去掉：
# 它是纯说明，占掉一整行，而下拉与按钮本身已经把用法摆出来了。
if ! grep -q 'Manage HomeProxy configuration files' "$PROFILE_VIEW"; then
	ok "no how-to paragraph under the page title"
else
	bad "the how-to paragraph under the page title is back"
fi

# 「状态」标签与「当前配置文件：xxx」都已去掉：当前配置在下面的下拉里就看得到，
# 再写一行只是重复；那一行只留一句校验说明（用户明确要求）。
if ! grep -q "_('Status')" "$PROFILE_VIEW" \
   && ! grep -q 'Current configuration file' "$PROFILE_VIEW"; then
	ok "the status row no longer repeats what the selector already shows"
else
	bad "a separate status row duplicates the active profile the selector shows"
fi

# 下拉的选中项必须靠 value 设定：把 `selected: false` 交给 E() 会写出
# selected="false"，而 HTML 里属性存在就算选中 —— 所有 option 都成选中态，
# 刷新后停下来的那一项不是当前配置（0.3.1 现场：状态写 default、下拉停 0.2.15）。
if grep -q 'select.value = current' "$PROFILE_VIEW" \
   && ! grep -q 'selected: name === current' "$PROFILE_VIEW"; then
	ok "the selector starts on the active profile (set by value, not by an attribute)"
else
	bad "the selector relies on a selected attribute that E() writes even when false"
fi

# LuCI 的 E() 不会跳过 null 子节点，它被当成文本节点渲染成字面 "null"（0.3.1
# 现场：「使用中」那一行的删除按钮位置就印着 null）。条件子节点只能用数组 push。
# 判据看结构而不是 grep 关键字：注释里提到这个写法时不该误报。
if grep -q 'const cells = \[' "$PROFILE_VIEW" \
   && grep -q 'cells.push(E(' "$PROFILE_VIEW"; then
	ok "conditional cells are pushed into an array (E would print a null child verbatim)"
else
	bad "a null child would render as the literal text null on the page"
fi

# 切换失败必须在主日志里留下原因（uci 的 Parse error 带 line/byte）：只闪一条
# 通知，页面一刷新就什么都不剩，用户只能反复重试。
if grep -q 'function profileLog' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" \
   && sed -n '/config_profile_switch:/,/^[[:space:]]*},/p' "$PKG/root/usr/share/rpcd/ucode/luci.homeproxy" | grep -q '配置文件切换失败'; then
	ok "a failed profile switch writes its reason to the main log, not just a notification"
else
	bad "a failed profile switch leaves nothing in the log"
fi

# ── QUIC 不支持的节点：一次汇总，不再逐节点写两行 ────────────────────────
# 0.2.12 现场：内核文件不在 /usr/bin → rpcd 的 features 读不到任何 tag →
# 订阅里 18 个 hysteria2 节点被丢掉，而每个节点写两行日志（36 行噪音），
# 真正有用的「内核不可用」反而被埋掉，用户以为要重编内核。
if grep -q 'function note_skipped_quic' "$SUB_UC" \
   && [ "$(grep -c 'return note_skipped_quic(' "$SUB_UC")" -ge 8 ]; then
	ok "nodes dropped for missing QUIC support are collected, not logged one by one"
else
	bad "each QUIC node still writes its own two log lines (noise buries the real cause)"
fi

if ! grep -v '^[[:space:]]*\*' "$SUB_UC" | grep -q 'Please rebuild sing-box'; then
	ok "the misleading 'Please rebuild sing-box with QUIC support' line is gone"
else
	bad "the log still tells users to rebuild sing-box when the real cause may be a missing core"
fi

if grep -q '跳过 %d 个需要 QUIC 的节点' "$SUB_UC" \
   && grep -q 'isEmpty(sing_features.version)' "$SUB_UC"; then
	ok "the QUIC summary names the real reason (kernel missing) and lists the nodes once"
else
	bad "the QUIC skip summary cannot tell 'kernel missing' from 'built without QUIC'"
fi

# 失败原因必须排除「提示：…」这类建议性文案，否则真因被顶掉（0.2.13 现场
# 被引去查 NTP）。启动路径现在不下载了，这段逻辑落在异步启动器里：下载失败
# 时把具体原因写进 core_update.out，面板读的就是它。
if grep -q "grep -v '提示：'" "$PKG/root/etc/homeproxy/scripts/update_core_async.sh" \
   && grep -q "printf 'failed: %s" "$PKG/root/etc/homeproxy/scripts/update_core_async.sh"; then
	ok "the download failure reason prefers the concrete failure over the NTP hint"
else
	bad "the download failure reason can surface a hint line instead of the real cause"
fi

# ── 启动路径不许等内核下载（0.2.13 现场：apk 安装被卡 10 分钟）─────────
# start_service 只能做「本地就绪检查」，一旦缺内核就转后台，绝不能同步跑
# ensure（那会真的下 26 MB，期间还握着 procd 锁，面板点什么都在排队）。
if ! sed -n '/^start_service()/,/^}/p' "$INIT" | grep -q 'CORE_SCRIPT" ensure'; then
	ok "the start path never runs a synchronous core download"
else
	bad "start_service still blocks on the 26 MB core download while holding the procd lock"
fi

if sed -n '/^start_service()/,/^}/p' "$INIT" | grep -q 'CORE_SCRIPT" check' \
   && grep -q 'core=ready' "$PKG/root/etc/homeproxy/scripts/update_core.sh" \
   && grep -q 'core=unsupported' "$PKG/root/etc/homeproxy/scripts/update_core.sh"; then
	ok "the start path asks a local-only 'check' and can tell ready / missing / unsupported"
else
	bad "there is no local core check, so start must guess or download"
fi

# ── 后台派生必须关掉 procd 锁的 fd（1000）────────────────────────────
# init.d 的每个动作都在 procd 锁里跑，那把锁的 fd 是 1000（procd_lock 里 exec）。
# fd 会被后台子进程继承：父进程退出后锁仍被握着，之后所有 start / stop / reload
# 都卡在阻塞的 flock 上（最长十几分钟，表象是「点了没反应、日志一行不写」）。
# 更糟的是 update_core_async.sh 下完内核会回调 init.d start，那是在等自己继承
# 的那把锁 → 自锁，服务永远起不来（2026-10-30 设备实验证实继承成立）。
# 所以每处 `… &` 派生都要先 `exec 1000>&-`，两边数量必须一一对上。
spawns=$(grep -cE '(^|[^&])&[[:space:]]*\)?[[:space:]]*$' "$INIT")
lock_closers=$(grep 'exec 1000>&-' "$INIT" | grep -vc '^[[:space:]]*#')
if [ "$spawns" -gt 0 ] && [ "$spawns" -eq "$lock_closers" ] \
   && grep -q '1000>&- 2>/dev/null; prefetch_panel' "$INIT" \
   && grep -q '1000>&- 2>/dev/null; setsid' "$INIT"; then
	ok "every background spawn in init.d closes the procd lock fd (1000) first"
else
	bad "a background child inherits the procd lock fd, so later start/reload block ($spawns spawns vs $lock_closers closers)"
fi

# 内核下载失败后 10 分钟内不再自动重试：用户网络不通时，每次「保存并应用」
# 都等于一次 reload，会把 26–34 MB 重新拉一遍，日志被刷满、流量白耗。
# 手动「更新内核」按钮不走这条路径（rpcd 直接 --detach），退避挡不住主动重试。
if sed -n '/^start_core_download_in_background()/,/^}/p' "$INIT" | grep -q 'core_update.rc' \
   && sed -n '/^start_core_download_in_background()/,/^}/p' "$INIT" | grep -q 'rc_age' \
   && sed -n '/^start_core_download_in_background()/,/^}/p' "$INIT" | grep -q 'lt 600'; then
	ok "a failed core download is not retried on every reload (10 minute backoff)"
else
	bad "every save-and-apply retries the 26 MB core download while the network is down"
fi

# check 必须是纯本地：分支里不许出现下载动作。
if ! sed -n '/^\t\tcheck)/,/^\t\t\t;;/p' "$PKG/root/etc/homeproxy/scripts/update_core.sh" \
   | grep -qE 'download_file|curl|wget|ensure_core'; then
	ok "the core check never touches the network (no curl / download_file inside)"
else
	bad "update_core.sh check performs a network operation"
fi

# 缺内核时转后台：启动器必须带 --start-after，下完自己把服务拉起来。
if grep -q 'start_core_download_in_background' "$INIT" \
   && sed -n '/^start_core_download_in_background()/,/^}/p' "$INIT" | grep -q -- '--detach --source "$src" --start-after'; then
	ok "a missing core is handed to the detached downloader, which starts the service afterwards"
else
	bad "a missing core is not handed to the background downloader (start would still block)"
fi

# 参数必须原样透传给 detach 出去的 worker，否则 --start-after 会被吞掉。
if sed -n '/--detach/,/^fi$/p' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh" \
   | grep -q 'no /bin/sh "$0" "$@"\|/bin/sh "$0" "$@"'; then
	ok "the detached launcher passes its arguments through to the worker"
else
	bad "the detach stage drops --source / --start-after"
fi

if grep -q -- '--start-after' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh" \
   && grep -q 'init.d/homeproxy start' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh"; then
	ok "the background downloader starts the service itself once the core is in place"
else
	bad "the background downloader never starts the service, so the user must click again"
fi
# 启动服务必须**直接执行** init.d（它的 shebang 是 `#!/bin/sh /etc/rc.common`）。
# 写成 `sh /etc/init.d/homeproxy start` 会跳过 shebang：rc.common 没被 source，
# 函数定义完就结束，退出码 0 却什么都没做 —— 服务静默不启动、日志一行都没有。
if ! grep -q 'sh /etc/init.d/homeproxy start' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh" \
   && grep -qE '^[[:space:]]*/etc/init.d/homeproxy start' "$PKG/root/etc/homeproxy/scripts/update_core_async.sh"; then
	ok "the post-download start executes init.d directly, so rc.common actually dispatches"
else
	bad "the post-download start bypasses the shebang and silently does nothing"
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

# 镜像列表里放过两个已经注销的域名（hub.gitmirror.com / github.moeyy.xyz）：
# 每次下载都要白等一次 NXDOMAIN，日志里留下 `返回码 6`，用户会以为是自己
# 路由器 DNS 坏了。2026-10-28 现场 nslookup 实测两个域名都是 NXDOMAIN。
# 只判赋值那一行：注释里会提到这些域名（说明它们为什么被移除）。
MIRROR_LINE="$(grep '^GH_PROXY_PREFIXES=' "$UC" | head -n1)"
case "$MIRROR_LINE" in
	*hub.gitmirror.com*|*github.moeyy.xyz*)
		bad "the core mirror list still holds a dead domain (NXDOMAIN since 2026-10-28)" ;;
	*gh-proxy.com*)
		ok "the core mirror list no longer holds the dead domains" ;;
	*)
		bad "GH_PROXY_PREFIXES is missing or unrecognised" ;;
esac

if grep -q '^GH_PROXY_PREFIXES="https://gh-proxy\.com/ https://ghproxy\.net/' "$UC"; then
	ok "the two mirrors measured reachable lead the core download list"
else
	bad "the core download list does not lead with the mirrors that actually work"
fi

# 全源失败时，真正的原因常常是「当前代理节点已失效」而不是镜像挂了：
# 服务运行时路由器自身出站被 tproxy 劫持，curl 拿到的不是直连。
# 这时必须停一次服务（firewall_teardown 撤掉劫持）再用真直连重试一轮。
if grep -q 'core_direct_retry' "$UC" \
   && grep -q '/etc/init\.d/homeproxy stop' "$UC" \
   && grep -q 'core_direct_retry "$asset_url"' "$UC"; then
	ok "a fully failed core download retries over a real direct link (service stopped first)"
else
	bad "core download never falls back to a genuine direct connection"
fi

if grep -q 'core_direct_restore' "$UC" && grep -q '/etc/init\.d/homeproxy start' "$UC"; then
	ok "the service is restarted no matter how the direct retry ends"
else
	bad "the service stays stopped after a direct retry"
fi

# 失败收口必须带上每个源的返回码（6=域名解析失败、28=超时、22=HTTP 4xx/5xx），
# 只写「下载失败」用户分不清是自家网络坏了还是镜像失效。
if grep -q 'DOWNLOAD_ATTEMPTS' "$UC" \
   && grep -q 'rc${rc}/http${LAST_HTTP:-000}' "$UC" \
   && grep -q '所有源都不可用' "$UC"; then
	ok "a failed core download lists every source with its return code"
else
	bad "a failed core download reports only a bare 'download failed'"
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
SUB_RESTART_HITS=$(grep -c "init_action('homeproxy', 'restart')" "$SUB")
SUB_STOP_HITS=$(grep -c "init_action('homeproxy', 'stop')" "$SUB")
SUB_START_HITS=$(grep -c "init_action('homeproxy', 'start')" "$SUB")
if [ "$SUB_RESTART_HITS" = 1 ] && [ "$SUB_STOP_HITS" = 0 ] && [ "$SUB_START_HITS" = 0 ] \
   && ! grep -q "log('Stopping service...')" "$SUB" \
   && ! grep -q "log('Starting service...')" "$SUB" \
   && sed -n '/^\tif (need_restart)/,/^\t}/p' "$SUB" | grep -q "init_action"; then
	ok "subscription update touches the service only on success (one restart)"
else
	bad "a failed subscription update can stop or restart the running service ($SUB_RESTART_HITS restart / $SUB_STOP_HITS stop / $SUB_START_HITS start)"
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

# 跳过日志必须按**时间**节流，不能按次数。0.2.12 现场风暴峰值约 100 次/秒，
# 「每 200 次记一行」结果是每 2 秒一行、几分钟 4.5 万条，面板翻半屏都是同一句。
if grep -q '\.reload-skips-ts' "$INIT" \
   && ! sed -n '/^reload_service()/,/^}/p' "$INIT" | grep -q '% 200'; then
	ok "skip logging is throttled by time, not by a count modulo"
else
	bad "skip logging is still throttled by occurrence count, which floods during a storm"
fi

# 完全相同的日志连续出现时合并成一条并计次（主日志与面板日志同一套）。
if grep -q '^log_dedup_write()' "$INIT" \
   && sed -n '/^log() {/,/^}/p' "$INIT" | grep -q 'log_dedup_write' \
   && sed -n '/panel_log() {/,/^\t}/p' "$INIT" | grep -q 'log_dedup_write'; then
	ok "identical log lines are merged with a count (main log and panel log share it)"
else
	bad "repeated log lines are written one by one and bury the real errors"
fi

# 只合并逐字相同的行：不许做数字归一，否则 rc7 / rc28、不同节点名会被吞掉。
if sed -n '/^log_dedup_write() {/,/^}/p' "$INIT" | grep -q '\[ "$prev" = "$text" \]' \
   && ! sed -n '/^log_dedup_write() {/,/^}/p' "$INIT" | grep -q 'sed '; then
	ok "log merging keys on the exact text, so different rc codes are never folded together"
else
	bad "log merging normalises the text and can silently swallow distinct errors"
fi

# 被合并掉的面板日志不能再送 syslog，否则面板「运行日志」还是刷屏。
if sed -n '/panel_log() {/,/^\t}/p' "$INIT" | grep -q '|| return 0'; then
	ok "a merged panel log line is not forwarded to syslog either"
else
	bad "panel log lines are forwarded to syslog even when merged"
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

# ── 自动附加 ?flag=singbox（需求第 51 条）────────────────────────────────
# 机场按 UA / 查询参数决定返回哪种格式：用户填的地址给 base64、节点少一截，
# 追加 ?flag=singbox 才给 sing-box 专用 JSON（2026-10-28 实测 SNY 11→31、
# PKM 31→37、YU 56→82）。但不能无脑加（NB 实测 24→24 不认这个参数），
# 更不能改写 uci 里的地址——md5(原始 url) 是节点归属键，改了整批节点会
# 重新归属、面板立刻 0/0（0.2.9 第 39 条事故）。
NODEJS="$PKG/htdocs/luci-static/resources/view/homeproxy/node.js"
if grep -A 6 "form.Flag, 'auto_flag'" "$NODEJS" | grep -q "o.default = '1'"; then
	ok "the auto-flag switch exists and defaults to enabled"
else
	bad "the auto-flag switch is missing or does not default to enabled"
fi

# rmempty=false 是这条开关能不能关掉的关键：少了它，取消勾选会把键整个
# 删掉，脚本读不到就按「开启」处理，用户看到的是「关了还在加参数」。
if grep -A 6 "form.Flag, 'auto_flag'" "$NODEJS" | grep -q 'o.rmempty = false'; then
	ok "unchecking the auto-flag switch persists an explicit 0"
else
	bad "the auto-flag switch deletes its key on uncheck, so it can never be disabled"
fi

if grep -q "auto_flag_option = uci.get(uciconfig, ucisubscription, 'auto_flag')" "$SUB_UC" \
   && grep -q 'function auto_flag_enabled' "$SUB_UC"; then
	ok "subscription updates read the auto-flag switch"
else
	bad "subscription updates ignore the auto-flag switch"
fi

# 老配置里没有这个键：必须按开启处理，否则这次改动对老用户完全不生效。
if grep -q 'if (isEmpty(auto_flag_option))' "$SUB_UC" \
   && grep -q 'return true;' "$SUB_UC"; then
	ok "a config without the auto-flag key is treated as enabled"
else
	bad "a missing auto-flag key would silently disable the feature"
fi

if grep -q 'choose_subscription_body(url, res)' "$SUB_UC"; then
	ok "the subscription body goes through the flag probe before parsing"
else
	bad "the flag probe is never applied to the fetched body"
fi

# 用户自己已经写了 flag：既不重复加也不再探测。
if grep -q "index(url, 'flag=') >= 0" "$SUB_UC"; then
	ok "a URL that already carries flag= is left alone"
else
	bad "the probe would append a second flag= to a hand-written URL"
fi

# 已经是 JSON 说明机场按 sing-box 格式给了，不该再白抓一次。
if grep -q "head === '{' || head === '\[" "$SUB_UC"; then
	ok "a body that is already JSON skips the extra probe request"
else
	bad "the probe fires even when the airport already returns JSON"
fi

# 只有节点数确实变多才采用；没变多就静默丢弃（NB 那类不认参数的机场）。
if grep -q 'if (length(alternative_nodes) <= length(nodes))' "$SUB_UC"; then
	ok "the flagged body is only used when it actually parses into more nodes"
else
	bad "the probe would adopt a flagged body that is not better"
fi

# 判据必须「真解析一遍」，绝不能数正文里 `"type"` 出现几次：WS 这家机场的
# sing-box 格式是空壳（outbounds 里只有 selector / urltest / direct，一个
# 节点都没有），字面上却有 9 个 "type"，而它的默认格式只有 4 个真节点。
# 粗数会得到 9 > 4 的假阳，把能用的 4 个换成 0 个 —— 2026-10-28 真机翻车。
if grep -q 'function parse_subscription_nodes' "$SUB_UC" \
   && ! grep -q 'body_node_count' "$SUB_UC"; then
	ok "the probe compares real parsed node counts, not a raw token count"
else
	bad "the probe compares a raw token count and can prefer an empty sing-box shell"
fi

# 探测时已经解析过的正文要复用，别为了比较再解析一遍。
if grep -q 'const chosen = choose_subscription_body(url, res)' "$SUB_UC" \
   && grep -q 'let nodes = chosen.nodes ?? parse_subscription_nodes(res)' "$SUB_UC"; then
	ok "the chosen body is parsed once and reused"
else
	bad "the chosen body is parsed twice (or never)"
fi

# 日志要说清「哪个订阅被自动加了参数」，所以必须带订阅名 + 域名，且是中文。
if grep -q '自动附加 ?flag=singbox 后 %d 个' "$SUB_UC" \
   && grep -q 'subscription_display_name(url), url_host_part(url)' "$SUB_UC"; then
	ok "the log names the subscription and its host when the flag is applied"
else
	bad "the log does not say which subscription got the flag"
fi

# 界面上显示的地址必须还是用户填的那个：脚本不许往 subscription_url 写回。
if grep -q "uci.set(uciconfig, ucisubscription, 'subscription_url'" "$SUB_UC"; then
	bad "the updater rewrites subscription_url, which breaks the node group hashes"
else
	ok "subscription_url in uci is never rewritten by the updater"
fi

# ── 重启服务：必须用 restart，不能 stop 紧跟 start ──────────────────────
# 每次 init_action 都是一次独立的 init.d 调用，各自去抢 rc.common 的 procd
# 锁（lock -w，没有超时）。只要 procd 触发器或面板同时在跑，stop 就无限等锁：
# 2026-10-28 现场卡在「Restarting service...」5 分钟，ps 里 stop 与 start
# 并存，只能 kill。restart 由 rc.common 在同一进程里 stop+start，只取一次锁。
if grep -q "init_action('homeproxy', 'restart')" "$SUB_UC"; then
	ok "the subscription updater restarts the service in one shot (no lock race)"
else
	bad "the subscription updater calls stop and start separately (deadlocks on the procd lock)"
fi

if grep -q "init_action('homeproxy', 'stop')" "$SUB_UC" \
   || grep -q "init_action('homeproxy', 'start')" "$SUB_UC"; then
	bad "the subscription updater still issues a separate stop/start"
else
	ok "no separate stop/start calls are left in the updater"
fi

# ── 0 节点时 DNS 不能指向不存在的出站 ───────────────────────────────────
# 清空节点后 dns.final 指向的自定义 DoH，detour 是「默认代理」，而那个
# selector 已不存在 → 整个局域网解析不了任何域名（nslookup 只回 No answer），
# 订阅也就永远拉不回来。生成器必须把所有悬空引用指回 direct-out。
GEN_JS="$PKG/root/etc/homeproxy/scripts/generate_client.uc"
if grep -q 'function ensure_outbound_refs' "$GEN_JS" \
   && grep -q 'ensure_outbound_refs(config)' "$GEN_JS"; then
	ok "the client generator repairs dangling outbound references"
else
	bad "a config without nodes keeps DNS/route refs to outbounds that do not exist"
fi

# 三处引用都要覆盖：route.final、route.rules[].outbound、dns.servers[].detour。
if grep -q "config.route.final = 'direct-out'" "$GEN_JS" \
   && grep -q "rule.outbound = 'direct-out'" "$GEN_JS" \
   && grep -q "server.detour = 'direct-out'" "$GEN_JS"; then
	ok "route final, rule targets and DNS detours all fall back to direct-out"
else
	bad "the reference repair misses route rules or DNS detours"
fi

# 修复必须发生在写盘之前，否则改的是内存里的副本、落盘的还是坏配置。
if awk '/ensure_outbound_refs\(config\);/{f=1} /writefile\(RUN_DIR \+ .\/sing-box-c.json/{print (f?"ok":"late")}' "$GEN_JS" | grep -q '^ok$'; then
	ok "the repair runs before the config is written to /var/run"
else
	bad "the repair runs after the config was already written"
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
