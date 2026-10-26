#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

'use strict';

import { md5 } from 'digest';
import { open, readfile } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import { urldecode, urlencode } from 'luci.http';
import { init_action } from 'luci.sys';

import {
	wGETResponse, wGETHeaders, decodeBase64Str, getTime, isEmpty, parseURL,
	validation, HP_DIR, RUN_DIR
} from 'homeproxy';

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const ucimain = 'config',
      ucinode = 'node',
      ucisubscription = 'subscription';

const allow_insecure = uci.get(uciconfig, ucisubscription, 'allow_insecure') || '0',
      filter_mode = uci.get(uciconfig, ucisubscription, 'filter_nodes') || 'disabled',
      filter_keywords = uci.get(uciconfig, ucisubscription, 'filter_keywords') || [],
      packet_encoding = uci.get(uciconfig, ucisubscription, 'packet_encoding') || 'xudp',
      all_subscription_urls = uci.get(uciconfig, ucisubscription, 'subscription_url') || [],
	  user_agent = uci.get(uciconfig, ucisubscription, 'user_agent'),
	  via_proxy = uci.get(uciconfig, ucisubscription, 'update_via_proxy') || '0';

/* 「通过代理更新订阅」在 0.2.04 之前是**死开关**：界面上有这一项，但脚本里
 * 只把它拼进日志文案（`手动（经代理）`），全项目从来没有为它设过
 * `http_proxy` 或传 `-x`。于是勾上它和不勾完全一样——而用户现场正是
 * 「5 个订阅里 4 个要海外网络才能拉」，这条需求一直没有被满足。
 *
 * 现在真的走本地 mixed 入口：`infra.mixed_port`（现场 5330），sing-box 的
 * `mixed-in` inbound 是**无条件创建**的（generate_client.uc:1112），无认证。
 * 走它的额外好处是绕开两件事：
 *   1. nft 的 `homeproxy_output_redir` 会劫持路由器自身出站（firewall_post.ut:372），
 *      内核在跑但出口不可用时抓订阅会被自己的代理拖死（现场每条约 5 秒）；
 *   2. 域名解析交给 sing-box（只发 CONNECT host:443），不再受 dnsmasq
 *      → 内核 5333 这条链路的当前状态影响。
 * 默认 `update_via_proxy=0` 时 proxy_url 为 null，抓取路径与旧版逐字相同。 */
const proxy_url = (via_proxy === '1')
	? sprintf('http://127.0.0.1:%s', uci.get(uciconfig, 'infra', 'mixed_port') || '5330')
	: null;

const provider_update_id = trim(readfile(RUN_DIR + '/provider-update-id') || '');

/* 触发来源：命令行 `--source` 优先（调用方最清楚自己是谁），其次才沿用标记
 * 文件那套判定（schedule-run / provider-update-id）。ucode 把多余的命令行
 * 参数放进全局 ARGV（见 ucode 文档 "Script arguments"），没有参数时是空数组。
 * exists() 是编译期的特殊形式，用它守卫一层：万一某个 ucode 版本没定义这个
 * 全局，也不能让订阅更新整个崩掉。 */
let cli_source = '';
if (exists(ARGV)) {
	const argv = ARGV || [];
	for (let i = 0; i < length(argv) - 1; i++) {
		if (argv[i] === '--source') {
			cli_source = trim(argv[i + 1] || '');
			break;
		}
	}
}

