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

# Mirror prefixes tried in order before falling back to github.com itself.
# GitHub release downloads are frequently unreachable from mainland China, so
# several public accelerators are attempted first; the list is kept in one
# place so it is easy to extend.
GH_PROXY_PREFIXES="https://gh-proxy.com/ https://ghproxy.net/ https://ghfast.top/ https://hub.gitmirror.com/ https://gh.llkk.cc/ https://github.moeyy.xyz/"

. /lib/functions.sh 2>/dev/null || true

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
	b0="$(dd if="$f" bs=1 skip=24 count=1 2>/dev/null | od -An -tx1 | tr -dc '0-9a-fA-F')"
	b1="$(dd if="$f" bs=1 skip=25 count=1 2>/dev/null | od -An -tx1 | tr -dc '0-9a-fA-F')"
	b2="$(dd if="$f" bs=1 skip=26 count=1 2>/dev/null | od -An -tx1 | tr -dc '0-9a-fA-F')"
	b3="$(dd if="$f" bs=1 skip=27 count=1 2>/dev/null | od -An -tx1 | tr -dc '0-9a-fA-F')"
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

	for prefix in $GH_PROXY_PREFIXES; do
		printf '%s\n' "${prefix}${url}"
	done
	printf '%s\n' "$url"
}

# Download a file with curl --retry 2 inside each mirror, then fail over.
# Usage: download_file SOURCE_URL OUTPUT_PATH PURPOSE [MIRROR]
download_file() {
	local url="$1" out="$2" purpose="${3:-generic}" mirror="${4:-auto}"
	local downloader rc actual_url connect_timeout transfer_timeout

	downloader="$(get_downloader "$purpose")" || return 1

	case "$purpose" in
		asset)    connect_timeout=20; transfer_timeout=240 ;;
		checksum) connect_timeout=20; transfer_timeout=60 ;;
		*)        connect_timeout=10; transfer_timeout=30 ;;
	esac

	for actual_url in $(candidate_urls "$url" "$mirror"); do
		case "$downloader" in
			curl)
				curl -fsSL --connect-timeout "$connect_timeout" --max-time "$transfer_timeout" \
					--retry 2 --retry-delay 5 --retry-all-errors \
					-A "luci-app-homeproxy" \
					-o "$out" "$actual_url" >/dev/null 2>&1
				rc=$?
				;;
			wget)
				# BusyBox wget is common on OpenWrt and rejects some GNU-only
				# long options, so only universally supported flags are used.
				wget -q -T "$transfer_timeout" \
					-O "$out" "$actual_url" >/dev/null 2>&1
				rc=$?
				;;
			*)
				return 1
				;;
		esac

		if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
			if [ "$purpose" = "asset" ]; then
				local magic
				magic="$(dd if="$out" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
				# A misbehaving mirror may answer with an HTML error page and
				# HTTP 200; only a real gzip stream is accepted.
				if [ "$magic" != "1f8b" ]; then
					log_download "下载内容不是 gzip 压缩包（疑似错误页面），继续尝试下一个源：${actual_url}"
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

# Best-effort SHA-256 verification. reF1nd does not publish per-asset checksums
# for this release, so when no checksum can be located we log a warning and let
# the install proceed (rather than blocking it). If a checksum IS found and does
# not match, the install is aborted.
verify_sha256() {
	local asset="$1" file="$2" base sum_url expected='' sum
	base="${asset%.tar.gz}"
	sum_url="https://github.com/${REFIND_REPO}/releases/download/${REFIND_TAG}/${asset}.sha256"

	if download_file "$sum_url" "${CACHE_DIR}/${asset}.sha256" checksum auto; then
		expected="$(awk '{print $1}' "${CACHE_DIR}/${asset}.sha256" 2>/dev/null | head -n1)"
	fi

	# Mirrors may answer a missing checksum with an error page (HTTP 200), so
	# only a real 64-character hex digest is accepted as a checksum.
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
		log_download "内核健康检查未通过（可能架构不匹配或缺少运行依赖），不安装此候选：${asset}"
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
