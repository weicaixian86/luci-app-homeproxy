#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Runtime download / install of the reF1nd sing-box core for HomeProxy.
#
# HomeProxy is now shipped as an architecture-independent LuCI package
# (LUCI_PKGARCH:=all). It does NOT bundle any single-arch sing-box binary.
# Instead, this script detects the device architecture at runtime and fetches
# the matching reF1nd sing-box build, verifies its SHA-256 when a checksum is
# published, and installs it to /usr/bin/sing-box.
#
# reF1nd/sing-box-releases currently publishes Linux musl builds for:
#   - x86_64  -> linux-amd64-musl
#   - aarch64 -> linux-arm64-musl
# Other architectures (armv7, arm, mips, mipsel) are not published yet; for
# those the script logs a clear notice and leaves any already-installed binary
# in place (the author may add more builds later).
#
# Download methodology follows luci-app-vnt2cli:
#   - curl is the preferred downloader, with --retry 2 inside a single mirror;
#   - if a mirror fails, fail over to the next source (gh-proxy -> github);
#   - the download cache is cleared before every download;
#   - SHA-256 is verified when an official checksum can be located.

set -u

HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"
CORE_BIN="/usr/bin/sing-box"
STATE_FILE="${HP_DIR}/core.state"
DOWNLOAD_LOG="${RUN_DIR}/core_download.log"
CACHE_DIR="/tmp/homeproxy-core-dl"

# Pinned reF1nd release. Only the leading 'v' differs between the git tag and
# the download path; the version string itself is reused verbatim.
REFIND_REPO="reF1nd/sing-box-releases"
REFIND_TAG="v1.14.3-reF1nd"
REFIND_VERSION="1.14.3-reF1nd"

# Accelerator prefixes. Order matters: a reachable-but-slow source still burns
# its whole --max-time before we fail over, so the fastest wins the front slot.
#
# Ordered by RELIABILITY first, throughput second. github.com direct is the
# fastest when it works (~89 KB/s measured on the target router on 2026-10-19,
# vs ~22 KB/s for gh-proxy.com and ~12 KB/s for ghproxy.net) but it is also
# the least dependable: from mainland China it is frequently blocked outright
# or drops mid-transfer, and a stalled direct connection burns the whole
# --max-time before failing over. Peak throughput on a good day is worth less
# than actually completing the download, so the mirrors lead and github.com is
# tried last as the authoritative fallback.
#
# gh-proxy.com leads because it was reachable on every network we measured
# (router: ~22 KB/s; dev machine: ~114 KB/s on the 34 MB core).
GH_PROXY_PREFIXES="https://gh-proxy.com/ https://ghproxy.net/ https://ghfast.top/ https://hub.gitmirror.com/ https://gh.llkk.cc/ https://github.moeyy.xyz/"

# NOTE: do NOT source /lib/functions.sh here. This helper does not use any of
# its functions, and under `set -u` sourcing it is fatal: if that library
# references a single undefined variable (which varies by firmware, e.g.
# iStoreOS), the whole shell exits with "parameter not set". Because the line
# was written as `. /lib/functions.sh 2>/dev/null || true`, the error was
# swallowed and `|| true` could not help (set -u aborts the shell, not a
# command), so the script died silently here: zero output, empty log, and
# `status` returned nothing — which made the UI look like "download failed".

# ---------- logging ----------
ensure_log() {
	mkdir -p "${RUN_DIR}" 2>/dev/null
}

log_download() {
	ensure_log
	printf '%s download : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${DOWNLOAD_LOG}" 2>/dev/null
}

# ---------- ELF / arch detection (BusyBox safe) ----------
is_elf_binary() {
	local bin="$1" magic expected
	[ -s "$bin" ] || return 1
	magic="$(dd if="$bin" bs=1 count=4 2>/dev/null)"
	expected="$(printf '\177ELF')"
	[ "$magic" = "$expected" ]
}

