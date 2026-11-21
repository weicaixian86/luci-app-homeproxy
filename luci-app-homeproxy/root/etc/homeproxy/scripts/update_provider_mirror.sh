#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 方案 B（provider 过滤镜像）：sing-box 内核的 remote provider 不支持节点过滤
# （fork 的 provider 结构体只有 Outbounds/Endpoints/HealthCheck，无 filter 字段；
# 二进制 strings + 实测双重验证），机场订阅里的「如果/客户端太旧/请到网站…」
# 提示节点会直达面板。本脚本把每个订阅**按导入同一套关键词过滤后**落到回环
# 镜像文件，generate_client.uc 把 provider 的 url 指向
# http://127.0.0.1:8595/<hash>.sub（init.d 起的回环 uhttpd 实例，仅本机可达），
# 内核拉到的永远是过滤后的内容——垃圾节点从源头进不了内核。
#
# 触发点：init.d start_service（生成配置前）、update_crond.sh（订阅定时更新后）、
# update_provider.sh（面板「更新」按钮链路末尾）。
#
# 缓存：镜像文件 mtime 在 1 小时内直接复用（--force 强制刷新），频繁 reload
# 不会反复拉订阅。拉取失败保留旧镜像——provider 至少还有上次的过滤内容可用。

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

HP_DIR="/etc/homeproxy"
MIRROR_DIR="$HP_DIR/providers-mirror"
RUN_DIR="${HP_RUN_DIR:-/var/run/homeproxy}"
CONF="homeproxy"
MAX_AGE=3600

FORCE="${1:-}"

log() { logger -t homeproxy "provider-mirror: $*" 2>/dev/null; }

[ -r "/etc/config/$CONF" ] || { log "配置不可读，跳过。"; exit 0; }
[ -f /lib/functions.sh ] || { log "缺 /lib/functions.sh，跳过。"; exit 0; }

MODE="disabled"
KW_LIST=""
UA="Wget/1.21 (HomeProxy, like v2rayN)"

handle_kw() {
	# 多个关键词条目时用 | 连接；单条目本身已是 官网|剩余|… 形态，两种都对。
	KW_LIST="${KW_LIST:+$KW_LIST|}$1"
}

. /lib/functions.sh
config_load "$CONF"
config_get MODE subscription filter_nodes disabled
config_list_foreach subscription filter_keywords handle_kw
config_get UA subscription user_agent "$UA"
config_get MIXED_PORT infra mixed_port 5330

