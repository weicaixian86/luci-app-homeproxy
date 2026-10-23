#!/bin/sh
# Static + behavioural checks for luci-app-homeproxy.
#
# Runs everything that can be verified without an OpenWrt SDK:
#   - JavaScript syntax            (node --check)
#   - shell syntax                 (sh -n)
#   - JSON / workflow YAML         (python)
#   - ucode syntax, approximated   (strip imports + wrap + node --check)
#   - gettext catalog consistency  (tools/tests/pocheck.py)
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

FAILED=0
CHECKS=0

section() { printf '\n== %s ==\n' "$1"; }
ok()      { CHECKS=$((CHECKS + 1)); printf '  OK   %s\n' "$1"; }
bad()     { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
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
	if sh -n "$f" >"$WORK/sh.err" 2>&1; then
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

# ----------------------------------------------------------------- summary
printf '\n----------------------------------------\n'
if [ "$FAILED" -eq 0 ]; then
	printf 'ALL CHECKS PASSED (%d checks)\n' "$CHECKS"
	exit 0
fi

printf 'FAILED: %d of %d checks\n' "$FAILED" "$CHECKS"
exit 1