# Read the 32-bit little-endian EI_DATA byte (offset 5) of /proc/self/exe to
# decide MIPS endianness. 1 = little-endian (mipsel), 2 = big-endian (mips).
detect_mips_endian() {
	local ei_data
	ei_data="$(dd if=/proc/self/exe bs=1 skip=5 count=1 2>/dev/null)"
	if [ "$ei_data" = "$(printf '\001')" ]; then
		echo "mipsel"
	else
		echo "mips"
	fi
}

read_elf_eflags_le() {
	local f="$1" b0 b1 b2 b3 v
	[ -r "$f" ] || { echo 0; return; }
	is_elf_binary "$f" >/dev/null 2>&1 || { echo 0; return; }
	# `od` is missing on some minimal BusyBox builds (e.g. iStoreOS). Its stderr
	# must be silenced too, otherwise "od: not found" leaks into the captured
	# output of every caller and pollutes the LuCI log.
	b0="$(dd if="$f" bs=1 skip=24 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -dc '0-9a-fA-F')"
	b1="$(dd if="$f" bs=1 skip=25 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -dc '0-9a-fA-F')"
	b2="$(dd if="$f" bs=1 skip=26 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -dc '0-9a-fA-F')"
	b3="$(dd if="$f" bs=1 skip=27 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -dc '0-9a-fA-F')"
	b0="${b0:-0}"; b1="${b1:-0}"; b2="${b2:-0}"; b3="${b3:-0}"
	[ -z "${b0}${b1}${b2}${b3}" ] && { echo 0; return; }
	v=$(( 0x$b0 + (0x$b1 << 8) + (0x$b2 << 16) + (0x$b3 << 24) ))
	echo "$v"
}

# Decide ARM float ABI from the ELF e_flags of a system binary.
detect_arm_float() {
	local f flags eabi
	for f in /proc/self/exe /bin/busybox /lib/libc.so* /bin/sh /sbin/init /lib/ld-musl-arm*.so.1; do
		[ -r "$f" ] || continue
		flags="$(read_elf_eflags_le "$f")"
		eabi=$(( (flags >> 24) & 0xFF ))
		[ "$eabi" -ge 1 ] || continue
		if [ $((flags & 0x400)) -ne 0 ]; then
			echo "musleabihf"; return 0
		elif [ $((flags & 0x200)) -ne 0 ]; then
			echo "musleabi"; return 0
		fi
	done
	echo ""
}

# Detect device architecture. Returns one of:
#   x86_64 | aarch64 | armv7-musleabihf | armv7-musleabi |
#   arm-musleabihf | arm-musleabi | mips | mipsel | unsupported
detect_arch_name() {
	local mach package_arch arm_family arm_abi
	mach="$(uname -m 2>/dev/null)"
	package_arch="$(opkg print-architecture 2>/dev/null | awk '$2 != "all" && $2 != "noarch" {print $2; exit}')"
	# OpenWrt 25.12+ switched to apk; opkg may be absent there. Fall back to
	# apk's arch query so the package_arch heuristics below still apply.
	[ -n "$package_arch" ] || package_arch="$(apk --print-arch 2>/dev/null)"

	case "$mach" in
		x86_64|amd64)
			echo "x86_64"; return 0 ;;
		aarch64|arm64)
			echo "aarch64"; return 0 ;;
		armv7*)
			arm_family="armv7" ;;
		armv6*|arm*)
			arm_family="arm" ;;
		mipsel*)
			echo "mipsel"; return 0 ;;
		mips*)
			detect_mips_endian; return 0 ;;
	esac

	if [ -n "$arm_family" ]; then
		arm_abi="$(detect_arm_float)"
		[ -z "$arm_abi" ] && {
			if [ -e /lib/ld-musl-armhf.so.1 ] || [ -e /lib/ld-musl-armhf.so.1.* ]; then
				arm_abi="musleabihf"
			elif [ -e /lib/ld-musl-arm.so.1 ] || [ -e /lib/ld-musl-arm.so.1.* ]; then
				arm_abi="musleabi"
			else
				case "$package_arch" in
					*eabihf*|*hard*|*hf*|*neon*|*vfp*) arm_abi="musleabihf" ;;
					*eabi*|*soft*) arm_abi="musleabi" ;;
				esac
			fi
		}
		[ -n "$arm_abi" ] && { echo "${arm_family}-${arm_abi}"; return 0; }
		echo "unsupported"; return 0
	fi

	case "$package_arch" in
		*x86_64*|*amd64*) echo "x86_64" ;;
		*aarch64*|*arm64*) echo "aarch64" ;;
		*mipsel*) echo "mipsel" ;;
		*mips*) detect_mips_endian ;;
		*) echo "unsupported" ;;
	esac
}