URLS=""
handle_url() { URLS="$URLS
$1"; }
config_list_foreach subscription subscription_url handle_url

# fetch：先直连；失败走本机 mixed 入站回环代理——内核 provider 的默认出站
# 就是这条链（机场域名常被墙，直连抖动时这条兜底保住镜像刷新）。
# ⚠️ 不能用命令替换 $(fetch_sub ...) 取 body：那会在子 shell 里执行，
# 里面设置的 LAST_UI 不会传回父 shell。改为写固定文件，调用方从文件读。
FETCH_BODY="$RUN_DIR/mirror-body.$$"
FETCH_UI="$RUN_DIR/mirror-ui.$$"
fetch_sub() {
	local u="$1" hdr="$RUN_DIR/mirror-hdr.$$"
	: > "$FETCH_BODY"; : > "$FETCH_UI"
	curl -sS -m 15 --compressed -D "$hdr" -A "$UA" "$u" -o "$FETCH_BODY" 2>/dev/null
	if [ ! -s "$FETCH_BODY" ]; then
		curl -sS -m 20 --compressed -D "$hdr" -x "http://127.0.0.1:${MIXED_PORT:-5330}" -A "$UA" "$u" -o "$FETCH_BODY" 2>/dev/null
	fi
	if [ -s "$FETCH_BODY" ]; then
		# 从响应头提取 subscription-userinfo（去掉 CR）写到文件
		grep -i '^subscription-userinfo:' "$hdr" 2>/dev/null | head -1 \
			| sed 's/^[Ss]ubscription-[Uu]serinfo:[[:space:]]*//' | tr -d '\r' > "$FETCH_UI" 2>/dev/null
	fi
	rm -f "$hdr" 2>/dev/null
}

if [ -z "$URLS" ]; then
	log "没有配置订阅 URL，跳过。"
	exit 0
fi

mkdir -p "$MIRROR_DIR" "$RUN_DIR" 2>/dev/null

printf '%s\n' "$URLS" | while IFS= read -r url; do
	[ -n "$url" ] || continue
	url_clean="${url%%#*}"
	hash="$(printf '%s' "$url_clean" | md5sum 2>/dev/null | cut -d' ' -f1)"
	[ -n "$hash" ] || { log "md5 计算失败（url=${url_clean}），跳过。"; continue; }
	mirror="$MIRROR_DIR/$hash.sub"
	seed="$HP_DIR/providers/$hash.sub"

	now="$(date +%s 2>/dev/null)"; case "$now" in ''|*[!0-9]*) now=0 ;; esac
	mt="$(stat -c %Y "$mirror" 2>/dev/null)"; case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
	if [ "$FORCE" != "--force" ] && [ "$mt" -gt 0 ] && [ "$now" -gt 0 ] \
	   && [ $((now - mt)) -lt "$MAX_AGE" ]; then
		continue
	fi

	fetch_sub "$url_clean"
	body="$(cat "$FETCH_BODY" 2>/dev/null)"
	if [ -z "$body" ]; then
		log "$hash: 订阅拉取失败，保留旧镜像（provider 继续用上次的过滤内容）。"
		continue
	fi

	# 流量/到期（userinfo）优先用 fetch_sub 从订阅 HTTP 响应头抓到的
	# subscription-userinfo（init.d 启动前会删旧缓存，不能依赖缓存文件）。
	ui="$(cat "$FETCH_UI" 2>/dev/null)"
	case "$ui" in
		upload=*|download=*|expire=*|total=*) ;;
		*) ui="" ;;
	esac
	if [ -z "$ui" ]; then
		# 回退：响应头没有时，从旧缓存首行取（手动刷新场景，缓存还在）
		if [ -f "$seed" ]; then
			seed_ui="$(head -n 1 "$seed" 2>/dev/null)"
			case "$seed_ui" in
				upload=*|download=*|expire=*|total=*) ui="$seed_ui" ;;
			esac
		fi
	fi

	# 解码/过滤/编码交给 ucode helper（busybox 无可用 base64 工具，openssl
	# 的 base64 在本机亦不可用；ucode 的 b64dec/b64enc + luci.http.urldecode
	# 才是 update_subscriptions.uc 解析订阅用的同一套实现，中文关键词 URL
	# 解码后才能真正匹配到节点名）。
	kw_file="$RUN_DIR/mirror-kw.$$"
	printf '%s\n' "$KW_LIST" > "$kw_file" 2>/dev/null

	b64="$(cd "$HP_DIR/scripts" && ucode -S filter_sub.uc "$FETCH_BODY" "$MODE" "$kw_file" 2>/dev/null)"
	rm -f "$kw_file" 2>/dev/null

	if [ -z "$b64" ]; then
		log "$hash: ucode 过滤助手无输出，原样透传不过滤。"
		{ [ -n "$ui" ] && printf '%s\n' "$ui"; printf '%s\n' "$body"; } > "$mirror.tmp" 2>/dev/null
		mv "$mirror.tmp" "$mirror" 2>/dev/null
		continue
	fi

	# 写两处：
	#   ① providers-mirror/<hash>.sub —— provider url（127.0.0.1:8595）拉取用
	#   ② providers/<hash>.sub —— provider 的 initial_path 缓存。内核启动优先
	#      读缓存，若这里还是旧的未过滤内容，垃圾节点就会直达面板；同时缓存
	#      首行的 userinfo 是面板流量/到期的唯一来源，必须保留。
	{
		[ -n "$ui" ] && printf '%s\n' "$ui"
		printf '%s\n' "$b64"
	} > "$mirror.tmp" 2>/dev/null
	mv "$mirror.tmp" "$mirror" 2>/dev/null

	mkdir -p "$HP_DIR/providers" 2>/dev/null
	{
		[ -n "$ui" ] && printf '%s\n' "$ui"
		printf '%s\n' "$b64"
	} > "$seed.tmp" 2>/dev/null
	mv "$seed.tmp" "$seed" 2>/dev/null

	# uhttpd docroot（/etc/homeproxy）根也写一份：provider url = /<hash>.sub
	# 直接命中这里。procd 缓存了旧实例参数（docroot 从 providers-mirror 变不回
	# 来），以实际 docroot 为准，确保内核拉到的是过滤后内容。
	{
		[ -n "$ui" ] && printf '%s\n' "$ui"
		printf '%s\n' "$b64"
	} > "$HP_DIR/$hash.sub.tmp" 2>/dev/null
	mv "$HP_DIR/$hash.sub.tmp" "$HP_DIR/$hash.sub" 2>/dev/null

	# local provider 专用：纯订阅正文（无 userinfo 头）。内核的 local provider
	# 会把首行当 JSON/YAML/SIP008 解析，userinfo（upload=…）会导致
	# "no servers found" 启动失败。只需 base64 payload 即可被正确解析成节点。
	mkdir -p "$HP_DIR/providers-local" 2>/dev/null
	printf '%s\n' "$b64" > "$HP_DIR/providers-local/$hash.sub.tmp" 2>/dev/null
	mv "$HP_DIR/providers-local/$hash.sub.tmp" "$HP_DIR/providers-local/$hash.sub" 2>/dev/null

	log "$hash: 镜像+缓存+local文件已刷新（ucode 过滤完成，userinfo=$( [ -n "$ui" ] && echo 保留 || echo 无)，mode=$MODE）。"
done

exit 0
