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
# weicaixian86/luci-app-homeproxy（本仓库 Release, tag = 发布版本号如 0.1.01）发布打补丁的
# Linux musl 内核构建，文件名带发布版本号（1.14.3-refind_<发布版本>-linux-<架构>-musl），供运行时自动下载：
#   - x86_64  -> 1.14.3-refind_<发布版本>-linux-amd64-musl      （含 x86-64-v3 优先候选）
#   - aarch64 -> 1.14.3-refind_<发布版本>-linux-arm64-musl
#   - armv7*  -> 1.14.3-refind_<发布版本>-linux-armv7-musl
#   - mipsel* -> 1.14.3-refind_<发布版本>-linux-mipsle-musl      （仅小端 mips；大端 mips 暂无构建）
# armv5/armv6（arm-* 而非 armv7-*）与 大端 mips 暂不发布，脚本会给出明确提示并保留已有内核。
#
# Download methodology follows luci-app-vnt2cli:
#   - curl is the preferred downloader, with --retry 2 inside a single mirror;
#   - if a mirror fails, fail over to the next source (gh-proxy -> github);
#   - if EVERY source fails, stop the service for a moment and retry the whole
#     list over a real direct connection: while homeproxy runs, its own outbound
#     traffic is tproxy-hijacked into the selected proxy node, so a dead node
#     looks exactly like "all mirrors are down" (see core_direct_retry);
#   - the download cache is cleared before every download;
#   - SHA-256 is verified when an official checksum can be located.

set -u

# 显式固定 PATH：本脚本会被 init.d、LuCI（ubus）、install.sh 以不同环境调用，
# PATH 不全时 uci/awk/tar 之类的调用会静默失败（stderr 多被 /dev/null 吞掉）。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

HP_DIR="/etc/homeproxy"
RUN_DIR="/var/run/homeproxy"
CORE_BIN="/usr/bin/sing-box"
STATE_FILE="${HP_DIR}/core.state"
DOWNLOAD_LOG="${RUN_DIR}/core_download.log"
CACHE_DIR="/tmp/homeproxy-core-dl"

# 每个下载源的失败明细，形如 `gh-proxy.com=rc28/http000; github.com=rc6/http000`。
# 由 download_file() 累积、download_and_install() 汇总成最后一行日志。
# 必须在全局初始化：脚本带 `set -u`，函数里读未定义变量会直接退出。
# 两轮分开记：第一轮经代理劫持，第二轮是真直连，混在一起会让人以为试了 8 次。
DOWNLOAD_ATTEMPTS=""
DOWNLOAD_ATTEMPTS_PROXIED=""

# Pinned reF1nd release. Only the leading 'v' differs between the git tag and
# the download path; the version string itself is reused verbatim.
# NOTE: the shipped binary reports "<REFIND_VERSION>_<plugin-version>" (e.g.
# 1.14.3-reF1nd_0.1.3) so the UI can distinguish our patched build from the
# upstream reF1nd release. ensure_core() only compares the part before '_',
# hence REFIND_VERSION stays the plain base version on purpose.
REFIND_REPO="weicaixian86/luci-app-homeproxy"
REFIND_TAG="v1.14.3-reF1nd"
REFIND_VERSION="1.14.3-reF1nd"
# 发布标签同时充当两件事：Release 名（可能带 v 前缀）和内核压缩包的文件名
# 组件（构建时统一不带 v）。这里剥掉前缀单独存一份，asset 名一律用它，
# 这样发布时填 "v0.1.10" 还是 "0.1.10" 都不会找不到文件。
REFIND_ASSET_TAG="${REFIND_TAG#v}"
REFIND_ASSET_TAG="${REFIND_ASSET_TAG#V}"

