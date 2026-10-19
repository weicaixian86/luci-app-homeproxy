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
	mkdir -p "$RUN_DIR" 2>/dev/null

	if command -v nohup >/dev/null 2>&1; then
		nohup /bin/sh "$0" >/dev/null 2>&1 &
	elif command -v setsid >/dev/null 2>&1; then
		setsid /bin/sh "$0" >/dev/null 2>&1 &
	else
		/bin/sh "$0" >/dev/null 2>&1 &
	fi

	exit 0
fi
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
/bin/sh "$CORE_SCRIPT" update > "$OUT_FILE" 2>&1
rc=$?

echo "$rc" > "$RC_FILE" 2>/dev/null
exit 0