# Detect x86-64-v3 (AVX2 / BMI2 / FMA / F16C). reF1nd ships a dedicated amd64v3
# build for this micro-architecture level; preferring it on capable CPUs yields
# better performance, while the baseline amd64 build remains as a fallback. Each
# flag is checked independently (no ordering assumption, /proc/cpuinfo lists
# them alphabetically with varying gaps).
cpu_supports_x86_64_v3() {
	local f
	f="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)"
	[ -n "$f" ] || return 1
	case " $f " in *" avx2 "*) ;; *) return 1 ;; esac
	case " $f " in *" bmi2 "*) ;; *) return 1 ;; esac
	case " $f " in *" fma "*)  ;; *) return 1 ;; esac
	case " $f " in *" f16c "*) ;; *) return 1 ;; esac
	return 0
}

# Return the ordered candidate asset filenames for an architecture (space
# separated). On x86_64, when the CPU advertises x86-64-v3 we prefer the faster
# amd64v3 build and fall back to the baseline amd64 build (which runs on every
# x86_64 CPU); otherwise only the baseline amd64 build is used.
asset_candidates_for_arch() {
	local arch="$1"
	case "$arch" in
		x86_64)
			if cpu_supports_x86_64_v3; then
				echo "sing-box-${REFIND_VERSION}-linux-amd64v3-musl.tar.gz sing-box-${REFIND_VERSION}-linux-amd64-musl.tar.gz"
			else
				echo "sing-box-${REFIND_VERSION}-linux-amd64-musl.tar.gz"
			fi
			;;
		aarch64)
			echo "sing-box-${REFIND_VERSION}-linux-arm64-musl.tar.gz"
			;;
		*)
			return 1
			;;
	esac
}