# 「目标版本」= 下载安装后 `sing-box version` 会报告的完整版本串。
# CI 构建时会把 REFIND_TAG 改成本次发布标签（如 0.1.12），而内核二进制的
# ldflags 写的是 1.14.3-reF1nd_<发布标签>，所以这里也要带上下划线后缀，
# 否则 UI 会显示成 reF1nd 官方版本号，和已安装的版本对不上。
# 未走 CI（REFIND_TAG 仍是默认的 v1.14.3-reF1nd）时不拼后缀，
# 避免出现 1.14.3-reF1nd_1.14.3-reF1nd 这种串。
CORE_TARGET_VERSION="$REFIND_VERSION"
if [ "$(printf '%s' "$REFIND_ASSET_TAG" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$REFIND_VERSION" | tr 'A-Z' 'a-z')" ]; then
	CORE_TARGET_VERSION="${REFIND_VERSION}_${REFIND_ASSET_TAG}"
fi

# ---------- 内置完整性校验（发版时由 CI 注入） ----------
# 每个发布版本的内核压缩包 SHA256，由 .github/workflows/build-deploy.yml 在
# 编译完内核后 sed 写入下面五个变量（键为架构名）。之所以用「内置常量」而不是
# 从 Release 再下一个 .sha256：校验和若与压缩包走同一个镜像，镜像/中间人把
# 两者一起换掉就形同虚设；内置值随包发布，只信任本仓库的构建产物。
#
# 空值 = 该版本没有内置校验值（本地手工编译、或 REFIND_TAG 指向旧 release）。
# 此时按 CORE_SHA256_MISSING 处理：默认 warn（只告警不拦截），避免把内核更新
# 整条链路堵死；想严格起来就把下面改成 fail，或运行时用环境变量覆盖。
CORE_SHA256_AMD64=""
CORE_SHA256_AMD64V3=""
CORE_SHA256_ARM64=""
CORE_SHA256_ARMV7=""
CORE_SHA256_MIPSLE=""
CORE_SHA256_MISSING="${CORE_SHA256_MISSING:-warn}"   # warn=放行并告警；fail=拒绝安装

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
#
# 2026-10-28 现场复测（237，每个源只取 1 KB，避开 34 MB 全量下载）：
#   gh-proxy.com  206 可用      ghproxy.net  206 可用
#   ghfast.top    rc=28 超时    gh.llkk.cc   rc=28 超时
#   hub.gitmirror.com / github.moeyy.xyz  ——  nslookup 直接 NXDOMAIN，域名已注销
# 两个死域名已移除。留着的代价不只是浪费一次尝试：日志里会写
# `下载失败（返回码 6，HTTP 000）`，而返回码 6 是「域名解析不了」，
# 用户会误以为是自己路由器 DNS 或网络坏了，实际是我们的镜像列表过期了。
GH_PROXY_PREFIXES="https://gh-proxy.com/ https://ghproxy.net/ https://ghfast.top/ https://gh.llkk.cc/"

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

# ---------- 单实例互斥 ----------
# 内核安装会被三处触发：init.d 启动时的 ensure、LuCI「更新内核」、以及
# 定时/手动执行。两个进程同时下载会往同一个 /usr/bin/sing-box 交替写，
# 还会互相清空 ${CACHE_DIR}，最终可能装上一个只写了一半的二进制。
# mkdir 在 POSIX 上是原子的，用它当锁比 lock/flock 更可移植；
# 持锁进程被 kill 留下的陈旧锁按 pid 是否存活清理。
LOCK_DIR="${RUN_DIR}/core-update.lock"
LOCK_HELD=0

lock_acquire() {
	local holder
	mkdir -p "${RUN_DIR}" 2>/dev/null

	while :; do
		if mkdir "${LOCK_DIR}" 2>/dev/null; then
			printf '%s\n' "$$" > "${LOCK_DIR}/pid" 2>/dev/null
			LOCK_HELD=1
			return 0
		fi

		holder="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"

		if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
			return 1
		fi

		rm -rf "${LOCK_DIR}" 2>/dev/null
	done
}