let subscription_urls = all_subscription_urls;
if (provider_update_id)
	subscription_urls = filter(all_subscription_urls, (url) =>
		md5(replace(url, /#.*$/, '')) === provider_update_id);

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainalnd_china';
let main_node, main_udp_node;
if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
	main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';
}
/* UCI config end */

/* String helper start */
function filter_check(name) {
	if (isEmpty(name) || filter_mode === 'disabled' || isEmpty(filter_keywords))
		return false;

	let ret = false;
	for (let i in filter_keywords) {
		const patten = regexp(i);
		if (match(name, patten))
			ret = true;
	}
	if (filter_mode === 'whitelist')
		ret = !ret;

	return ret;
}
/* String helper end */

/* Common var start */
const node_cache = {},
      node_result = [];

const ubus = connect();
const sing_features = ubus.call('luci.homeproxy', 'singbox_get_features', {}) || {};
/* Common var end */

/* Log */
system(`mkdir -p ${RUN_DIR}`);
function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [SUBSCRIBE] ${join(' ', args)}\n`);
	logfile.close();
}

function has_value(value) {
	return value !== null && value !== '' && value !== 'nil';
}

function to_string(value) {
	return has_value(value) ? sprintf('%s', value) : null;
}

function bool_to_uci(value) {
	if (value === true)
		return '1';
	if (value === false)
		return '0';
	return null;
}

function normalize_list(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	return [to_string(value)];
}

function normalize_alpn(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	if (type(value) === 'string') {
		let items = map(split(value, ','), (v) => trim(v));
		items = filter(items, (v) => length(v));
		return length(items) ? items : null;
	}
	return [to_string(value)];
}

function normalize_host_list(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	return split(to_string(value), ',');
}

function normalize_first(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return length(value) ? value[0] : null;
	return to_string(value);
}

function normalize_hysteria_hopping_port(mport) {
	if (!has_value(mport))
		return null;

	let ports = [];
	for (let p in split(to_string(mport), ',')) {
		p = trim(p);
		if (!p)
			continue;
		if (match(p, /^\d+$/))
			p = p + ':' + p;
		else
			p = replace(p, '-', ':');
		push(ports, p);
	}

	return length(ports) ? ports : null;
}

function normalize_mihomo_ports(ports) {
	if (!has_value(ports))
		return null;

	if (type(ports) === 'array')
		return map(ports, (p) => {
			const v = to_string(p);
			if (match(v, /^\d+$/))
				return v + ':' + v;
			return replace(v, '-', ':');
		});

	return normalize_hysteria_hopping_port(to_string(ports));
}

function parse_mihomo_speed(value) {
	if (!has_value(value))
		return null;

	const str = to_string(value);
	const match_val = match(str, /[0-9]+(\.[0-9]+)?/);
	if (!match_val)
		return null;

	const num_str = type(match_val) === 'array' ? match_val[0] : match_val;
	if (!num_str)
		return null;

	const num = int(num_str);
	if (num === null || num != num)
		return null;

	return to_string(num);
}

function get_header_host(headers) {
	if (type(headers) !== 'object')
		return null;

	return headers.Host || headers.host || headers['HOST'];
}

/* sing-box 的 VLESS/VMess 只认三档 UDP 编码：缺省（等同 xudp）、
   'packetaddr'、'none'（空串）。机场写法五花八门，这里归一到表单那三档。
   返回 null = 节点没声明 → 由调用方用全局默认值兜底；返回 '' = 显式关闭。

   ⚠️ 判「没声明」只用 `=== null`，**绝不许写 `undefined`**。
   0.2.03 就是在这里写了 `value === undefined`，真机上的报错是
   `access to undeclared variable undefined` —— ucode 没有 `undefined`
   这个关键字，它只是一个普通标识符；在 **.uc 模块**（有 import、按闭包
   编译）里读它直接抛异常，被 parse_uri 每节点的 try/catch 吞成一行
   `Skipping unparsable node entry`，后果是 **vless + vmess 整批消失**
   （hysteria2 / trojan / anytls 不经过本函数，毫发无损），而日志里就看
   不出原因。2026-10-26 真机实测：PKM 订阅 `Successfully fetched 14 nodes
   of total 31`（31 - 11 个 vless - 6 个公告 vmess = 14），vless 计数为 0。

   ⚠️ 另注：`ucode -e` 探针**不能**用来验证这条——`-e` 在全局作用域跑，
   读 `undefined` 不抛（实测 `o.missing === undefined` 返回 true），会给出
   假阴性。要验就在 .uc 里验，或直接看设备日志。

   大小写差异用显式白名单枚举兜（`in` 对数组是值匹配，-e 与模块内一致）。 */
function normalize_packet_encoding(value) {
	if (value === null)
		return null;

	const raw = trim(sprintf('%s', value));

	if (raw === '')
		return null;

	if (raw in [ 'xudp', 'XUDP', 'xUdp', 'Xudp' ])
		return 'xudp';

	if (raw in [ 'packetaddr', 'PacketAddr', 'packet-addr', 'packet_addr' ])
		return 'packetaddr';

	if (raw in [ 'none', 'None', 'NONE', 'disabled', 'Disabled', 'false', 'False', '0', 'off', 'Off' ])
		/* 显式写了「不要编码」：空串表示，generate_client 原样写进
		   packet_encoding —— 空串在 sing-box 里就是 none 档。 */
		return '';

	/* 认不出的值别写进配置（脏值会让 sing-box check 失败），退回全局默认。 */
	return null;
}

function apply_transport_opts(config, proxy) {
	const network = proxy.network;
	if (!has_value(network) || network === 'tcp')
		return;

	let ws_opts = proxy['ws-opts'] || {};
	let grpc_opts = proxy['grpc-opts'] || {};
	let http_opts = proxy['http-opts'] || proxy['h2-opts'] || {};
	let httpupgrade_opts = proxy['http-upgrade-opts'] || {};

	switch (network) {
	case 'ws':
		config.transport = 'ws';
		config.ws_path = ws_opts.path ? to_string(ws_opts.path) : null;
		config.ws_host = get_header_host(ws_opts.headers);
		config.websocket_early_data = ws_opts['early-data'] ? to_string(ws_opts['early-data']) : null;
		config.websocket_early_data_header = ws_opts['early-data-header-name'] ?
			to_string(ws_opts['early-data-header-name']) : null;
		break;
	case 'grpc':
		config.transport = 'grpc';
		config.grpc_servicename = to_string(grpc_opts['grpc-service-name'] || grpc_opts['service-name']);
		break;
	case 'http':
	case 'h2':
		config.transport = 'http';
		config.http_path = normalize_first(http_opts.path);
		config.http_host = normalize_host_list(get_header_host(http_opts.headers) || http_opts.host);
		break;
	case 'httpupgrade':
		config.transport = 'httpupgrade';
		config.httpupgrade_host = get_header_host(httpupgrade_opts.headers) || httpupgrade_opts.host;
		config.http_path = normalize_first(httpupgrade_opts.path);
		break;
	}
}

function parse_mihomo_proxy(proxy) {
	if (type(proxy) !== 'object')
		return null;

	let config;
	const tls_sni = proxy.servername || proxy.sni;
	const tls_fingerprint = proxy['client-fingerprint'] || proxy.fingerprint;
	const tls_insecure = (proxy['skip-cert-verify'] === true || proxy.insecure === '1' || proxy.allowInsecure === true || proxy.allowInsecure === '1') ? '1'
		: (proxy['skip-cert-verify'] === false || proxy.insecure === '0' || proxy.allowInsecure === false || proxy.allowInsecure === '0') ? '0'
		: null;

	switch (proxy.type) {
	case 'anytls': {
		/* fingerprint 是字符串，`||` 对 null / '' / 缺失 都安全。
		   ⚠️ 别写 `!== undefined`：ucode 里 `undefined` 不是关键字，
		   在 .uc 模块里读它就是 `access to undeclared variable undefined`
		   （0.2.03 在本分支与归一函数里各写了一处，前者让 mihomo 格式
		   订阅的 anytls 也抛，后者让 vless/vmess 整批消失）。 */
		let anytls_fp = proxy['client-fingerprint'] || proxy.fingerprint;
		anytls_fp = to_string(anytls_fp);
		if (anytls_fp === 'none' || anytls_fp === 'disable' || anytls_fp === 'disabled')
			anytls_fp = null;
		else if (!has_value(anytls_fp))
			anytls_fp = 'chrome';
		config = {
			label: proxy.name,
			type: 'anytls',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			tls: '1',
			tls_sni: tls_sni || proxy.peer,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? anytls_fp : null,
			anytls_idle_session_check_interval: to_string(proxy['idle-session-check-interval']),
			anytls_idle_session_timeout: to_string(proxy['idle-session-timeout']),
			anytls_min_idle_session: to_string(proxy['min-idle-session']),
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'vmess':
		config = {
			label: proxy.name,
			type: 'vmess',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			vmess_alterid: has_value(proxy.alterId) ? to_string(proxy.alterId) : null,
			vmess_encrypt: proxy.cipher,
			/* 兼容 mihomo 的两种写法，并归一成表单那三档；null = 没声明 */
			packet_encoding: normalize_packet_encoding(proxy['packet-encoding'] || proxy.packetEncoding),
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'hysteria2':
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		config = {
			label: proxy.name,
			type: 'hysteria2',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			hysteria_hopping_port: normalize_mihomo_ports(proxy.ports),
			hysteria_down_mbps: parse_mihomo_speed(proxy.down),
			hysteria_up_mbps: parse_mihomo_speed(proxy.up),
			hysteria_obfs_type: proxy.obfs,
			hysteria_obfs_password: proxy['obfs-password'],
			tls: '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'hysteria':
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		config = {
			label: proxy.name,
			type: 'hysteria',
			address: proxy.server,
			port: to_string(proxy.port),
			hysteria_hopping_port: normalize_mihomo_ports(proxy.ports),
			hysteria_protocol: proxy.protocol,
			hysteria_auth_type: proxy['auth-str'] ? 'string' : (proxy.auth ? 'base64' : null),
			hysteria_auth_payload: proxy['auth-str'] || proxy.auth,
			hysteria_obfs_password: proxy.obfs,
			hysteria_down_mbps: parse_mihomo_speed(proxy.down),
			hysteria_up_mbps: parse_mihomo_speed(proxy.up),
			tls: '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'vless':
		config = {
			label: proxy.name,
			type: 'vless',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			vless_flow: proxy.flow,
			/* 兼容 mihomo 的两种写法，并归一成表单那三档；null = 没声明 */
			packet_encoding: normalize_packet_encoding(proxy['packet-encoding'] || proxy.packetEncoding),
			tls: (proxy.tls === true || proxy['reality-opts']) ? '1' : '0',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tls_reality: proxy['reality-opts'] ? '1' : '0',
			tls_reality_public_key: proxy['reality-opts'] ? proxy['reality-opts']['public-key'] : null,
			tls_reality_short_id: proxy['reality-opts'] ? proxy['reality-opts']['short-id'] : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'trojan':
		config = {
			label: proxy.name,
			type: 'trojan',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			tls: (proxy.tls === false) ? '0' : '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'ss': {
		let ss_plugin = proxy.plugin;
		if (ss_plugin === 'simple-obfs')
			ss_plugin = 'obfs-local';
		config = {
			label: proxy.name,
			type: 'shadowsocks',
			address: proxy.server,
			port: to_string(proxy.port),
			shadowsocks_encrypt_method: proxy.cipher,
			password: proxy.password,
			shadowsocks_plugin: ss_plugin,
			shadowsocks_plugin_opts: proxy['plugin-opts'],
			udp_over_tcp: bool_to_uci(proxy['udp-over-tcp']),
			udp_over_tcp_version: to_string(proxy['udp-over-tcp-version']),
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'ssr':
		log(sprintf('Skipping unsupported ssr node: %s.', proxy.name || proxy.server));
		return null;
	case 'socks5':
	case 'socks':
	case 'socks4':
	case 'socks4a':
		config = {
			label: proxy.name,
			type: 'socks',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			socks_version: (proxy.type === 'socks4a') ? '4a' : ((proxy.type === 'socks4') ? '4' : '5'),
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'http':
		config = {
			label: proxy.name,
			type: 'http',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'tuic': {
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		let tuic_heartbeat = proxy['heartbeat-interval'];
		if (has_value(tuic_heartbeat)) {
			tuic_heartbeat = int(tuic_heartbeat);
			if (tuic_heartbeat >= 1000)
				tuic_heartbeat = int(tuic_heartbeat / 1000);
		}
		config = {
			label: proxy.name,
			type: 'tuic',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			password: proxy.password || proxy.token,
			tuic_congestion_control: proxy['congestion-controller'],
			tuic_udp_relay_mode: proxy['udp-relay-mode'],
			tuic_udp_over_stream: bool_to_uci(proxy['udp-over-stream']),
			tuic_enable_zero_rtt: bool_to_uci(proxy['zero-rtt-handshake']),
			tuic_heartbeat: has_value(tuic_heartbeat) ? to_string(tuic_heartbeat) : null,
			tls: '1',
			tls_sni: proxy['disable-sni'] ? null : tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'ssh':
		config = {
			label: proxy.name,
			type: 'ssh',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			ssh_client_version: proxy['client-version'],
			ssh_host_key: normalize_list(proxy['host-key']),
			ssh_host_key_algo: normalize_list(proxy['host-key-algorithms']),
			ssh_priv_key: normalize_list(proxy['private-key']),
			ssh_priv_key_pp: proxy['private-key-passphrase'],
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'wireguard': {
		let wg_addresses = [];
		if (has_value(proxy.ip))
			push(wg_addresses, to_string(proxy.ip));
		if (has_value(proxy.ipv6))
			push(wg_addresses, to_string(proxy.ipv6));
		config = {
			label: proxy.name,
			type: 'wireguard',
			address: proxy.server,
			port: to_string(proxy.port),
			wireguard_local_address: length(wg_addresses) ? wg_addresses : null,
			wireguard_private_key: proxy['private-key'],
			wireguard_peer_public_key: proxy['public-key'],
			wireguard_pre_shared_key: proxy['pre-shared-key'],
			wireguard_reserved: normalize_list(proxy.reserved),
			wireguard_mtu: to_string(proxy.mtu),
			wireguard_persistent_keepalive_interval: to_string(proxy['persistent-keepalive'] || proxy['persistent-keepalive-interval'] || proxy.keepalive)
		};
		break;
	}
	default:
		return null;
	}

	return config;
}

function parse_subscription_userinfo(headers) {
	let header_value = null;
	for (let line in split(headers || '', '\n')) {
		const matched = match(line, /^\s*subscription-userinfo:\s*(.*)$/i);
		if (matched)
			header_value = trim(matched[1]);
	}

	if (isEmpty(header_value))
		return null;

	let info = {};
	for (let item in split(header_value, ';')) {
		const matched = match(trim(item), /^([a-z]+)\s*=\s*([0-9]+)$/i);
		if (!matched)
			continue;

		const value = int(matched[2]);
		if (value < 0)
			continue;

		if (match(matched[1], /^upload$/i))
			info.upload = value;
		else if (match(matched[1], /^download$/i))
			info.download = value;
		else if (match(matched[1], /^total$/i))
			info.total = value;
		else if (match(matched[1], /^expire$/i))
			info.expire = value;
	}

	return length(info) ? info : null;
}

function subscription_info_option(url) {
	url = replace(url || '', /#.*$/, '');
	return 'subinfo_' + substr(md5(url), 0, 16);
}

function subscription_display_name(url) {
	const names = normalize_list(uci.get(uciconfig, ucisubscription, 'subscription_name')) || [];
	let index = 0;
	for (let configured_url in all_subscription_urls) {
		if (replace(configured_url, /#.*$/, '') === replace(url, /#.*$/, '')) {
			const name = trim(names[index] || '');
			return name || substr(md5(replace(url, /#.*$/, '')), 0, 8);
		}
		index++;
	}
	return substr(md5(replace(url, /#.*$/, '')), 0, 8);
}

function previous_subscription_info(info_option) {
	const value = uci.get(uciconfig, ucisubscription, info_option);
	if (isEmpty(value))
		return null;

	try {
		const info = json(value);
		if (type(info) === 'object' && (('upload' in info) || ('download' in info) ||
		    ('total' in info) || ('expire' in info)))
			return info;
	} catch (e) {}

	return null;
}

function merge_subscription_info(current, previous) {
	if (!current)
		return previous || null;
	if (!previous)
		return current;

	for (let field in ['upload', 'download', 'total', 'expire'])
		if (!(field in current) && (field in previous))
			current[field] = previous[field];

	return current;
}

function cleanup_subscription_info() {
	let active_options = {};
	for (let url in all_subscription_urls)
		active_options[subscription_info_option(url)] = true;

	const subscription = uci.get_all(uciconfig, ucisubscription) || {};
	for (let option in keys(subscription))
		if (match(option, /^subinfo_/) && !active_options[option])
			uci.delete(uciconfig, ucisubscription, option);
}

function apply_sing_box_tls(config, outbound) {
	const tls = outbound.tls;
	if (type(tls) !== 'object')
		return;

	config.tls = (tls.enabled === false) ? '0' : '1';
	config.tls_sni = tls.server_name;
	config.tls_insecure = bool_to_uci(tls.insecure);
	config.tls_alpn = normalize_alpn(tls.alpn);
	config.tls_utls = sing_features.with_utls ? tls.utls?.fingerprint : null;
	config.tls_reality = tls.reality ? '1' : '0';
	config.tls_reality_public_key = tls.reality?.public_key;
	config.tls_reality_short_id = tls.reality?.short_id;
}

function apply_sing_box_transport(config, outbound) {
	const transport = outbound.transport;
	if (type(transport) !== 'object')
		return;

	config.transport = transport.type;
	switch (transport.type) {
	case 'ws':
		config.ws_path = transport.path;
		config.ws_host = get_header_host(transport.headers);
		config.websocket_early_data = to_string(transport.max_early_data);
		config.websocket_early_data_header = transport.early_data_header_name;
		break;
	case 'grpc':
		config.grpc_servicename = transport.service_name;
		break;
	case 'http':
		config.http_path = normalize_first(transport.path);
		config.http_host = normalize_host_list(get_header_host(transport.headers) || transport.host);
		config.http_method = transport.method;
		break;
	case 'httpupgrade':
		config.httpupgrade_host = get_header_host(transport.headers) || transport.host;
		config.http_path = normalize_first(transport.path);
		break;
	}
}

function parse_sing_box_outbound(outbound) {
	if (type(outbound) !== 'object')
		return null;

	let config;
	const port = to_string(outbound.server_port || outbound.port);

	switch (outbound.type) {
	case 'anytls':
		config = {
			label: outbound.tag,
			type: 'anytls',
			address: outbound.server,
			port,
			password: outbound.password,
			tls: '1'
		};
		break;
	case 'vmess':
		config = {
			label: outbound.tag,
			type: 'vmess',
			address: outbound.server,
			port,
			uuid: outbound.uuid,
			vmess_alterid: to_string(outbound.alter_id),
			vmess_encrypt: outbound.security,
			packet_encoding: outbound.packet_encoding
		};
		break;
	case 'vless':
		config = {
			label: outbound.tag,
			type: 'vless',
			address: outbound.server,
			port,
			uuid: outbound.uuid,
			vless_flow: outbound.flow,
			packet_encoding: outbound.packet_encoding
		};
		break;
	case 'trojan':
		config = {
			label: outbound.tag,
			type: 'trojan',
			address: outbound.server,
			port,
			password: outbound.password,
			tls: '1'
		};
		break;
	case 'shadowsocks':
		config = {
			label: outbound.tag,
			type: 'shadowsocks',
			address: outbound.server,
			port,
			shadowsocks_encrypt_method: outbound.method,
			password: outbound.password,
			shadowsocks_plugin: outbound.plugin,
			shadowsocks_plugin_opts: outbound.plugin_opts
		};
		break;
	case 'hysteria':
		config = {
			label: outbound.tag,
			type: 'hysteria',
			address: outbound.server,
			port,
			hysteria_hopping_port: outbound.server_ports,
			hysteria_auth_type: outbound.auth_str ? 'string' : (outbound.auth ? 'base64' : null),
			hysteria_auth_payload: outbound.auth_str || outbound.auth,
			hysteria_obfs_password: outbound.obfs,
			hysteria_down_mbps: to_string(outbound.down_mbps),
			hysteria_up_mbps: to_string(outbound.up_mbps),
			tls: '1'
		};
		break;
	case 'hysteria2':
		config = {
			label: outbound.tag,
			type: 'hysteria2',
			address: outbound.server,
			port,
			password: outbound.password,
			hysteria_hopping_port: outbound.server_ports,
			hysteria_down_mbps: to_string(outbound.down_mbps),
			hysteria_up_mbps: to_string(outbound.up_mbps),
			hysteria_obfs_type: outbound.obfs?.type,
			hysteria_obfs_password: outbound.obfs?.password,
			tls: '1'
		};
		break;
	case 'tuic':
		config = {
			label: outbound.tag,
			type: 'tuic',
			address: outbound.server,
			port,
			uuid: outbound.uuid,
			password: outbound.password,
			tuic_congestion_control: outbound.congestion_control,
			tuic_udp_relay_mode: outbound.udp_relay_mode,
			tuic_udp_over_stream: bool_to_uci(outbound.udp_over_stream),
			tuic_enable_zero_rtt: bool_to_uci(outbound.zero_rtt_handshake),
			tuic_heartbeat: to_string(outbound.heartbeat),
			tls: '1'
		};
		break;
	case 'socks':
		config = {
			label: outbound.tag,
			type: 'socks',
			address: outbound.server,
			port,
			username: outbound.username,
			password: outbound.password,
			socks_version: outbound.version || '5'
		};
		break;
	case 'http':
		config = {
			label: outbound.tag,
			type: 'http',
			address: outbound.server,
			port,
			username: outbound.username,
			password: outbound.password
		};
		break;
	case 'ssh':
		config = {
			label: outbound.tag,
			type: 'ssh',
			address: outbound.server,
			port,
			username: outbound.user || outbound.username,
			password: outbound.password,
			ssh_client_version: outbound.client_version,
			ssh_host_key: normalize_list(outbound.host_key),
			ssh_host_key_algo: normalize_list(outbound.host_key_algorithms),
			ssh_priv_key: normalize_list(outbound.private_key),
			ssh_priv_key_pp: outbound.private_key_passphrase
		};
		break;
	case 'wireguard':
		config = {
			label: outbound.tag,
			type: 'wireguard',
			address: outbound.server,
			port,
			wireguard_local_address: normalize_list(outbound.local_address || outbound.address),
			wireguard_private_key: outbound.private_key,
			wireguard_peer_public_key: outbound.peer_public_key,
			wireguard_pre_shared_key: outbound.pre_shared_key,
			wireguard_reserved: normalize_list(outbound.reserved),
			wireguard_mtu: to_string(outbound.mtu),
			wireguard_persistent_keepalive_interval: to_string(outbound.persistent_keepalive_interval)
		};
		break;
	default:
		return null;
	}

	if (!isEmpty(config)) {
		apply_sing_box_tls(config, outbound);
		apply_sing_box_transport(config, outbound);
		config.tcp_fast_open = bool_to_uci(outbound.tcp_fast_open);
		config.tcp_multi_path = bool_to_uci(outbound.tcp_multi_path);
		config.udp_fragment = bool_to_uci(outbound.udp_fragment);
	}

	return config;
}

function parse_uri(uri) {
	let config, url, params;

	if (type(uri) === 'object') {
		if (uri.nodetype === 'mihomo') {
			return parse_mihomo_proxy(uri);
		}
		if (uri.nodetype === 'sing-box') {
			return parse_sing_box_outbound(uri);
		}
		if (uri.nodetype === 'sip008') {
			/* https://shadowsocks.org/guide/sip008.html */
			config = {
				label: uri.remarks,
				type: 'shadowsocks',
				address: uri.server,
				port: uri.server_port,
				shadowsocks_encrypt_method: uri.method,
				password: uri.password,
				shadowsocks_plugin: uri.plugin,
				shadowsocks_plugin_opts: uri.plugin_opts
			};
		}
	} else if (type(uri) === 'string') {
		uri = split(trim(uri), '://');

		switch (uri[0]) {
	case 'anytls':
		/* https://github.com/anytls/anytls-go/blob/v0.0.8/docs/uri_scheme.md */
		url = parseURL('http://' + uri[1]) || {};
		params = url.searchParams || {};
		let anytls_fp = params.fp || params.fingerprint;
		if (anytls_fp === 'none' || anytls_fp === 'disable' || anytls_fp === 'disabled')
			anytls_fp = null;
		else if (!has_value(anytls_fp))
			anytls_fp = 'chrome';

		config = {
			label: url.hash ? urldecode(url.hash) : null,
			type: 'anytls',
			address: url.hostname,
			port: url.port,
			password: urldecode(url.username),
			tls: '1',
			tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
			tls_sni: params.sni,
			tls_utls: sing_features.with_utls ? anytls_fp : null
		};

		break;
		case 'http':
		case 'https':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'http',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				tls: (uri[0] === 'https') ? '1' : '0'
			};

			break;
		case 'hysteria':
			/* https://github.com/HyNetwork/hysteria/wiki/URI-Scheme */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic || (params.protocol && params.protocol !== 'udp')) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria',
				address: url.hostname,
				port: url.port,
				hysteria_hopping_port: normalize_hysteria_hopping_port(params.mport),
				hysteria_protocol: params.protocol || 'udp',
				hysteria_auth_type: params.auth ? 'string' : null,
				hysteria_auth_payload: params.auth,
				hysteria_obfs_password: params.obfsParam,
				hysteria_down_mbps: params.downmbps,
				hysteria_up_mbps: params.upmbps,
				tls: '1',
				tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
				tls_sni: params.peer,
				tls_alpn: params.alpn
			};

			break;
		case 'hysteria2':
		case 'hy2':
			/* https://v2.hysteria.network/docs/developers/URI-Scheme/ */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria2',
				address: url.hostname,
				port: url.port,
				password: url.username ? (
					urldecode(url.username + (url.password ? (':' + url.password) : ''))
				) : null,
				hysteria_hopping_port: normalize_hysteria_hopping_port(params.mport),
				hysteria_obfs_type: params.obfs,
				hysteria_obfs_password: params['obfs-password'],
				tls: '1',
				tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
				tls_sni: params.sni
			};

			break;
		case 'socks':
		case 'socks4':
		case 'socks4a':
		case 'socsk5':
		case 'socks5h':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'socks',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				socks_version: (match(uri[0], /4/)) ? '4' : '5'
			};

			break;
		case 'ss':
			/* "Lovely" Shadowrocket format */
			const ss_suri = split(uri[1], '#');
			let ss_slabel = '';
			if (length(ss_suri) <= 2) {
				if (length(ss_suri) === 2)
					ss_slabel = '#' + urlencode(ss_suri[1]);
				if (decodeBase64Str(ss_suri[0]))
					uri[1] = decodeBase64Str(ss_suri[0]) + ss_slabel;
			}

			/* Legacy format is not supported, it should be never appeared in modern subscriptions */
			/* https://github.com/shadowsocks/shadowsocks-org/commit/78ca46cd6859a4e9475953ed34a2d301454f579e */

			/* SIP002 format https://shadowsocks.org/guide/sip002.html */
			url = parseURL('http://' + uri[1]) || {};

			let ss_userinfo = {};
			if (url.username && url.password)
				/* User info encoded with URIComponent */
				ss_userinfo = [url.username, urldecode(url.password)];
			else if (url.username)
				/* User info encoded with base64 */
				ss_userinfo = split(decodeBase64Str(urldecode(url.username)), ':', 2);

			let ss_plugin, ss_plugin_opts;
			if (url.search && url.searchParams.plugin) {
				const ss_plugin_info = split(url.searchParams.plugin, ';', 2);
				ss_plugin = ss_plugin_info[0];
				if (ss_plugin === 'simple-obfs')
					/* Fix non-standard plugin name */
					ss_plugin = 'obfs-local';
				ss_plugin_opts = ss_plugin_info[1];
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'shadowsocks',
				address: url.hostname,
				port: url.port,
				shadowsocks_encrypt_method: ss_userinfo[0],
				password: ss_userinfo[1],
				shadowsocks_plugin: ss_plugin,
				shadowsocks_plugin_opts: ss_plugin_opts
			};

			break;
		case 'trojan':
			/* https://p4gefau1t.github.io/trojan-go/developer/url/ */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'trojan',
				address: url.hostname,
				port: url.port,
				password: urldecode(url.username),
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: '1',
				tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
				tls_sni: params.sni
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		case 'tuic':
			/* https://github.com/daeuniverse/dae/discussions/182 */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'tuic',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				password: url.password ? urldecode(url.password) : null,
				tuic_congestion_control: params.congestion_control,
				tuic_udp_relay_mode: params.udp_relay_mode,
				tls: '1',
				tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
			};

			break;
		case 'vless':
			/* https://github.com/XTLS/Xray-core/discussions/716 */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			/* Unsupported protocol */
			if (params.type === 'kcp') {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				return null;
			} else if (params.type === 'quic' && ((params.quicSecurity && params.quicSecurity !== 'none') || !sing_features.with_quic)) {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'vless',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: (params.security in ['tls', 'xtls', 'reality']) ? '1' : '0',
				tls_insecure: (params.insecure === '1' || params.allowInsecure === '1') ? '1' : '0',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
				tls_reality: (params.security === 'reality') ? '1' : '0',
				tls_reality_public_key: params.pbk ? urldecode(params.pbk) : null,
				tls_reality_short_id: params.sid,
				tls_utls: sing_features.with_utls ? params.fp : null,
				vless_flow: (params.security in ['tls', 'reality']) ? params.flow : null,
				/* 节点自己声明的 UDP 编码优先级最高（Xray 分享链接里叫
				   packetEncoding，v2rayN 等也接受 packet-encoding 别名）。
				   0.2.2 前完全没读：一律被下面的全局兜底覆盖成 xudp，
				   于是机场显式写了 packetEncoding=none 的节点被改成 xudp
				   —— 能连上但 UDP 不通（UDP Blocked），表现为「节点拉下来了
				   却用不了」。只有真的没声明时才让全局默认值生效。 */
				packet_encoding: normalize_packet_encoding(params.packetEncoding || params['packet-encoding'])
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'http':
			case 'tcp':
				if (params.type === 'http' || params.headerType === 'http') {
					config.http_host = params.host ? split(urldecode(params.host), ',') : null;
					config.http_path = params.path ? urldecode(params.path) : null;
				}
				break;
			case 'httpupgrade':
				config.httpupgrade_host = params.host ? urldecode(params.host) : null;
				config.http_path = params.path ? urldecode(params.path) : null;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		case 'vmess':
			/* "Lovely" shadowrocket format */
			if (match(uri, /&/)) {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			}

			/* https://github.com/2dust/v2rayN/wiki/Description-of-VMess-share-link */
			try {
				uri = json(decodeBase64Str(uri[1])) || {};
			} catch(e) {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			}

			if (uri.v != '2') {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			/* Unsupported protocol */
			} else if (uri.net === 'kcp') {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], uri.ps || uri.add));
				return null;
			} else if (uri.net === 'quic' && ((uri.type && uri.type !== 'none') || uri.path || !sing_features.with_quic)) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], uri.ps || uri.add));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}
			/*
			 * https://www.v2fly.org/config/protocols/vmess.html#vmess-md5-%E8%AE%A4%E8%AF%81%E4%BF%A1%E6%81%AF-%E6%B7%98%E6%B1%B0%E6%9C%BA%E5%88%B6
			 * else if (uri.aid && int(uri.aid) !== 0) {
			 * 	log(sprintf('Skipping unsupported %s node: %s.', uri[0], uri.ps || uri.add));
			 * 	return null;
			 * }
			 */

			config = {
				label: uri.ps ? urldecode(uri.ps) : null,
				type: 'vmess',
				address: uri.add,
				port: uri.port,
				uuid: uri.id,
				vmess_alterid: uri.aid,
				vmess_encrypt: uri.scy || 'auto',
				vmess_global_padding: '1',
				/* vmess JSON 里的 UDP 编码（v2rayN 写 packetEncoding）；
				   没写就用全局默认值，见下面统一兜底那段的注释。 */
				packet_encoding: normalize_packet_encoding(uri.packetEncoding || uri['packet-encoding']),
				transport: (uri.net !== 'tcp') ? uri.net : null,
				tls: (uri.tls === 'tls') ? '1' : '0',
				tls_sni: uri.sni || uri.host,
				tls_alpn: uri.alpn ? split(uri.alpn, ',') : null,
				tls_utls: sing_features.with_utls ? uri.fp : null
			};
			switch (uri.net) {
			case 'grpc':
				config.grpc_servicename = uri.path;
				break;
			case 'h2':
			case 'tcp':
				if (uri.net === 'h2' || uri.type === 'http') {
					config.transport = 'http';
					config.http_host = uri.host ? split(uri.host, ',') : null;
					config.http_path = uri.path;
				}
				break;
			case 'httpupgrade':
				config.httpupgrade_host = uri.host;
				config.http_path = uri.path;
				break;
			case 'ws':
				config.ws_host = uri.host;
				config.ws_path = uri.path;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		}
	}

	if (!isEmpty(config)) {
		if (config.address)
			config.address = replace(config.address, /\[|\]/g, '');

		if (!validation('host', config.address) || !validation('port', config.port)) {
			log(sprintf('Skipping invalid %s node: %s.', config.type, config.label || 'NULL'));
			return null;
		} else if (!config.label)
			config.label = (validation('ip6addr', config.address) ?
				`[${config.address}]` : config.address) + ':' + config.port;
	}

	return config;
}

function split_top_level(str, separator) {
	let items = [], current = '', quote = null, depth = 0;

	for (let i = 0; i < length(str); i++) {
		const ch = substr(str, i, 1);

		if (quote) {
			current += ch;
			if (ch === quote)
				quote = null;
			continue;
		}

		if (ch === '"' || ch === "'") {
			quote = ch;
			current += ch;
			continue;
		}

		if (ch === '[' || ch === '{')
			depth++;
		else if (ch === ']' || ch === '}')
			depth--;

		if (ch === separator && depth === 0) {
			push(items, trim(current));
			current = '';
		} else {
			current += ch;
		}
	}

	if (length(trim(current)))
		push(items, trim(current));

	return items;
}

function strip_yaml_quotes(value) {
	value = trim(value);
	if ((match(value, /^".*"$/) || match(value, /^'.*'$/)) && length(value) >= 2)
		return substr(value, 1, length(value) - 2);

	return value;
}

function parse_yaml_value(value) {
	value = trim(value || '');
	if (value === '' || value === 'null' || value === '~')
		return null;

	if (match(value, /^\[.*\]$/)) {
		let arr = [];
		const inner = substr(value, 1, length(value) - 2);
		for (let item in split_top_level(inner, ','))
			push(arr, parse_yaml_value(item));
		return arr;
	}

	if (match(value, /^\{.*\}$/))
		return parse_yaml_inline_object(value);

	value = strip_yaml_quotes(value);
	if (value === 'true')
		return true;
	if (value === 'false')
		return false;

	return value;
}

function parse_yaml_key_value(line) {
	const m = match(line, /^([^:]+):\s*(.*)$/);
	if (!m)
		return null;

	return {
		key: strip_yaml_quotes(trim(m[1])),
		value: m[2]
	};
}

function parse_yaml_inline_object(text) {
	let obj = {};
	text = trim(text);
	text = substr(text, 1, length(text) - 2);

	for (let part in split_top_level(text, ',')) {
		const kv = parse_yaml_key_value(part);
		if (kv)
			obj[kv.key] = parse_yaml_value(kv.value);
	}

	return obj;
}

function yaml_indent(line) {
	const m = match(line, /^(\s*)/);
	return m ? length(m[1]) : 0;
}

function stack_pop(stack) {
	let next = [];
	for (let i = 0; i < length(stack) - 1; i++)
		push(next, stack[i]);
	return next;
}

function parse_mihomo_yaml(text) {
	if (isEmpty(text) || type(text) !== 'string')
		return null;

	let in_proxies = false, proxies = [], current = null, stack = [];

	for (let raw_line in split(text, '\n')) {
		raw_line = replace(raw_line, /\r$/, '');
		let line = trim(raw_line);

		if (!line || match(line, /^#/))
			continue;

		if (line === 'proxies:' || match(line, /^proxies:\s*$/)) {
			in_proxies = true;
			continue;
		}
		if (!in_proxies)
			continue;

		if (yaml_indent(raw_line) === 0 && match(line, /^[A-Za-z0-9_-]+:\s*$/))
			break;

		if (match(line, /^-\s*/)) {
			if (current)
				push(proxies, current);

			current = {};
			stack = [{ indent: yaml_indent(raw_line), obj: current }];
			line = replace(line, /^-\s*/, '');

			if (!line)
				continue;

			if (match(line, /^\{.*\}$/)) {
				current = parse_yaml_inline_object(line);
				current.nodetype = 'mihomo';
				stack = [{ indent: yaml_indent(raw_line), obj: current }];
				continue;
			}
		}

		if (!current)
			continue;

		const kv = parse_yaml_key_value(line);
		if (!kv)
			continue;

		const indent = yaml_indent(raw_line);
		while (length(stack) > 1 && indent <= stack[length(stack) - 1].indent)
			stack = stack_pop(stack);

		const parent = stack[length(stack) - 1].obj;
		if (trim(kv.value) === '') {
			parent[kv.key] = {};
			push(stack, { indent, obj: parent[kv.key] });
		} else {
			parent[kv.key] = parse_yaml_value(kv.value);
		}
	}

	if (current)
		push(proxies, current);

	for (let proxy in proxies)
		proxy.nodetype = 'mihomo';

	return length(proxies) ? proxies : null;
}

function main() {
	cleanup_subscription_info();

	/* 定时任务由 update_crond.sh 先写一个标记文件，这里据此区分触发来源：
	 * 否则日志里只有「Successfully updated subscriptions.」，用户没法判断
	 * 到底是 cron 到点跑了，还是自己点了按钮。 */
	const scheduled = !isEmpty(readfile(RUN_DIR + '/schedule-run') || ''),
	      trigger = cli_source ||
	                (provider_update_id ? '面板单个机场「更新」按钮' :
	                (scheduled ? '定时任务（cron，update_crond.sh）' : (via_proxy === '1' ? '手动（经代理）' : '手动（终端/SSH）')));
	log(sprintf('==== 订阅更新开始：来源=%s，共 %d 个订阅 ====', trigger, length(subscription_urls)));

	/* 抓取方式必须在日志开头就能对上：这个开关在 0.2.04 之前是死的，
	   日志里骂「到底走没走代理」根本无从判断。 */
	log(sprintf('Fetch mode: %s.', proxy_url
		? sprintf('proxy %s, fallback to direct', proxy_url)
		: 'direct'));

	/* 全程**不停服务**（用户 0.2.2 定稿）：下载、解析、写 uci 全部成功才在
	 * main() 末尾 stop+start 一次让新节点生效；任何一步失败都在不动服务的
	 * 前提下退出。旧版在下载前就 `init_action('homeproxy','stop')`（所谓
	 * 「绕过自身代理」），失败再 start 回来——更新不成功也会把当前服务断
	 * 一次流，面板上就是「点了更新、代理闪断一下、节点却没变」。 */
	for (let url in subscription_urls) {
		url = replace(url, /#.*$/, '');
		const groupHash = md5(url);
		node_cache[groupHash] = {};

		/* 本次订阅按协议类型的解析结果计数。机场「某个协议整批没了」时，
		   第一手信息就该是「到底解析出了哪些类型、各几条」，而不是让用户
		   数 uci 里剩几个节点反推——0.2.03 的 vless 事故就是这么绕远的。 */
		const type_tally = {};

		let response = wGETResponse(url, user_agent, proxy_url);
		let res = response?.body;

		/* 代理这一跳失败时**不能**让整次更新就此结束：退回直连再试一次。
		   「有 4 个机场要海外」是常态，但总有 1 个国内能拉；而 sing-box
		   没起、5330 没人监听时代理必然失败（回环立刻回 exit=7，不会拖
		   时间），这时直连才是唯一有希望的路径。两次都失败才记 Failed，
		   并且代理与直连的原因都要能看见。 */
		if (proxy_url && isEmpty(res)) {
			log(sprintf('Proxy fetch failed for %s, retrying directly.', url));

			response = wGETResponse(url, user_agent);
			res = response?.body;
		}

		if (isEmpty(res)) {
			/* ⚠️ 抓不到正文时**必须**留下「为什么」。0.2.03 现场这里只打一行
			   `Failed to fetch resources`，exitcode 与 stderr 全丢，于是
			   「DNS 解析失败 / TLS 失败 / 服务器 4xx 被 curl -f 吞掉正文 /
			   环境里根本没有下载器（127）」四种情况在日志上长得一模一样，
			   只能让用户在设备上手动重敲 curl 反推。排查纪律 §8：诊断内建。

			   为什么连 stderr 一起打：curl 的失败原因（`curl: (6) Could not
			   resolve host` 等）只出现在 stderr 里；而成功但正文为空时，
			   stderr 里是 -D 写过去的响应头，同样能说明服务器回了什么。 */
			let why = 'no response object';

			if (response) {
				let err = replace(trim(sprintf('%s', response.headers || '')), '\n', ' | ');

				if (length(err) > 300)
					err = substr(err, 0, 300) + '...';

				why = sprintf('exit=%d, bytes=%d, stderr=%s',
					response.exitcode, response.size, length(err) ? err : '(empty)');
			}

			log(sprintf('Failed to fetch resources from %s%s (%s).', url,
				proxy_url ? sprintf(' via %s', proxy_url) : '', why));
			continue;
		}

		/* 正文超过采集上限（16 MiB）时会被截断：必须显式告警，否则用户只
		   看到「节点少了」，却不知道是响应太大而不是订阅本身的问题。 */
		if (response.truncated)
			log(sprintf('Warning: the response from %s exceeded the 16 MiB limit and was truncated; the node list may be incomplete.', url));

		let nodes;
		try {
			const parsed = json(res);
			if (type(parsed?.servers) === 'array') {
				nodes = parsed.servers;

				/* Shadowsocks SIP008 format */
				if (nodes[0].server && nodes[0].method)
					map(nodes, (_, i) => nodes[i].nodetype = 'sip008');
			} else if (type(parsed?.proxies) === 'array') {
				nodes = parsed.proxies;
				map(nodes, (_, i) => nodes[i].nodetype = 'mihomo');
			} else if (type(parsed?.outbounds) === 'array') {
				nodes = parsed.outbounds;
				map(nodes, (_, i) => nodes[i].nodetype = 'sing-box');
			} else if (type(parsed) === 'array') {
				nodes = parsed;
				if (nodes[0]?.server && nodes[0]?.method)
					map(nodes, (_, i) => nodes[i].nodetype = 'sip008');
				else if (nodes[0]?.type && nodes[0]?.server)
					map(nodes, (_, i) => nodes[i].nodetype = 'sing-box');
			} else {
				nodes = [];
			}
		} catch(e) {
			nodes = parse_mihomo_yaml(res);
			if (isEmpty(nodes)) {
				nodes = decodeBase64Str(res);
				const decoded_nodes = parse_mihomo_yaml(nodes);
				if (!isEmpty(decoded_nodes))
					nodes = decoded_nodes;
				else
					nodes = nodes ? split(trim(replace(nodes, / /g, '_')), '\n') : [];
			}
		}

		let count = 0;
		for (let node in nodes) {
			let config = null;
			if (!isEmpty(node)) {
				/* 任意一条坏节点（畸形 base64、非预期 JSON 结构、缺字段）都只
				   跳过它自己：解析异常漏出去会让整条订阅中断，用户看到的是
				   「这次更新一个节点都没有」。 */
				try {
					config = parse_uri(node);
				} catch (e) {
					log(sprintf('Skipping unparsable node entry in %s: %s', url, trim(sprintf('%s', e))));
					config = null;
				}
			}
			if (isEmpty(config))
				continue;

			const label = config.label;
			config.label = null;
			const confHash = md5(sprintf('%J', config)),
			      nameHash = md5(label);
			config.label = label;

			if (filter_check(config.label))
				log(sprintf('Skipping blacklist node: %s.', config.label));
			else if (node_cache[groupHash][confHash] || node_cache[groupHash][nameHash])
				log(sprintf('Skipping duplicate node: %s.', config.label));
			else {
				if (config.tls === '1' && allow_insecure === '1')
					config.tls_insecure = '1';
				/* ⚠️ 这里**不能**用 isEmpty() 判断「节点有没有声明」：显式
				   packetEncoding=none 归一化后就是空串 ''，而 isEmpty('') 为
				   真 → 全局默认值会把用户的 none 覆盖回 xudp，修改白做。
				   归一函数的契约：null = 没声明、'' = 显式 none，必须分开。
				   也不要再补 `undefined` 判据：ucode 没有这个关键字，
				   模块里读它直接抛 access to undeclared variable。 */
				if (config.type in ['vless', 'vmess'] && config.packet_encoding === null)
					config.packet_encoding = packet_encoding;

				config.grouphash = groupHash;
				push(node_result, []);
				push(node_result[length(node_result)-1], config);
				node_cache[groupHash][confHash] = config;
				node_cache[groupHash][nameHash] = config;

				type_tally[config.type] = (type_tally[config.type] || 0) + 1;
				count++;
			}
		}

		/* 「拿到 M 行、解析出 N 个」之外再给出按协议的明细：用户说「某个协议
		   拉不到」时，这一行直接区分「根本没解析出来」与「解析出来又被过滤
		   掉了」。为排查服务，不要删。 */
		let type_parts = [];
		map(keys(type_tally), (t) => push(type_parts, sprintf('%s=%d', t, type_tally[t])));
		log(sprintf('Node types from %s: %s.', url, length(type_parts) ? join(' ', type_parts) : 'none'));

		if (count == 0)
			log(sprintf('No valid node found in %s.', url));
		else {
			const info_option = subscription_info_option(url),
			      display_name = subscription_display_name(url);
			const previous_info = previous_subscription_info(info_option);
			let subscription_info = parse_subscription_userinfo(response.headers);

			if (!subscription_info || !('total' in subscription_info) || !('expire' in subscription_info)) {
				const fallback_headers = wGETHeaders(url, 'clash.meta', proxy_url);
				const fallback_info = parse_subscription_userinfo(fallback_headers);
				if (fallback_info) {
					if (subscription_info)
						log(sprintf('Supplemented subscription user info for %s with Clash Meta user agent.', display_name));
					else
						log(sprintf('Fetched subscription user info for %s with Clash Meta user agent.', display_name));
					subscription_info = merge_subscription_info(subscription_info, fallback_info);
				}
			}

			if (!subscription_info) {
				subscription_info = previous_info || {};
				if (length(subscription_info))
					log(sprintf('Subscription %s did not return user info; keeping the previous values.', display_name));
				else
					log(sprintf('Subscription %s did not return Subscription-Userinfo.', display_name));
			} else {
				if (!('expire' in subscription_info))
					log(sprintf('Subscription %s returned traffic data without an expire value%s.', display_name,
						previous_info && ('expire' in previous_info) ? '; keeping the previous value' : ''));
				if (!('total' in subscription_info))
					log(sprintf('Subscription %s returned user info without a total value%s.', display_name,
						previous_info && ('total' in previous_info) ? '; keeping the previous value' : ''));
				subscription_info = merge_subscription_info(subscription_info, previous_info);
			}

			subscription_info.updated_at = getTime();
			uci.set(uciconfig, ucisubscription, info_option, sprintf('%.J', subscription_info));

			log(sprintf('Successfully fetched %s nodes of total %s from %s.', count, length(nodes), url));
		}
	}

	if (isEmpty(node_result)) {
		log('Failed to update subscriptions: no valid node found.');

		/* 服务从未被停过（见 main() 开头的注释），失败时什么都不用恢复。
		 * 旧版这里要 start 回来，是因为它先前把服务停了。 */
		return false;
	}

	let added = 0, removed = 0;
	uci.foreach(uciconfig, ucinode, (cfg) => {
		/* Nodes created by the user */
		if (!cfg.grouphash)
			return null;

		/* A provider update must not touch nodes from other subscriptions. */
		if (!(cfg.grouphash in node_cache))
			return null;

		/* Empty object - failed to fetch nodes */
		if (length(node_cache[cfg.grouphash]) === 0)
			return null;

		if (!node_cache[cfg.grouphash] || !node_cache[cfg.grouphash][cfg['.name']]) {
			uci.delete(uciconfig, cfg['.name']);
			removed++;

			log(sprintf('Removing node: %s.', cfg.label || cfg['name']));
		} else {
			map(keys(cfg), (v) => {
				if (v in node_cache[cfg.grouphash][cfg['.name']])
					uci.set(uciconfig, cfg['.name'], v, node_cache[cfg.grouphash][cfg['.name']][v]);
				else
					uci.delete(uciconfig, cfg['.name'], v);
			});
			node_cache[cfg.grouphash][cfg['.name']].isExisting = true;
		}
	});
	for (let nodes in node_result)
		map(nodes, (node) => {
			if (node.isExisting)
				return null;

			const nameHash = md5(node.label);
			uci.set(uciconfig, nameHash, 'node');
			map(keys(node), (v) => uci.set(uciconfig, nameHash, v, node[v]));

			added++;
			log(sprintf('Adding node: %s.', node.label));
		});
	uci.commit(uciconfig);

	/* 成功才重启：到这里 uci 已 commit，stop+start 让新节点进内核。服务在
	 * 整个更新过程中一直活着——只有这一处会碰它，且只在成功路径上。 */
	let need_restart = true;
	if (!isEmpty(main_node)) {
		const first_server = uci.get_first(uciconfig, ucinode);
		if (first_server) {
			let main_urltest_nodes;
			if (main_node === 'urltest') {
				main_urltest_nodes = filter(uci.get(uciconfig, ucimain, 'main_urltest_nodes'), (v) => {
					if (!uci.get(uciconfig, v)) {
						log(sprintf('Node %s is gone, removing from urltest list.', v));
						return false;
					}
					return true;
				});
			}

			if ((main_node === 'urltest') ? !length(main_urltest_nodes) : !uci.get(uciconfig, main_node)) {
				uci.set(uciconfig, ucimain, 'main_node', first_server);
				uci.commit(uciconfig);
				need_restart = true;

				log('Main node is gone, switching to the first node.');
			}

			if (!isEmpty(main_udp_node) && main_udp_node !== 'same') {
				let main_udp_urltest_nodes;
				if (main_udp_node === 'urltest') {
					main_udp_urltest_nodes = filter(uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes'), (v) => {
						if (!uci.get(uciconfig, v)) {
							log(sprintf('Node %s is gone, removing from urltest list.', v));
							return false;
						}
						return true;
					});
				}

				if ((main_udp_node === 'urltest') ? !length(main_udp_urltest_nodes) : !uci.get(uciconfig, main_udp_node)) {
					uci.set(uciconfig, ucimain, 'main_udp_node', first_server);
					uci.commit(uciconfig);
					need_restart = true;

					log('Main UDP node is gone, switching to the first node.');
				}
			}
		} else {
			uci.set(uciconfig, ucimain, 'main_node', 'nil');
			uci.set(uciconfig, ucimain, 'main_udp_node', 'nil');
			uci.commit(uciconfig);
			need_restart = true;

			log('No available node, disable tproxy.');
		}
	}

	if (need_restart) {
		log('Restarting service...');
		init_action('homeproxy', 'stop');
		init_action('homeproxy', 'start');
	}

	log(sprintf('%s nodes added, %s removed.', added, removed));
	log('Successfully updated subscriptions.');
	log(sprintf('==== 订阅更新完成：新增 %s 个节点，删除 %s 个，共 %d 个订阅 ====', added, removed, length(subscription_urls)));
}

if (provider_update_id && isEmpty(subscription_urls)) {
	log(sprintf('Provider %s does not match any subscription.', provider_update_id));
	exit(1);
}

if (!isEmpty(subscription_urls))
	try {
		if (call(main) === false)
			exit(1);
	} catch(e) {
		log('[FATAL ERROR] An error occurred during updating subscriptions:');
		log(sprintf('%s: %s', e.type, e.message));
		log(e.stacktrace[0].context);

		/* 异常 ≠ 成功：不重启服务（用户 0.2.2 定稿——更新不成功不得影响
		 * 当前服务）。uci 可能改了一半，但没 commit 的改动不会生效；
		 * 已 commit 的部分（节点增删）会在下次成功更新或手动重载时收敛。
		 * 旧版无条件 stop+start：更新崩了还把正在跑的代理断一次流。 */
		exit(1);
	}