# ---------- SHA-256 ----------
sha256_of() {
	local f="$1"
	[ -s "$f" ] || return 1
	command -v sha256sum >/dev/null 2>&1 || return 1
	sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# ---------- downloader ----------
get_downloader() {
	if command -v curl >/dev/null 2>&1; then
		echo "curl"; return 0
	elif command -v wget >/dev/null 2>&1; then
		echo "wget"; return 0
	fi
	return 1
}

# Best-effort NTP correction before downloading. A wrong-but-plausible clock
# (e.g. a few days/weeks behind, yet still a "normal" year) is invisible to the
# year-only clock_looks_unsynced heuristic in the init script, but it can still
# break HTTPS certificate validation (curl exit 60) and thus the core download.
# We attempt a bounded one-shot NTP step here so a mis-set clock gets a chance
# to correct itself right before we hit GitHub. Failure is non-fatal: if no NTP
# server is reachable, we proceed and the download fails with a clear curl
# return code. Bounded to ~10s so an unreachable server never hangs the update.
sync_time() {
	local ntpd_bin servers s args=''
	ntpd_bin="$(command -v ntpd 2>/dev/null)" || return 0
	servers="$(uci -q get system.ntp.server 2>/dev/null | tr '\n' ' ')"
	if [ -n "$servers" ]; then
		# Build the "-p <server>" args without relying on `printf --`, which
		# some minimal BusyBox printf builds do not special-case; a plain loop
		# is unambiguously ash-safe.
		for s in $servers; do
			args="$args -p $s"
		done
		# shellcheck disable=SC2086
		$ntpd_bin -n -q $args 2>/dev/null &
	else
		# No servers configured in UCI: fall back to public pools so the
		# one-shot sync still has something to query on a freshly flashed box.
		$ntpd_bin -n -q -p time1.aliyun.com -p pool.ntp.org 2>/dev/null &
	fi
	local pid=$!
	local i=0
	while [ "$i" -lt 10 ]; do
		sleep 1
		i=$((i + 1))
		kill -0 "$pid" 2>/dev/null || return 0
	done
	return 0
}

# Produce the ordered list of candidate URLs for a github release asset.
# Auto mode tries gh-proxy first, then github (failover).
candidate_urls() {
	local url="$1" mirror="${2:-auto}" prefix

	[ "$mirror" = "github" ] && { printf '%s\n' "$url"; return 0; }

	# Mirrors FIRST, direct GitHub LAST. Direct is faster when it connects
	# (~89 KB/s vs ~22 KB/s) but unreliable — usually unreachable from
	# mainland China, and a half-open connection stalls until --max-time
	# expires. Trying it first would add a long dead wait before every
	# failover, so it stays the authoritative fallback.
	for prefix in $GH_PROXY_PREFIXES; do
		printf '%s\n' "${prefix}${url}"
	done
	printf '%s\n' "$url"
}

# Download a file with curl --retry 2 inside each mirror, then fail over.
# Usage: download_file SOURCE_URL OUTPUT_PATH PURPOSE [MIRROR]
download_file() {
	local url="$1" out="$2" purpose="${3:-generic}" mirror="${4:-auto}"
	local downloader rc actual_url connect_timeout

	downloader="$(get_downloader "$purpose")" || return 1

	if [ "$purpose" = "asset" ]; then
		connect_timeout=15
	else
		connect_timeout=10
	fi

	# Timeouts are expressed as "no useful progress" rather than "total
	# elapsed", because a total budget cannot be chosen sanely here: the
	# release tarball is 34 MB and the mirrors run anywhere from ~22 KB/s to
	# ~130 KB/s, i.e. 4 to 26 minutes for one healthy download. The old
	# --max-time 240 cut off every attempt past ~5 MB, so the core could
	# never be installed through a working mirror at all — the download was
	# killed mid-transfer and reported as a mirror failure.
	#
	# --speed-limit/--speed-time instead abort only when the transfer is too
	# slow to be worth waiting for. The threshold is 6 KB/s, not "is it
	# completely dead": a 34 MB body at 6 KB/s already takes 96 minutes, so
	# anything slower is better spent trying the next mirror than sitting on
	# a link that will need hours. Measured on the target router, throughput
	# ranged from 3.2 KB/s to 8.5 MB/s for the same URL depending on whether
	# the edge node had it cached, so a 1 KB/s floor (the old value) would
	# happily wait out a 3 KB/s trickle for the full --max-time and then give
	# up anyway.
	#
	# --max-time 7200 leaves enough room for a 6 KB/s transfer to actually
	# finish (96 min) while still bounding a pathological trickle.
	#
	# --retry-all-errors is deliberately NOT used: it needs curl >= 7.71 and
	# an older build (common on embedded OpenWrt images) rejects the flag
	# outright, which would fail every single download. Plain --retry already
	# covers transient timeouts, connection failures and 5xx answers.
	for actual_url in $(candidate_urls "$url" "$mirror"); do
		# A 34 MB body at mirror speeds takes anywhere from 4 to 26 minutes,
		# and nothing is logged until it finishes. Without this line the UI
		# (which shows the tail of this log) looks frozen for the whole
		# download and the user kills it halfway through.
		log_download "正在下载（源：${actual_url}）"
		case "$downloader" in
			curl)
				curl -fsSL --connect-timeout "$connect_timeout" \
					--speed-limit 6144 --speed-time 60 --max-time 7200 \
					--retry 2 --retry-delay 3 \
					-A "luci-app-homeproxy" \
					-o "$out" "$actual_url" >/dev/null 2>&1
				rc=$?
				;;
			wget)
				# BusyBox wget is common on OpenWrt and rejects some GNU-only
				# long options, so only universally supported flags are used.
				# Its -T is already a socket-inactivity timeout (not a total
				# budget), which is the semantics we want for a 34 MB body.
				wget -q -T 60 -O "$out" "$actual_url" >/dev/null 2>&1
				rc=$?
				;;
			*)
				return 1
				;;
		esac

		if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
			if [ "$purpose" = "asset" ]; then
				# Validate that the mirror really returned a gzip-compressed
				# tarball. A misbehaving mirror may answer with an HTML error
				# page and HTTP 200, so the content must be checked.
				#
				# IMPORTANT: do NOT check the gzip magic via `od`. Many minimal
				# BusyBox builds (e.g. some iStoreOS images) ship WITHOUT `od`;
				# the old `od`-based check then produced an empty string, which
				# never equals "1f8b", so EVERY valid download was rejected as
				# "not gzip" and deleted — making the core impossible to install
				# even with a perfectly healthy mirror. `tar -tzf` is portable
				# (busybox tar handles -z) and validates the archive for real.
				if ! tar -tzf "$out" >/dev/null 2>&1; then
					log_download "下载内容不是有效的 tar.gz 包（疑似错误页面），继续尝试下一个源：${actual_url}"
					rm -f "$out"
					continue
				fi
			fi
			log_download "下载成功：${actual_url}"
			return 0
		fi
		log_download "下载失败（返回码 ${rc}）：${actual_url}"
		rm -f "$out"
	done

	return 1
}