lock_release() {
	# 只删自己持有的锁：没拿到锁就退出时绝不能把别人的锁清掉
	[ "${LOCK_HELD}" = "1" ] || return 0
	rm -rf "${LOCK_DIR}" 2>/dev/null
	LOCK_HELD=0
	return 0
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
				echo "sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-amd64v3-musl.tar.gz sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-amd64-musl.tar.gz"
			else
				echo "sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-amd64-musl.tar.gz"
			fi
			;;
		aarch64)
			echo "sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-arm64-musl.tar.gz"
			;;
		armv7*)
			echo "sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-armv7-musl.tar.gz"
			;;
		mipsel*|*mipsle*)
			echo "sing-box-1.14.3-refind_${REFIND_ASSET_TAG}-linux-mipsle-musl.tar.gz"
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
# 下载文件并在日志中显示进度百分比与可读字节数。
# transfer 在后台运行，同时轮询已下载字节大小，使 UI（tail core_download.log）
# 能看到稳定推进，而不是在 4~33 分钟的下载里长时间无输出。
download_file() {
	local url="$1" out="$2" purpose="${3:-generic}" mirror="${4:-auto}"
	local downloader rc actual_url connect_timeout codefile LAST_HTTP=""
	local round_attempts="" label

	downloader="$(get_downloader "$purpose")" || return 1

	if [ "$purpose" = "asset" ]; then
		connect_timeout=15
	else
		connect_timeout=10
	fi

	for actual_url in $(candidate_urls "$url" "$mirror"); do
		# 34MB 的包按镜像速度需 4~26 分钟。先打印源地址，避免首条进度
		# （慢链路上可能要等约 10 秒）之前 UI 看起来像卡死。
		log_download "正在下载（源：${actual_url}）"
		case "$downloader" in
			curl)
				local total=0 cur=0 pct=0 last_pct=0 last_time=0 last_cur=0 pid now
				codefile="${out}.code"
				# HEAD 探测总大小；部分镜像不支持 HEAD 时 total=0，
				# 退化为只显示已下载字节数。
				total="$(curl -sI --connect-timeout "$connect_timeout" "$actual_url" 2>/dev/null \
					| awk '{s=tolower($0)} s ~ /^content-length:/ {gsub(/\r/,"",$2); v=$2} END{print v+0}')"
				rm -f "$codefile" "$out"
				curl -fsSL --connect-timeout "$connect_timeout" \
					--speed-limit 6144 --speed-time 60 --max-time 7200 \
					-A "luci-app-homeproxy" \
					-o "$out" -w '%{http_code}' "$actual_url" >"$codefile" 2>/dev/null &
				pid=$!
				while kill -0 "$pid" 2>/dev/null; do
					# 同 fetch_panel.sh：curl 后台启动，输出文件可能尚未创建，
					# 直接 `wc -c < 文件` 会触发 shell 重定向报错，先判存在。
					cur=0
					[ -f "$out" ] && cur="$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
					[ -z "$cur" ] && cur=0
					now=$(date +%s)
					if [ "$total" -gt 0 ]; then
						pct=$(( cur * 100 / total ))
						if [ "$pct" -ge "$((last_pct + 5))" ] || [ "$pct" -ge 100 ] || [ "$((now - last_time))" -ge 10 ]; then
							log_download "下载进度 ${pct}%（$(human_size "$cur")/$(human_size "$total")）：${actual_url}"
							last_pct=$pct; last_time=$now
						fi
					else
						if [ "$cur" -ge "$((last_cur + 1048576))" ] || [ "$((now - last_time))" -ge 10 ]; then
							log_download "已下载 $(human_size "$cur")（总大小未知）：${actual_url}"
							last_cur=$cur; last_time=$now
						fi
					fi
					sleep 1
				done
				wait "$pid"; rc=$?
		if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ]; then
			log_download "下载进度 100%（$(human_size "$total")/$(human_size "$total")）：${actual_url}"
		fi
				LAST_HTTP="$(cat "$codefile" 2>/dev/null | tr -d ' \r\n')"
				rm -f "$codefile"
				;;
			wget)
				wget -q -T 60 -O "$out" "$actual_url" >/dev/null 2>&1
				rc=$?
				;;
			*)
				return 1
				;;
		esac

		if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
			if [ "$purpose" = "asset" ]; then
				# 校验镜像确实返回了 gzip 压缩的 tar 包。错误镜像可能以
				# HTTP 200 返回 HTML 错误页，必须校验内容。
				if ! tar -tzf "$out" >/dev/null 2>&1; then
					log_download "下载内容不是有效的 tar.gz 包（疑似错误页面），继续尝试下一个源：${actual_url}"
					rm -f "$out"
					continue
				fi
			fi
			log_download "下载成功：${actual_url}"
			DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS}${DOWNLOAD_ATTEMPTS:+; }${round_attempts}"
			return 0
		fi
		# 每个源失败的返回码都要留档：全失败时汇总成一行给用户看，
		# 才分得清「域名死了(6)」「超时(28)」「文件不对(22)」。
		label="${actual_url#*://}"
		label="${label%%/*}"
		log_download "下载失败（返回码 ${rc}，HTTP ${LAST_HTTP:-000}）：${actual_url}"
		round_attempts="${round_attempts}${round_attempts:+; }${label}=rc${rc}/http${LAST_HTTP:-000}"
		rm -f "$out"
	done

	DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS}${DOWNLOAD_ATTEMPTS:+; }${round_attempts}"
	return 1
}

# 压缩包名 -> 内置校验值（见文件顶部 CORE_SHA256_* 常量）
builtin_sha256_for_asset() {
	local asset="$1"
	case "$asset" in
		*-linux-amd64v3-musl.tar.gz) printf '%s' "$CORE_SHA256_AMD64V3" ;;
		*-linux-amd64-musl.tar.gz)   printf '%s' "$CORE_SHA256_AMD64" ;;
		*-linux-arm64-musl.tar.gz)   printf '%s' "$CORE_SHA256_ARM64" ;;
		*-linux-armv7-musl.tar.gz)   printf '%s' "$CORE_SHA256_ARMV7" ;;
		*-linux-mipsle-musl.tar.gz)  printf '%s' "$CORE_SHA256_MIPSLE" ;;
		*) printf '%s' "" ;;
	esac
}

# SHA-256 verification.
#
# 校验值优先级：
#   1) 内置常量（CI 发版注入，最可信：不经过镜像、不依赖 Release 附带文件）
#   2) /etc/homeproxy/<asset>.sha256（手工放置，第一列 = 十六进制摘要）
# 两者都没有时按 CORE_SHA256_MISSING 处理（默认告警放行）。
#
# 注意：reF1nd 上游本身不发布 .sha256（v1.14.3-reF1nd 与 v1.15.0-alpha.11-reF1nd
# 的 asset 列表里都没有），所以旧实现逐个镜像去请求 `<asset>.sha256`，白扔了
# 7 个候选 URL x 每次 3 次重试的延迟，还刷出一堆假「下载失败」。这里不再联网
# 找校验和，只认内置值或本地文件。
verify_sha256() {
	local asset="$1" file="$2" expected='' sum source=''
	local sum_file="${HP_DIR}/${asset}.sha256"

	expected="$(builtin_sha256_for_asset "$asset")"
	if [ -n "$expected" ]; then
		source="内置校验值"
	elif [ -f "$sum_file" ]; then
		expected="$(awk '{print $1}' "$sum_file" 2>/dev/null | head -n1)"
		[ -n "$expected" ] && source="本地校验文件 ${sum_file}"
	fi

	# Guard against a malformed digest: only a real 64-character hex digest
	# counts as a checksum. Normalised to lower case so a hand-written (or
	# upper-case) built-in constant still matches sha256sum's output.
	case "$expected" in
		*[!0-9a-fA-F]*) expected='' ;;
	esac
	[ ${#expected} -eq 64 ] || expected=''
	[ -n "$expected" ] && expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"

	if [ -z "$expected" ]; then
		if [ "$CORE_SHA256_MISSING" = "fail" ]; then
			log_download "拒绝安装：${asset} 没有内置 SHA256 校验值，且 CORE_SHA256_MISSING=fail（若用的是本仓库 release，说明 CI 未成功注入校验值）"
			return 1
		fi
		log_download "警告：${asset} 没有内置 SHA256 校验值（本地编译或指向旧 release），跳过完整性校验，仅依赖 HTTPS 传输保护；可把 CORE_SHA256_MISSING 设为 fail 强制校验"
		return 0
	fi

	sum="$(sha256_of "$file")"
	if [ -z "$sum" ]; then
		log_download "拒绝安装：无法计算 ${asset} 的 SHA256（缺少 sha256sum 或文件为空）"
		return 1
	fi

	if [ "$sum" = "$expected" ]; then
		log_download "SHA256 校验通过（${source}）：${sum}"
		return 0
	fi

	log_download "SHA256 校验失败（${source}）：期望 ${expected}，实际 ${sum}（拒绝安装。若通过第三方镜像下载，请换镜像或改用 github 直连）"
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

# 选择可用空间足够的缓存目录。默认的 /tmp 在 OpenWrt 上是 tmpfs（内存盘），
# 在小内存路由器上可能小于 34MB 内核包 + 解压所需，导致下载报
# “No space left on device”。/tmp 空间不足时改到 /etc/homeproxy（overlay 闪存），
# 通常空间更充裕。
setup_cache_dir() {
	local tmp_free need=104857600  # 100MB 余量：34MB tar 包 + 解压
	tmp_free="$(disk_free_bytes /tmp)"
	if [ "$tmp_free" -lt "$need" ]; then
		CACHE_DIR="${HP_DIR}/core-dl"
		log_download "提示：/tmp（内存盘）可用空间仅 $(human_size "$tmp_free")，不足 100MB，缓存目录改用 ${CACHE_DIR}（/etc/homeproxy 在闪存 overlay 上空间通常更足）。"
	else
		CACHE_DIR="/tmp/homeproxy-core-dl"
	fi
}

# 服务运行时，路由器自身出站会被 homeproxy 的 nft tproxy 规则劫持
# （firewall_post.ut 的 homeproxy_output_redir）：curl 拿到的不是「直连」，
# 而是「当前选中的那个代理节点」。而「要更新内核」往往恰恰是「代理已经
# 不工作」的时刻 —— 于是镜像一个都连不上，日志里一片 `返回码 6` / `28`。
#
# 第一轮（不停服务）全失败后，临时停一次服务：stop_service 会做
# firewall_teardown，nft 劫持与 DNS 劫持一起撤掉，这一轮才是真的直连。
# 无论成败都立刻恢复，避免把局域网一直挂在「代理停了」的状态上。
CORE_DIRECT_RETRY_STOPPED=''

core_direct_retry() {
	local url="$1" out="$2"

	if ! /etc/init.d/homeproxy running >/dev/null 2>&1; then
		log_download "服务当前未运行，没有代理劫持可绕开，不再重试。"
		return 1
	fi

	log_download "全部源都不可用，疑似当前代理节点已失效。临时停止 homeproxy 改用直连再试一轮（下载结束后自动恢复服务）"
	/etc/init.d/homeproxy stop >/dev/null 2>&1
	CORE_DIRECT_RETRY_STOPPED=1

	# stop_service 要 teardown nft、重启 dnsmasq，给它一点时间落地，
	# 否则紧接着发出的 curl 仍可能命中尚未撤掉的规则。
	sleep 2

	DOWNLOAD_ATTEMPTS_PROXIED="$DOWNLOAD_ATTEMPTS"
	DOWNLOAD_ATTEMPTS=""

	download_file "$url" "$out" asset auto
	return 0
}

core_direct_restore() {
	[ -n "$CORE_DIRECT_RETRY_STOPPED" ] || return 0
	CORE_DIRECT_RETRY_STOPPED=''

	if /etc/init.d/homeproxy start >/dev/null 2>&1; then
		log_download "已重新启动 homeproxy。"
	else
		log_download "警告：homeproxy 未能自动重新启动，请到「服务状态」页确认，必要时手动执行 /etc/init.d/homeproxy start"
	fi

	return 0
}

# Download and install the matching reF1nd core for the given arch/asset.
download_and_install() {
	local arch="$1" asset="$2"
	local asset_url rc

	setup_cache_dir
	clear_cache

	DOWNLOAD_ATTEMPTS=""
	DOWNLOAD_ATTEMPTS_PROXIED=""
	asset_url="https://github.com/${REFIND_REPO}/releases/download/${REFIND_TAG}/${asset}"
	log_download "开始下载 reF1nd 内核：${asset}（架构 ${arch}）"

	if ! download_file "$asset_url" "${CACHE_DIR}/${asset}" asset auto; then
		core_direct_retry "$asset_url" "${CACHE_DIR}/${asset}"
		core_direct_restore
	fi

	if [ ! -s "${CACHE_DIR}/${asset}" ]; then
		# 一行收口，并且把每个源的返回码带上：6=域名解析不了，
		# 28=超时，22=HTTP 4xx/5xx。没有这串数字，用户只能看到
		# 「下载失败」四个字，分不清是自己的网络问题还是镜像失效。
		local detail=""
		if [ -n "$DOWNLOAD_ATTEMPTS_PROXIED" ]; then
			detail="经代理：${DOWNLOAD_ATTEMPTS_PROXIED}"
		fi
		if [ -n "$DOWNLOAD_ATTEMPTS" ]; then
			[ -n "$detail" ] && detail="${detail}｜"
			detail="${detail}直连：${DOWNLOAD_ATTEMPTS}"
		fi
		log_download "下载失败：${asset}（所有源都不可用 ${detail:-无记录}）"
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
	local arch candidates asset cur_ver cur_base

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
	# The shipped binary reports "<base>_<plugin-version>" (e.g.
	# 1.14.3-reF1nd_0.1.3). Only the base part is compared so that:
	#   · an older core installed by a previous release, or a plain "<base>"
	#     string, is still recognised as up-to-date and never overwritten with
	#     an official (unpatched) reF1nd binary;
	#   · the plugin-version suffix stays purely informational for the UI.
	cur_base="${cur_ver%%_*}"
	if [ -x "$CORE_BIN" ] && [ "$cur_base" = "$REFIND_VERSION" ]; then
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
	#   scp sing-box-1.14.3-refind_*-linux-amd64-musl.tar.gz root@router:/etc/homeproxy/sing-box.tar.gz
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
	echo "target_version=${CORE_TARGET_VERSION}"
}

# 这次内核下载是谁触发的。三条入口：init.d 启动时的 ensure、面板「更新内核」
# 按钮（经 update_core_async.sh 调 update）、终端手动执行。以前日志只写
# 「命令=ensure/update」，看不出是谁发起的，排障时只能靠时间猜。
default_source() {
	case "${1:-}" in
		ensure) printf '%s' "服务启动（init.d 自动检查内核）" ;;
		update) printf '%s' "手动执行（终端/SSH）" ;;
		status) printf '%s' "状态查询" ;;
		*) printf '%s' "未标注" ;;
	esac
}