# Best-effort SHA-256 verification.
#
# IMPORTANT: reF1nd does NOT publish per-asset checksums. Verified against the
# release asset lists of both v1.14.3-reF1nd and v1.15.0-alpha.11-reF1nd —
# neither contains a `.sha256`, `sha256sums` or `checksums` asset. The previous
# implementation nevertheless requested `<asset>.sha256` through every mirror:
# 7 candidate URLs x 3 curl attempts each (--retry 2, --retry-delay 5), i.e.
# minutes of pure latency on EVERY install, plus 7 bogus "download failed" log
# lines that buried the real error when something actually went wrong.
# Checksum verification is therefore opt-in: place a `<asset>.sha256` file in
# /etc/homeproxy/ (first whitespace-separated field = hex digest) and it will
# be honoured; otherwise the install proceeds without it.
verify_sha256() {
	local asset="$1" file="$2" expected='' sum
	local sum_file="${HP_DIR}/${asset}.sha256"

	if [ -f "$sum_file" ]; then
		expected="$(awk '{print $1}' "$sum_file" 2>/dev/null | head -n1)"
	else
		log_download "reF1nd 未发布 ${asset} 的 SHA256 校验和（该 release 不含 .sha256 文件），跳过校验"
		return 0
	fi

	# Guard against a malformed digest file: only a real 64-character hex
	# digest counts as a checksum.
	case "$expected" in
		*[!0-9a-fA-F]*) expected='' ;;
	esac
	[ ${#expected} -eq 64 ] || expected=''

	if [ -z "$expected" ]; then
		log_download "未找到 ${asset} 的官方 SHA256 校验和，跳过校验（作者后续可能提供）"
		return 0
	fi

	sum="$(sha256_of "$file")"
	if [ "$sum" = "$expected" ]; then
		log_download "SHA256 校验通过：${sum}"
		return 0
	fi

	log_download "SHA256 校验失败：期望 ${expected}，实际 ${sum}（拒绝安装）"
	return 1
}

# ---------- cache / install ----------
clear_cache() {
	rm -rf "${CACHE_DIR}"
	mkdir -p "${CACHE_DIR}"
}

record_state() {
	local version="$1" arch="$2" dir tmp
	dir="$(dirname "$STATE_FILE")"
	mkdir -p "$dir" 2>/dev/null
	tmp="${STATE_FILE}.$$"
	{
		echo "version=${version}"
		echo "arch=${arch}"
		echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE" 2>/dev/null
}

installed_core_version() {
	[ -x "$CORE_BIN" ] || return 1
	"$CORE_BIN" version 2>/dev/null | sed -n 's/^sing-box version //p' | head -n1
}

extract_and_install() {
	local archive="$1" tmp_dir bin rc

	tmp_dir="$(mktemp -d "${CACHE_DIR}/extract.XXXXXX")" || return 1
	tar -xzf "$archive" -C "$tmp_dir" >/dev/null 2>&1 || { rm -rf "$tmp_dir"; return 1; }

	bin="$(find "$tmp_dir" -type f -name sing-box 2>/dev/null | head -n1)"
	if [ -z "$bin" ]; then
		log_download "压缩包内未找到 sing-box 可执行文件"
		rm -rf "$tmp_dir"
		return 1
	fi

	chmod 0755 "$bin" 2>/dev/null
	# Health check: a wrong-arch binary (e.g. amd64v3 on a non-v3 CPU) would
	# SIGILL here. Refuse to install so the caller can fall back to the next
	# candidate (the baseline amd64 build) instead of leaving a dead binary.
	if ! "$bin" version >/dev/null 2>&1; then
		# NOTE: log the archive path, not `${asset}`. `asset` lives in the
		# caller (download_and_install); under `set -u` referencing it here
		# is only safe when the caller happens to have set it, and the
		# manual-archive path can reach this function with no such variable.
		log_download "内核健康检查未通过（可能架构不匹配或缺少运行依赖），不安装此候选：${archive}"
		rm -rf "$tmp_dir"
		return 1
	fi

	if ! mv -f "$bin" "$CORE_BIN"; then
		rm -rf "$tmp_dir"
		return 1
	fi
	chmod 0755 "$CORE_BIN" 2>/dev/null
	chown root:root "$CORE_BIN" 2>/dev/null
	rm -rf "$tmp_dir"
	return 0
}

# Download and install the matching reF1nd core for the given arch/asset.
download_and_install() {
	local arch="$1" asset="$2"
	local asset_url rc

	clear_cache

	asset_url="https://github.com/${REFIND_REPO}/releases/download/${REFIND_TAG}/${asset}"
	log_download "开始下载 reF1nd 内核：${asset}（架构 ${arch}）"

	if ! download_file "$asset_url" "${CACHE_DIR}/${asset}" asset auto; then
		log_download "下载失败：${asset}（已尝试 gh-proxy 与 github 故障转移）"
		return 1
	fi

	log_download "下载完成，开始校验与安装"

	if ! verify_sha256 "$asset" "${CACHE_DIR}/${asset}"; then
		rm -f "${CACHE_DIR}/${asset}"
		return 1
	fi

	if ! extract_and_install "${CACHE_DIR}/${asset}"; then
		log_download "安装失败：${asset}"
		return 1
	fi

	record_state "$REFIND_VERSION" "$arch"
	log_download "reF1nd 内核安装成功：$($CORE_BIN version 2>/dev/null | head -n1)"
	return 0
}

# Ensure a usable reF1nd core is present. Returns 0 when /usr/bin/sing-box
# exists (correct version, or at least an existing binary), 1 otherwise.
ensure_core() {
	local arch candidates asset cur_ver

	sync_time
	arch="$(detect_arch_name)"
	log_download "检测到设备架构：${arch}"

	if [ "$arch" = "unsupported" ]; then
		log_download "当前架构暂不支持，reF1nd 尚未提供该架构二进制（作者后续可能提供）"
		[ -x "$CORE_BIN" ] && return 0
		return 1
	fi

	if ! candidates="$(asset_candidates_for_arch "$arch")"; then
		log_download "架构 ${arch} 暂无可下载的 reF1nd 二进制程序（作者后续可能提供）"
		[ -x "$CORE_BIN" ] && return 0
		return 1
	fi

	cur_ver="$(installed_core_version)"
	if [ -x "$CORE_BIN" ] && [ "$cur_ver" = "$REFIND_VERSION" ]; then
		log_download "reF1nd 内核已是最新版本：${cur_ver}"
		return 0
	fi

	for asset in $candidates; do
		if download_and_install "$arch" "$asset"; then
			return 0
		fi
		log_download "候选内核 ${asset} 下载/安装失败，尝试下一个候选（若存在）"
	done

	# Download failed: fall back to any existing binary so the service can still
	# attempt to run (it may be a stale but working version).
	if [ -x "$CORE_BIN" ]; then
		log_download "reF1nd 内核下载/更新失败，继续使用已有内核（版本 $(installed_core_version)）"
		return 0
	fi

	# Last resort: an archive placed manually by the user, e.g. copied over
	# SSH when every mirror is unreachable:
	#   scp sing-box-*-linux-amd64-musl.tar.gz root@router:/etc/homeproxy/sing-box.tar.gz
	if [ -f "${HP_DIR}/sing-box.tar.gz" ]; then
		log_download "尝试安装手动放置的内核：${HP_DIR}/sing-box.tar.gz"
		if extract_and_install "${HP_DIR}/sing-box.tar.gz"; then
			record_state "$REFIND_VERSION" "$arch"
			log_download "手动放置的内核安装成功：$($CORE_BIN version 2>/dev/null | head -n1)"
			return 0
		fi
		log_download "手动放置的内核安装失败：${HP_DIR}/sing-box.tar.gz"
	fi

	log_download "reF1nd 内核缺失且下载失败，无法启动服务"
	log_download "提示：若系统时间未同步（NTP 未校时），HTTPS 证书校验会失败（curl 返回码 60）；请先确认 date 与真实时间一致"
	return 1
}

# Force a re-download regardless of the installed version.
update_core() {
	local arch candidates asset
	sync_time
	arch="$(detect_arch_name)"
	if [ "$arch" = "unsupported" ]; then
		log_download "当前架构暂不支持，reF1nd 尚未提供该架构二进制"
		echo "unsupported"
		return 1
	fi
	if ! candidates="$(asset_candidates_for_arch "$arch")"; then
		log_download "架构 ${arch} 暂无可下载的 reF1nd 二进制程序"
		echo "no_asset"
		return 1
	fi
	for asset in $candidates; do
		if download_and_install "$arch" "$asset"; then
			echo "ok"
			return 0
		fi
		log_download "候选内核 ${asset} 下载/安装失败，尝试下一个候选（若存在）"
	done

	# Same manual-archive fallback as ensure_core(), so the UI button can also
	# recover when no mirror is reachable.
	if [ -f "${HP_DIR}/sing-box.tar.gz" ] && extract_and_install "${HP_DIR}/sing-box.tar.gz"; then
		record_state "$REFIND_VERSION" "$arch"
		echo "ok"
		return 0
	fi

	log_download "手动更新失败：所有镜像及手动放置的内核均未成功"
	log_download "提示：若系统时间未同步（NTP 未校时），HTTPS 证书校验会失败（curl 返回码 60）；请先确认 date 与真实时间一致"
	echo "failed"
	return 1
}

# Print machine-readable status for the LuCI backend.
print_status() {
	local arch cur_ver candidates asset
	arch="$(detect_arch_name)"
	cur_ver="$(installed_core_version)"
	# Use the same candidate logic as ensure/update so the UI reflects what
	# would actually be downloaded (on x86-64-v3 capable CPUs the preferred
	# first candidate is the amd64v3 build, with baseline amd64 as fallback).
	if candidates="$(asset_candidates_for_arch "$arch")"; then
		asset_available="1"
		asset="${candidates%% *}"
	else
		asset_available="0"
		asset=""
	fi
	[ -z "$cur_ver" ] && cur_ver="-"
	echo "arch=${arch}"
	echo "asset_available=${asset_available}"
	echo "asset=${asset}"
	echo "installed_version=${cur_ver}"
	echo "refind_version=${REFIND_VERSION}"
}

main() {
	local cmd="${1:-ensure}"
	# Start marker: lets us tell "the helper never ran at all" (e.g. a fatal
	# parse error before this point, or the file missing) apart from "it ran
	# but failed early". On a fresh boot /var/run/homeproxy may not exist yet,
	# so ensure_log() inside log_download creates it first.
	log_download "==== 脚本启动：命令=${cmd} ===="
	case "$cmd" in
		ensure)  ensure_core ;;
		update)  update_core ;;
		status)  print_status ;;
		*)
			echo "Usage: $0 {ensure|update|status}" >&2
			exit 2
			;;
	esac
}

main "$@"