main() {
	local cmd="" source=""
	while [ $# -gt 0 ]; do
		case "$1" in
			ensure|update|status) cmd="$1" ;;
			--source)
				shift
				source="${1:-}"
				;;
		esac
		shift
	done
	[ -n "$cmd" ] || cmd="ensure"
	[ -n "$source" ] || source="$(default_source "$cmd")"

	# Start marker: lets us tell "the helper never ran at all" (e.g. a fatal
	# parse error before this point, or the file missing) apart from "it ran
	# but failed early". On a fresh boot /var/run/homeproxy may not exist yet,
	# so ensure_log() inside log_download creates it first.
	log_download "==== 脚本启动：命令=${cmd}，来源=${source} ===="
	case "$cmd" in
		ensure)
			# 另一个实例正在下载/安装内核：它做的正是 ensure 要做的事，
			# 让路即可（rc 0，不把并发当成失败写进日志）。
			if ! lock_acquire; then
				log_download "另一个内核任务正在运行，ensure 让路退出。"
				exit 0
			fi
			trap 'lock_release' EXIT INT TERM
			ensure_core
			;;
		update)
			if ! lock_acquire; then
				log_download "另一个内核任务正在运行，update 让路退出。"
				echo "busy"
				exit 1
			fi
			trap 'lock_release' EXIT INT TERM
			update_core
			;;
		status)  print_status ;;
		*)
			echo "Usage: $0 {ensure|update|status}" >&2
			exit 2
			;;
	esac
}

main "$@"
