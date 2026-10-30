function __ucode_wrap() {
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */




const ubus = connect();

/* const features = ubus.call('luci.homeproxy', 'singbox_get_features') || {}; */

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      ucicontrol = 'control',
      uciclashapi = 'clash_api',
      ucintp = 'ntp',
      ucicache = 'cache';

const ucidnssetting = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule';

const uciroutingsetting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule';

const ucinode = 'node';
const uciruleset = 'ruleset';
const RULESET_DIR = HP_DIR + '/ruleset';

let http_client_map = {};

/* Forward declaration.
 *
 * ucode resolves identifiers at compile time, so a plain `function` declared
 * further down is NOT visible to a function defined above it. filter_group_nodes()
 * (line ~280) calls section_display_name(), which is defined at line ~382 —
 * that produced at runtime:
 *   Reference error: access to undeclared variable section_display_name
 * which aborted the whole client config generation ("生成客户端配置失败")
 * and left the service unable to start.
 *
 * Declaring the binding here and assigning the implementation at its original
 * position keeps every call site bound without reordering the file. */
let section_display_name = null;

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';

function normalize_list(value) {
	if (isEmpty(value))
		return [];
	if (type(value) === 'array')
		return value;
	return [value];
}

function ruleset_file_name(tag, format) {
	let filename = replace(tag || 'ruleset', /[^A-Za-z0-9_.-]+/g, '_');
	if (isEmpty(filename))
		filename = 'ruleset';

	return filename + ((format === 'source') ? '.json' : '.srs');
}

function ruleset_default_path(tag, format) {
	return RULESET_DIR + '/' + ruleset_file_name(tag, format);
}

/* True when a *validated* local copy of a remote rule-set exists, so the
   generator can emit `type: local` instead of `type: remote`.
   Checking the magic number (not just the size) matters: a mirror error page
   is small but non-empty, sing-box saves it verbatim and then the binary
   decoder aborts the whole instance while initialising. fetch_rulesets.sh
   fills this cache out of band, before start-up. */
function ruleset_local_ready(path, format) {
	if (isEmpty(path))
		return false;

	let fp = null;
	try {
		fp = open(path, 'r');
	} catch (e) {
		return false;
	}
	if (!fp)
		return false;

	let head = null;
	try {
		head = fp.read(8);
	} catch (e) {
		head = null;
	}
	try { fp.close(); } catch (e) {}

	if (!head || length(head) < 1)
		return false;

	/* `head` is a `bytes` value (fp.read returns bytes). Coerce it to a plain
	   string view so the magic-number / JSON checks do not depend on ucode's
	   bytes<->string equality semantics — `substr(bytes,0,3) === 'SRS'` would
	   otherwise be undefined behaviour and could silently fail, defeating the
	   whole local-cache optimisation (and falling back to remote downloads). */
	let s = sprintf('%s', head);
	if (format === 'source')
		return match(s, /^\s*[{\[]/) !== null;

	return substr(s, 0, 3) === 'SRS';
}

function ruleset_remote_path(path, tag, format) {
	if (isEmpty(path))
		return ruleset_default_path(tag, format);

	if (match(path, /\/$/))
		return path + ruleset_file_name(tag, format);

	return path;
}

/* Map a rule-set download detour (outbound tag) to a top-level http_client tag.
   Collects distinct detours so they can be declared once as http_clients.
   Replaces the deprecated download_detour field (sing-box 1.14). */
function dl_tag_for(detour) {
	if (isEmpty(detour))
		return 'dl-default';

	const tag = 'dl-' + detour;
	http_client_map[tag] = detour;
	return tag;
}

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode in ['proxy_mainland_china', 'global']) ? '9.9.9.9' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

let ntp_enabled = uci.get(uciconfig, ucintp, 'enabled'),
    ntp_server = uci.get(uciconfig, ucintp, 'server'),
    ntp_server_port = uci.get(uciconfig, ucintp, 'server_port'),
    ntp_interval = uci.get(uciconfig, ucintp, 'interval');

if (isEmpty(ntp_enabled) && isEmpty(ntp_server)) {
	ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server');
	ntp_enabled = !isEmpty(ntp_server) ? '1' : '0';
}

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

let cache_file_enabled, cache_file_path, cache_store_dns, cache_store_selected,
    main_node, main_udp_node, dedicated_udp_node, default_outbound, default_outbound_dns,
    domain_strategy, sniff_override, dns_server, china_dns_server, dns_default_strategy,
    dns_default_server, dns_disable_cache, dns_disable_cache_expire,
    dns_client_subnet, direct_domain_list,
    proxy_domain_list;

if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
	main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';
	dedicated_udp_node = !isEmpty(main_udp_node) && !(main_udp_node in ['same', main_node]);

	dns_server = uci.get(uciconfig, ucimain, 'dns_server');
	if (isEmpty(dns_server) || dns_server === 'wan')
		dns_server = wan_dns;

	if (routing_mode === 'bypass_mainland_china') {
		china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
		if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
			china_dns_server = wan_dns;
	}
	dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

	direct_domain_list = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
	if (direct_domain_list)
		direct_domain_list = split(direct_domain_list, /[\r\n]/);

	proxy_domain_list = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
	if (proxy_domain_list)
		proxy_domain_list = split(proxy_domain_list, /[\r\n]/);

	sniff_override = uci.get(uciconfig, uciinfra, 'sniff_override') || '1';
} else {
	/* DNS settings */
	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy');
	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server');
	dns_disable_cache = uci.get(uciconfig, ucidnssetting, 'disable_cache');
	dns_disable_cache_expire = uci.get(uciconfig, ucidnssetting, 'disable_cache_expire');
	dns_client_subnet = uci.get(uciconfig, ucidnssetting, 'client_subnet');

	/* Routing settings */
	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
	default_outbound_dns = uci.get(uciconfig, uciroutingsetting, 'default_outbound_dns') || 'default-dns';
	domain_strategy = uci.get(uciconfig, uciroutingsetting, 'domain_strategy');
	sniff_override = uci.get(uciconfig, uciroutingsetting, 'sniff_override');
}

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface');

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';

let self_mark, redirect_port, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack,
    udp_timeout;

if (routing_mode === 'custom')
	udp_timeout = uci.get(uciconfig, uciroutingsetting, 'udp_timeout');
else
	udp_timeout = uci.get(uciconfig, 'infra', 'udp_timeout');

if (match(proxy_mode, /redirect/)) {
	self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';
	redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '5331';
}
if (match(proxy_mode, /tproxy/))
	if (main_udp_node !== 'nil' || routing_mode === 'custom')
		tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';
if (match(proxy_mode, /tun/)) {
	tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
	tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
	tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
	tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
	tcpip_stack = 'system';
	if (routing_mode === 'custom')
		tcpip_stack = uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') || 'system';
}

/* Only the four levels the UI offers are accepted by sing-box. A hand-edited
   or restored config carrying anything else (e.g. "warning") would make
   `sing-box check` fail and the whole service refuse to start, so fall back
   to info instead of trusting UCI verbatim. */
const log_level_uci = uci.get(uciconfig, ucimain, 'log_level') || 'info';

const log_level = (log_level_uci == 'debug' || log_level_uci == 'info' ||
	log_level_uci == 'warn' || log_level_uci == 'error') ? log_level_uci : 'info';

cache_file_enabled = uci.get(uciconfig, ucicache, 'enabled');
cache_file_path = uci.get(uciconfig, ucicache, 'path');
cache_store_dns = uci.get(uciconfig, ucicache, 'store_dns');
cache_store_selected = uci.get(uciconfig, ucicache, 'store_selected');

let clash_api = null;
/* UCI config end */

/* Config helper start */
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function parse_dnsserver(server_addr, default_protocol) {
	if (isEmpty(server_addr))
		return null;

	if (!match(server_addr, /:\/\//))
		server_addr = (default_protocol || 'udp') + '://' + (validation('ip6addr', server_addr) ? `[${server_addr}]` : server_addr);
	server_addr = parseURL(server_addr);

	return {
		type: server_addr.protocol,
		server: server_addr.hostname,
		server_port: strToInt(server_addr.port),
		path: (server_addr.pathname !== '/') ? server_addr.pathname : null,
	}
}

function parse_custom_dnsserver(cfg) {
	let server = cfg.server,
	    server_port = (cfg.type in ['https', 'h3']) ? null : strToInt(cfg.server_port),
	    path = cfg.path;

	if (!isEmpty(server) && match(server, /:\/\//)) {
		const server_url = parseURL(server);

		server = server_url.hostname;
		if (isEmpty(server_port))
			server_port = strToInt(server_url.port);
		if ((cfg.type in ['https', 'h3']) && isEmpty(path) && server_url.pathname !== '/')
			path = server_url.pathname;
	}
	if ((cfg.type in ['https', 'h3']) && isEmpty(path))
		path = '/dns-query';

	return {
		type: cfg.type,
		server,
		server_port,
		path
	};
}

function parse_dnsquery(strquery) {
	if (type(strquery) !== 'array' || isEmpty(strquery))
		return null;

	let querys = [];
	for (let i in strquery)
		isnan(int(i)) ? push(querys, i) : push(querys, int(i));

	return querys;

}

function filter_existing_nodes(nodes) {
	if (type(nodes) !== 'array' || isEmpty(nodes))
		return [];

	return filter(nodes, (k) => {
		const node = uci.get_all(uciconfig, k) || {};
		return !isEmpty(node);
	});
}

/* Keep/drop nodes of a policy group according to the group's own node filter.
   Keywords are matched (regex, unanchored) against the node display name, i.e.
   the label used as the sing-box outbound tag. */
function filter_group_nodes(nodes, mode, keywords) {
	keywords = normalize_list(keywords);

	if ((mode !== 'whitelist' && mode !== 'blacklist') || isEmpty(keywords) || isEmpty(nodes))
		return nodes;

	const kept = [];
	for (let node in nodes) {
		const name = section_display_name(uci.get_all(uciconfig, node)) || '';
		let matched = false;

		for (let keyword in keywords) {
			let patten = null;

			try {
				patten = regexp(keyword);
			} catch (e) {
				patten = null;
			}

			if (patten !== null && !isEmpty(name) && match(name, patten)) {
				matched = true;
				break;
			}
		}

		if (mode === 'whitelist' ? matched : !matched)
			push(kept, node);
	}

	/* An empty outbound list makes sing-box refuse to start, so fall back to
	   the unfiltered list instead of dropping every node. */
	if (isEmpty(kept)) {
		system(sprintf('logger -t homeproxy "Warning: node filter (%s) in policy group matched no node, filter ignored."', shellQuote(mode)));
		return nodes;
	}

	return kept;
}

function collect_group_nodes(groups, subscription_nodes, nodes, legacy_nodes, filter_mode, filter_keywords) {
	let result = [];

	for (let group in normalize_list(groups))
		uci.foreach(uciconfig, ucinode, (cfg) => {
			if (cfg.grouphash === group && !~index(result, cfg['.name']))
				push(result, cfg['.name']);
		});

	for (let node in filter_existing_nodes(normalize_list(subscription_nodes)))
		if (!~index(result, node))
			push(result, node);

	for (let node in filter_existing_nodes(normalize_list(nodes)))
		if (!~index(result, node))
			push(result, node);

	for (let node in filter_existing_nodes(normalize_list(legacy_nodes)))
		if (!~index(result, node))
			push(result, node);

	return filter_group_nodes(result, filter_mode, filter_keywords);
}

function collect_policy_nodes(nodes, current) {
	let result = [];

	for (let node in normalize_list(nodes)) {
		if (node === current || ~index(result, node))
			continue;

		const outbound = uci.get_all(uciconfig, node) || {};
		if (!isEmpty(outbound) && outbound['.type'] === uciroutingnode && isSectionEnabled(outbound.enabled) && outbound.node in ['urltest', 'selector'])
			push(result, node);
	}

	return result;
}

const reserved_outbound_tags = {
	'GLOBAL': true,
	'main-out': true,
	'main-udp-out': true,
	'direct-out': true,
	'block-out': true
};

let outbound_tag_map = {},
    outbound_tag_used = {};

function normalize_outbound_tag(tag) {
	if (isEmpty(tag))
		return null;

	tag = trim(sprintf('%s', tag));
	tag = replace(tag, /[\r\n\t]+/g, ' ');
	tag = replace(tag, /[\/\\?#%]+/g, '-');
	tag = replace(tag, /\s+/g, ' ');

	return tag || null;
}

/* Airport (subscription) name per subscription group hash.
 *
 * Clash dashboards (zashboard & co.) only ever display the sing-box outbound
 * tag, so an airport marker has to live inside the tag itself. Every node
 * imported from a subscription carries the md5 of its (fragment-stripped) URL
 * in `grouphash`, which is exactly what update_subscriptions.uc and the LuCI
 * web UI use to map a node back to its subscription. Keys are built the same
 * way as in build_proxy_providers() below. */
function resolve_subscription_group_names() {
	let names = {},
	    urls = normalize_list(uci.get(uciconfig, 'subscription', 'subscription_url')),
	    labels = normalize_list(uci.get(uciconfig, 'subscription', 'subscription_name'));

	for (let i = 0; i < length(urls); i++) {
		const url = replace(trim(urls[i] || ''), /#.*$/, ''),
		      name = normalize_outbound_tag(labels[i]);

		if (isEmpty(url) || isEmpty(name))
			continue;

		names[md5(url)] = name;
	}

	return names;
}

const subscription_group_names = resolve_subscription_group_names();

/* Assigned (not declared) here: see the forward declaration above for why. */
section_display_name = function(section) {
	if (type(section) !== 'object' || isEmpty(section))
		return null;

	let label = normalize_outbound_tag(section.label);
	if (!isEmpty(label))
		return label;

	if (section['.type'] === ucinode) {
		const address = trim(section.override_address || section.address || '');
		const port = trim(section.override_port || section.port || '');

		if (address && port)
			return normalize_outbound_tag(`${address}:${port}`);
	}

	return null;
};

function register_outbound_tag(section_id, display_name) {
	if (isEmpty(section_id))
		return null;

	let tag = outbound_tag_map[section_id];
	if (!isEmpty(tag))
		return tag;

	const fallback_tag = `cfg-${section_id}-out`;
	let base_tag = normalize_outbound_tag(display_name) || fallback_tag;

	/* No readable label/address: the internal tag leaks into Clash
	   dashboards (e.g. zashboard). Log it so it can be traced back. */
	if (base_tag === fallback_tag)
		system(sprintf('logger -t homeproxy "Warning: outbound %s has no label or address; falling back to internal tag %s, it will show as-is in Clash dashboards."', shellQuote(section_id), shellQuote(fallback_tag)));
	else {
		/* Subscription nodes are tagged "[<airport>] <node name>" so the
		   airport stays visible in Clash dashboards, which can only show
		   the tag. The LuCI web UI keeps its own "[<airport>] " prefix on
		   top of the raw label, so users see it exactly once in both UIs. */
		const group_hash = uci.get(uciconfig, section_id, 'grouphash'),
		      airport = isEmpty(group_hash) ? null : subscription_group_names[group_hash];

		if (!isEmpty(airport))
			base_tag = `[${airport}] ${base_tag}`;
	}

	tag = base_tag;
	let suffix = 2;
	while (reserved_outbound_tags[tag] || outbound_tag_used[tag]) {
		tag = `${base_tag} (${suffix})`;
		suffix++;
	}

	outbound_tag_map[section_id] = tag;
	outbound_tag_used[tag] = true;

	return tag;
}

function get_section_outbound_tag(section_id) {
	if (isEmpty(section_id))
		return null;

	let tag = outbound_tag_map[section_id];
	if (!isEmpty(tag))
		return tag;

	const section = uci.get_all(uciconfig, section_id) || {};
	return register_outbound_tag(section_id, section_display_name(section));
}

uci.foreach(uciconfig, ucinode, (cfg) => {
	register_outbound_tag(cfg['.name'], section_display_name(cfg));
});

uci.foreach(uciconfig, uciroutingnode, (cfg) => {
	if (isSectionEnabled(cfg.enabled))
		register_outbound_tag(cfg['.name'], section_display_name(cfg));
});

function generate_endpoint(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const endpoint = {
		type: node.type,
		tag: get_section_outbound_tag(node['.name']),
		address: node.wireguard_local_address,
		mtu: strToInt(node.wireguard_mtu),
		private_key: node.wireguard_private_key,
		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: strToInt(node.port),
				allowed_ips: [
					'0.0.0.0/0',
					'::/0'
				],
				persistent_keepalive_interval: strToInt(node.wireguard_persistent_keepalive_interval),
				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: parse_port(node.wireguard_reserved),
			}
		] : null,
		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return endpoint;
}

function generate_outbound(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	/* sing-box 对 reality 是**硬性**要求 uTLS：配置里出现 `reality.enabled`
	   而没有 `utls` 时，内核直接
	     FATAL initialize outbound[N]: uTLS is required by reality client
	   然后整个客户端实例起不来 —— 一个节点就能让整机断网（2026-10-29 现场：
	   YU 订阅里 19 个 reality 节点没带 `fp=`，服务每 6 秒重启一次，全靠 `sing-box
	   check` 那句「检测到客户端配置有误」才发现）。
	   机场不给 `fp` 时按业界默认补 chrome（mihomo / v2rayN 对 reality 也是这个
	   默认值，且服务端 public_key 与客户端指纹无关，不会因此连不上）。
	   anytls 同理：它没有 `flow`，不少机场也不带 `fp`。 */
	const tls_utls_value = !isEmpty(node.tls_utls) ? node.tls_utls
		: ((node.type === 'anytls' || (node.tls === '1' && node.tls_reality === '1')) ? 'chrome' : null);
	const outbound = {
		type: node.type,
		tag: get_section_outbound_tag(node['.name']),
		routing_mark: strToInt(self_mark),

		server: (node.type !== 'direct') ? node.address : null,
		server_port: (node.type !== 'direct') ? strToInt(node.port) : null,
		/* Hysteria(2) */
		server_ports: node.hysteria_hopping_port,

		username: (node.type !== 'ssh') ? node.username : null,
		user: (node.type === 'ssh') ? node.username : null,
		password: node.password,

		/* AnyTLS */
		idle_session_check_interval: strToTime(node.anytls_idle_session_check_interval),
		idle_session_timeout: strToTime(node.anytls_idle_session_timeout),
		min_idle_session: strToInt(node.anytls_min_idle_session),
		/* Hysteria (2) */
		hop_interval: strToTime(node.hysteria_hop_interval),
		up_mbps: strToInt(node.hysteria_up_mbps),
		down_mbps: strToInt(node.hysteria_down_mbps),
		obfs: node.hysteria_obfs_type ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password,
		auth: (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null,
		auth_str: (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null,
		recv_window_conn: strToInt(node.hysteria_recv_window_conn),
		recv_window: strToInt(node.hysteria_revc_window),
		disable_mtu_discovery: strToBool(node.hysteria_disable_mtu_discovery),
		/* Shadowsocks */
		method: node.shadowsocks_encrypt_method,
		plugin: node.shadowsocks_plugin,
		plugin_opts: node.shadowsocks_plugin_opts,
		/* ShadowTLS / Socks */
		version: (node.type === 'shadowtls') ? strToInt(node.shadowtls_version) : ((node.type === 'socks') ? node.socks_version : null),
		/* SSH */
		client_version: node.ssh_client_version,
		host_key: node.ssh_host_key,
		host_key_algorithms: node.ssh_host_key_algo,
		private_key: node.ssh_priv_key,
		private_key_passphrase: node.ssh_priv_key_pp,
		/* Tuic */
		uuid: node.uuid,
		congestion_control: node.tuic_congestion_control,
		udp_relay_mode: node.tuic_udp_relay_mode,
		udp_over_stream: strToBool(node.tuic_udp_over_stream),
		zero_rtt_handshake: strToBool(node.tuic_enable_zero_rtt),
		heartbeat: strToTime(node.tuic_heartbeat),
		/* VLESS / VMess */
		flow: node.vless_flow,
		alter_id: strToInt(node.vmess_alterid),
		security: node.vmess_encrypt,
		global_padding: strToBool(node.vmess_global_padding),
		authenticated_length: strToBool(node.vmess_authenticated_length),
		packet_encoding: node.packet_encoding,

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: strToBool(node.multiplex_padding),
			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(node.multiplex_brutal_up),
				down_mbps: strToInt(node.multiplex_brutal_down)
			} : null
		} : null,
		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: strToBool(node.tls_insecure),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,
			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config: node.tls_ech_config,
				config_path: node.tls_ech_config_path
			} : null,
			utls: !isEmpty(tls_utls_value) ? {
				enabled: true,
				fingerprint: tls_utls_value
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,
		transport: !isEmpty(node.transport) ? {
			type: node.transport,
			host: node.http_host || node.httpupgrade_host,
			path: node.http_path || node.ws_path,
			headers: node.ws_host ? {
				Host: node.ws_host
			} : null,
			method: node.http_method,
			max_early_data: strToInt(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header,
			service_name: node.grpc_servicename,
			idle_timeout: strToTime(node.http_idle_timeout),
			ping_timeout: strToTime(node.http_ping_timeout),
			permit_without_stream: strToBool(node.grpc_permit_without_stream)
		} : null,
		udp_over_tcp: (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.udp_over_tcp_version)
		} : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return outbound;
}

function get_outbound(cfg) {
	if (isEmpty(cfg))
		return null;

	if (type(cfg) === 'array') {
		if ('any-out' in cfg)
			return 'any';

		let outbounds = [];
		for (let i in cfg)
			push(outbounds, get_outbound(i));
		return outbounds;
	} else {
		switch (cfg) {
		case 'block-out':
		case 'direct-out':
			return cfg;
		default:
			const node = uci.get(uciconfig, cfg, 'node');
			if (isEmpty(node))
				die(sprintf("%s's node is missing, please check your configuration.", cfg));
			else if (node in ['urltest', 'selector'])
				return get_section_outbound_tag(cfg);
			else
				return get_section_outbound_tag(node);
		}
	}
}

function get_resolver(cfg) {
	if (isEmpty(cfg))
		return null;

	switch (cfg) {
	case 'default-dns':
	case 'system-dns':
		return cfg;
	default:
		return 'cfg-' + cfg + '-dns';
	}
}

function get_ruleset(cfg) {
	if (isEmpty(cfg))
		return null;

	let rules = [];
	for (let i in cfg) {
		if (isEmpty(i)) {
			push(rules, null);
			continue;
		}

		const ruleset = uci.get_all(uciconfig, i);
		push(rules, !isEmpty(ruleset?.tag) ? ruleset.tag : ('cfg-' + i + '-rule'));
	}
	return rules;
}

function subscription_provider_name(name) {
	name = trim(name || '');
	return name;
}

function unique_provider_name(name, used) {
	const base = name;
	let suffix = 2;

	while (used[name]) {
		name = sprintf('%s (%d)', base, suffix);
		suffix++;
	}
	used[name] = true;

	return name;
}

function get_subscription_info(group_hash) {
	const value = uci.get(uciconfig, 'subscription', 'subinfo_' + substr(group_hash, 0, 16));
	if (isEmpty(value))
		return null;

	try {
		const info = json(value);
		if (type(info) !== 'object')
			return null;

		const has_subscription_info = ('upload' in info) || ('download' in info) ||
		      ('total' in info) || ('expire' in info);

		return {
			updated_at: info.updated_at,
			subscription_info: has_subscription_info ? {
				upload: info.upload,
				download: info.download,
				total: info.total,
				expire: info.expire
			} : null
		};
	} catch (e) {
		return null;
	}
}

/* Build the `proxy_providers` list for the (patched) reF1nd kernel's native
   Clash API `/providers/proxies` endpoint. The patched kernel synthesises the
   provider objects from this config and resolves each member to a real
   outbound by its tag, so `proxies` is an array of outbound tags (strings),
   not proxy objects. Keys follow sing-box's snake_case Clash API options:
   `vehicle_type`, `updated_at`, `update_id`, `subscription_info`. */
function build_proxy_providers() {
	let providers = [],
	    used_names = {},
	    subscription_names = normalize_list(uci.get(uciconfig, 'subscription', 'subscription_name')),
	    sub_index = 0;

	for (let suburl in normalize_list(uci.get(uciconfig, 'subscription', 'subscription_url'))) {
		const subscription_name = subscription_names[sub_index];
		sub_index++;

		if (isEmpty(suburl) || isEmpty(trim(subscription_name || '')))
			continue;

		const url = replace(suburl, /#.*$/, ''),
		      group_hash = md5(url);

		let proxies = [],
		    seen = {};

		uci.foreach(uciconfig, ucinode, (cfg) => {
			if (cfg.grouphash !== group_hash)
				return;

			const tag = get_section_outbound_tag(cfg['.name']);
			if (isEmpty(tag) || seen[tag])
				return;

			seen[tag] = true;
			push(proxies, tag);
		});

		if (isEmpty(proxies))
			continue;

		const info = get_subscription_info(group_hash);
		let subscription_info = null;

		if (info?.subscription_info != null)
			subscription_info = {
				upload: info.subscription_info.upload,
				download: info.subscription_info.download,
				total: info.subscription_info.total,
				expire: info.subscription_info.expire
			};

		push(providers, {
			name: unique_provider_name(subscription_provider_name(subscription_name), used_names),
			type: 'Proxy',
			vehicle_type: 'HTTP',
			proxies: proxies,
			/* 32-hex group hash; the kernel passes it to
			   /etc/homeproxy/scripts/update_provider.sh on a panel
			   "update provider" request. */
			update_id: group_hash,
			updated_at: info?.updated_at,
			subscription_info: subscription_info
		});
	}

	return providers;
}

/* 面板是否真的就位（目录里有 index.html）。
   ⚠️ 这个判断决定两件事，二者必须同时成立：
   1) 只有就位时才下发 `external_ui`；
   2) `external_ui_download_url` **任何情况都不下发**。
   2026-10-31 三组最小配置实验（§十五 33）证明：只要 `external_ui` 有值而目录里
   没有文件，内核就会**自己下一次 UI**（与给不给 download_url 无关），而且这次下载
   在 clash-api 监听**之前**同步做完 —— 现场就是这样卡了 1188 秒，面板全程打不开。
   反过来，不设 `external_ui` 时内核根本不下载，API 立刻可用（只是 `/ui/` 返回 404）。
   所以：面板没装好就不下发 `external_ui`，由 fetch_panel.sh 负责把面板弄好并 reload；
   装好了才下发，内核直接静态服务，不再碰网络。 */
function panel_installed(external_ui) {
	let dir = external_ui;

	/* 与 fetch_panel.sh 的 resolve 规则一致：相对路径/空值一律落到 HP_DIR/run/ui，
	   否则这里检查的是生成器自己的 cwd，永远查不到面板。 */
	if (isEmpty(dir) || !match(dir, /^\//))
		dir = HP_DIR + '/run/ui';

	let fp = null;
	try {
		fp = open(dir + '/index.html', 'r');
	} catch (e) {
		return false;
	}

	if (!fp)
		return false;

	try { fp.close(); } catch (e) {}

	return true;
}

const clash_panel_ok = panel_installed(uci.get(uciconfig, uciclashapi, 'external_ui'));

clash_api = {
	external_controller: uci.get(uciconfig, uciclashapi, 'external_controller') || '127.0.0.1:9090',
	external_ui: clash_panel_ok ? uci.get(uciconfig, uciclashapi, 'external_ui') : null,
	external_ui_download_url: null,
	external_ui_download_detour: null,
	secret: uci.get(uciconfig, uciclashapi, 'secret'),
	default_mode: uci.get(uciconfig, uciclashapi, 'default_mode') || 'rule',
	/* NOTE: selector choice persistence (store_selected) is emitted ONLY under
	   experimental.cache_file (see the cache_file block below), NEVER under clash_api.
	   In sing-box 1.12+ clash_api.store_selected is rejected at startup (deprecated
	   since 1.8.0, see experimental/clashapi/server.go) — emitting it there makes the
	   Clash API abort. The stock reF1nd 1.14.3-reF1nd kernel's cache_file also lacked
	   the field, but this repo's build-deploy.yml applies
	   tools/sing-box-patches/003-add-cache-file-store-selected.patch which adds it back,
	   so the patched kernel accepts cache_file.store_selected and persists the selected
	   outbound across restarts. Outdated stock kernels without that patch would reject
	   it as an unknown field. */
	/* Native proxy providers for the patched reF1nd kernel. The kernel serves
	   /providers/proxies from this list; empty in non-subscription modes. */
	proxy_providers: build_proxy_providers()
};
/* Config helper end */

const config = {};

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: ntp_enabled === '1',
		server: ntp_server,
		server_port: strToInt(ntp_server_port),
		interval: ntp_interval,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};

/* DNS start */
/* Default settings */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: self_mark ? 'direct-out' : null
		},
		{
			tag: 'system-dns',
			type: 'local',
			detour: self_mark ? 'direct-out' : null
		}
	],
	rules: [],
	strategy: dns_default_strategy,
	disable_cache: strToBool(dns_disable_cache),
	disable_expire: strToBool(dns_disable_cache_expire),
	client_subnet: dns_client_subnet
};

if (!isEmpty(main_node)) {
	/* Main DNS */
	push(config.dns.servers, {
		tag: 'main-dns',
		domain_resolver: {
			server: 'default-dns',
			strategy: (ipv6_support !== '1') ? 'ipv4_only' : null
		},
		detour: 'main-out',
		...parse_dnsserver(dns_server, 'tcp')
	});
	config.dns.final = 'main-dns';

	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns'
		});

	/* Filter out SVCB/HTTPS queries for "exquisite" Apple devices */
	if (routing_mode === 'gfwlist' || length(proxy_domain_list))
		push(config.dns.rules, {
			rule_set: (routing_mode !== 'gfwlist') ? 'proxy-domain' : null,
			query_type: [64, 65],
			action: 'reject'
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.dns.servers, {
			tag: 'china-dns',
			domain_resolver: {
				server: 'default-dns',
				strategy: 'prefer_ipv6'
			},
			detour: self_mark ? 'direct-out' : null,
			...parse_dnsserver(china_dns_server)
		});

		if (length(proxy_domain_list))
			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});

		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
		push(config.dns.rules, {
			type: 'logical',
			mode: 'and',
			rules: [
				{
					rule_set: 'geosite-noncn',
					invert: true
				},
				{
					rule_set: 'geoip-cn'
				}
			],
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
	}
} else if (!isEmpty(default_outbound)) {
	/* DNS servers */
	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (!isSectionEnabled(cfg.enabled))
			return;

		let outbound = get_outbound(cfg.outbound);
		if (outbound === 'direct-out' && isEmpty(self_mark))
			outbound = null;

		push(config.dns.servers, {
			tag: 'cfg-' + cfg['.name'] + '-dns',
			...parse_custom_dnsserver(cfg),
			headers: cfg.headers,
			tls: cfg.tls_sni ? {
				enabled: true,
				server_name: cfg.tls_sni
			} : null,
			domain_resolver: (cfg.address_resolver || cfg.address_strategy) ? {
				server: get_resolver(cfg.address_resolver || dns_default_server),
				strategy: cfg.address_strategy
			} : null,
			detour: outbound
		});
	});

	/* DNS rules */
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (!isSectionEnabled(cfg.enabled))
			return;

		push(config.dns.rules, {
			ip_version: strToInt(cfg.ip_version),
			query_type: parse_dnsquery(cfg.query_type),
			network: cfg.network,
			protocol: cfg.protocol,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			source_ip_cidr: cfg.source_ip_cidr,
			source_ip_is_private: strToBool(cfg.source_ip_is_private),
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			process_path_regex: cfg.process_path_regex,
			user: cfg.user,
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			invert: strToBool(cfg.invert),
			outbound: get_outbound(cfg.outbound),
			action: cfg.action,
			server: get_resolver(cfg.server),
			strategy: cfg.domain_strategy,
			disable_cache: strToBool(cfg.dns_disable_cache),
			rewrite_ttl: strToInt(cfg.rewrite_ttl),
			client_subnet: cfg.client_subnet,
			method: cfg.reject_method,
			no_drop: strToBool(cfg.reject_no_drop),
			rcode: cfg.predefined_rcode,
			answer: cfg.predefined_answer,
			ns: cfg.predefined_ns,
			extra: cfg.predefined_extra
		});
	});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	config.dns.final = get_resolver(dns_default_server);
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

push(config.inbounds, {
	type: 'mixed',
	tag: 'mixed-in',
	listen: '::',
	listen_port: int(mixed_port),
	udp_timeout: strToTime(udp_timeout),
	set_system_proxy: false
});

if (match(proxy_mode, /redirect/))
	push(config.inbounds, {
		type: 'redirect',
		tag: 'redirect-in',

		listen: '::',
		listen_port: int(redirect_port)
	});
if (match(proxy_mode, /tproxy/))
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',

		listen: '::',
		listen_port: int(tproxy_port),
		network: 'udp',
		udp_timeout: strToTime(udp_timeout)
	});
if (match(proxy_mode, /tun/))
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',

		interface_name: tun_name,
		address: (ipv6_support === '1') ? [tun_addr4, tun_addr6] : [tun_addr4],
		mtu: strToInt(tun_mtu),
		auto_route: false,
		udp_timeout: strToTime(udp_timeout),
		stack: tcpip_stack
	});
/* Inbound end */

/* Outbound start */
config.endpoints = [];

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	},
	{
		type: 'block',
		tag: 'block-out'
	}
];

/* Main outbounds */
if (!isEmpty(main_node)) {
	let urltest_nodes = [];

	if (main_node === 'urltest') {
		const main_urltest_nodes = filter_existing_nodes(
			normalize_list(uci.get(uciconfig, ucimain, 'main_urltest_nodes'))
		);
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval');
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => get_section_outbound_tag(k)),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
		});
		urltest_nodes = main_urltest_nodes;
	} else {
		/* Simple mode used to emit exactly one outbound (`main-out`), so a
		   Clash dashboard (Zashboard / yacd) only saw the synthetic GLOBAL
		   group with that single node and could not switch anything. Generate
		   every node under its own tag and turn `main-out` into a selector
		   over all of them, keeping the configured main node as the default.
		   Routing already points at `main-out`, so it keeps working; the
		   dashboard now gets a real, switchable group. */
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {},
		      main_tag = get_section_outbound_tag(main_node);
		let members = [];

		uci.foreach(uciconfig, ucinode, (cfg) => {
			const tag = get_section_outbound_tag(cfg['.name']);

			if (isEmpty(tag) || ~index(members, tag))
				return;

			if (cfg.type === 'wireguard') {
				const endpoint = generate_endpoint(cfg);
				if (!endpoint)
					return;

				endpoint.tag = tag;
				push(config.endpoints, endpoint);
			} else {
				const outbound = generate_outbound(cfg);
				if (!outbound)
					return;

				outbound.tag = tag;
				push(config.outbounds, outbound);
			}

			push(members, tag);
		});

		/* Configured main node first: it is the selector default and shows at
		   the top of the group in the dashboard. */
		if (length(members) && !isEmpty(main_tag) && ~index(members, main_tag))
			members = [ main_tag, ...filter(members, (tag) => tag !== main_tag) ];

		if (!length(members)) {
			/* Nothing could be generated (e.g. the section was removed while
			   the UCI value survived): keep the old single-outbound shape so
			   the rest of the config still references a valid tag. */
			if (main_node_cfg.type === 'wireguard') {
				const main_endpoint = generate_endpoint(main_node_cfg);
				if (main_endpoint) {
					main_endpoint.tag = 'main-out';
					push(config.endpoints, main_endpoint);
				}
			} else {
				const main_outbound = generate_outbound(main_node_cfg);
				if (main_outbound) {
					main_outbound.tag = 'main-out';
					push(config.outbounds, main_outbound);
				}
			}
		} else {
			push(config.outbounds, {
				type: 'selector',
				tag: 'main-out',
				outbounds: members,
				default: (!isEmpty(main_tag) && ~index(members, main_tag)) ? main_tag : members[0],
				interrupt_exist_connections: false
			});
		}
	}

	if (main_udp_node === 'urltest') {
		const main_udp_urltest_nodes = filter_existing_nodes(
			normalize_list(uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes'))
		);
		const main_udp_urltest_interval = uci.get(uciconfig, ucimain, 'main_udp_urltest_interval');
		const main_udp_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_udp_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-udp-out',
			outbounds: map(main_udp_urltest_nodes, (k) => get_section_outbound_tag(k)),
			interval: strToTime(main_udp_urltest_interval),
			tolerance: strToInt(main_udp_urltest_tolerance),
			idle_timeout: (strToInt(main_udp_urltest_interval) > 1800) ? `${main_udp_urltest_interval * 2}s` : null,
		});
		urltest_nodes = [...urltest_nodes, ...filter(main_udp_urltest_nodes, (l) => !~index(urltest_nodes, l))];
	} else if (dedicated_udp_node) {
		const main_udp_node_cfg = uci.get_all(uciconfig, main_udp_node) || {};
		if (main_udp_node_cfg.type === 'wireguard') {
			const main_udp_endpoint = generate_endpoint(main_udp_node_cfg);
			if (main_udp_endpoint) {
				main_udp_endpoint.tag = 'main-udp-out';
				push(config.endpoints, main_udp_endpoint);
			}
		} else {
			const main_udp_outbound = generate_outbound(main_udp_node_cfg);
			if (main_udp_outbound) {
				main_udp_outbound.tag = 'main-udp-out';
				push(config.outbounds, main_udp_outbound);
			}
		}
	}

	for (let i in urltest_nodes) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = generate_endpoint(urltest_node);
			if (endpoint) {
				endpoint.tag = get_section_outbound_tag(i);
				push(config.endpoints, endpoint);
			}
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound) {
				outbound.tag = get_section_outbound_tag(i);
				push(config.outbounds, outbound);
			}
		}
	}
} else if (!isEmpty(default_outbound)) {
	let urltest_nodes = [],
	    routing_nodes = [];

	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (!isSectionEnabled(cfg.enabled))
			return;

		if (cfg.node === 'urltest') {
			const legacy_nodes = (isEmpty(cfg.subscription_groups) && isEmpty(cfg.subscription_nodes) && isEmpty(cfg.selected_nodes)) ? cfg.urltest_nodes : null;
			const urltest_list = collect_group_nodes(cfg.subscription_groups, cfg.subscription_nodes, cfg.selected_nodes, legacy_nodes, cfg.filter_nodes, cfg.filter_keywords);
			const urltest_tags = map(urltest_list, (k) => get_section_outbound_tag(k));
			push(config.outbounds, {
				type: 'urltest',
				tag: get_section_outbound_tag(cfg['.name']),
				/* 成员为空时必须给一个兜底。内核会因为空 urltest 整个起不来：
				   `FATAL: start outbound: start endpoint/urltest[香港自动]: missing
				   outbound and provider tags`。而服务没起来时，防火墙的 DNS 劫持
				   已经装上了 —— 用户点「清除所有订阅节点」后正好是这个状态：
				   局域网 DNS 全灭，连订阅都拉不回来（死锁，0.2.9 现场）。
				   空分组 = 直连。 */
				outbounds: length(urltest_tags) ? urltest_tags : [ 'direct-out' ],
				/* 没配 urltest_url（老配置/手工建的段）时显式写成 google 的
				   generate_204，而不是留 null 让内核用自己的默认值：两边默认值
				   一旦分岔，同一个组的打分口径就变了，日志里还看不出来。
				   ⚠️ 别改回 `www.gstatic.com` —— 它在本项目 china_list（直连域名）
				   里，且实测有节点通 google 却对 gstatic 失败/超时，会把可用节点
				   判成不可用（0.2.9 现场）。 */
				url: length(cfg.urltest_url ?? '') ? cfg.urltest_url : 'https://www.google.com/generate_204',
				interval: strToTime(cfg.urltest_interval),
				tolerance: strToInt(cfg.urltest_tolerance),
				idle_timeout: strToTime(cfg.urltest_idle_timeout),
				interrupt_exist_connections: strToBool(cfg.urltest_interrupt_exist_connections)
			});
			urltest_nodes = [...urltest_nodes, ...filter(urltest_list, (l) => !~index(urltest_nodes, l))];
		} else if (cfg.node === 'selector') {
			const selector_node_list = collect_group_nodes(cfg.subscription_groups, cfg.subscription_nodes, cfg.selected_nodes, null, cfg.filter_nodes, cfg.filter_keywords);
			const selector_policy_list = collect_policy_nodes(cfg.policy_nodes, cfg['.name']);
			const selector_list = [...selector_node_list, ...filter(selector_policy_list, (l) => !~index(selector_node_list, l))];
			const selector_default = (!isEmpty(cfg.selector_default) && ~index(selector_list, cfg.selector_default)) ? cfg.selector_default : null;
			const selector_tags = map(selector_list, (k) => get_section_outbound_tag(k));
			push(config.outbounds, {
				type: 'selector',
				tag: get_section_outbound_tag(cfg['.name']),
				/* 同上：空 selector 一样让内核启动失败（"missing outbound and
				   provider tags"），兜底成直连。 */
				outbounds: length(selector_tags) ? selector_tags : [ 'direct-out' ],
				default: selector_default ? get_section_outbound_tag(selector_default) : null,
				interrupt_exist_connections: strToBool(cfg.selector_interrupt_exist_connections)
			});
			urltest_nodes = [...urltest_nodes, ...filter(selector_node_list, (l) => !~index(urltest_nodes, l))];
		} else {
			const outbound = uci.get_all(uciconfig, cfg.node) || {};
			if (isEmpty(outbound))
				return;

			if (outbound.type === 'wireguard') {
				const endpoint = generate_endpoint(outbound);
				if (!endpoint)
					return;

				endpoint.bind_interface = cfg.bind_interface;
				endpoint.detour = get_outbound(cfg.outbound);
				if (cfg.domain_resolver)
					endpoint.domain_resolver = {
						server: get_resolver(cfg.domain_resolver),
						strategy: cfg.domain_strategy
					};
				push(config.endpoints, endpoint);
			} else {
				const routed_outbound = generate_outbound(outbound);
				if (!routed_outbound)
					return;

				routed_outbound.bind_interface = cfg.bind_interface;
				routed_outbound.detour = get_outbound(cfg.outbound);
				if (cfg.domain_resolver)
					routed_outbound.domain_resolver = {
						server: get_resolver(cfg.domain_resolver),
						strategy: cfg.domain_strategy
					};
				push(config.outbounds, routed_outbound);
			}
			push(routing_nodes, cfg.node);
		}
	});

	for (let i in filter(urltest_nodes, (l) => !~index(routing_nodes, l))) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (isEmpty(urltest_node))
			continue;

		if (urltest_node.type === 'wireguard') {
			const endpoint = generate_endpoint(urltest_node);
			if (endpoint)
				push(config.endpoints, endpoint);
		} else {
			const outbound = generate_outbound(urltest_node);
			if (outbound)
				push(config.outbounds, outbound);
		}
	}
}

if (isEmpty(config.endpoints))
	config.endpoints = null;
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [
		{
			inbound: 'dns-in',
			action: 'hijack-dns'
		},
		{
			action: 'sniff'
		}
	],
	rule_set: [],
	auto_detect_interface: isEmpty(default_interface) ? true : null,
	default_interface: default_interface
};

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		action: 'route',
		server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	/* Main UDP out */
	if (dedicated_udp_node)
		push(config.route.rules, {
			network: 'udp',
			action: 'route',
			outbound: 'main-udp-out'
		});

	/* Bypass mainland China: route everything that is NOT mainland (by IP or
	   by geosite) through the proxy; the rest — mainland + unknown — falls
	   through to direct-out below. Without this rule the mode name is
	   misleading: traffic would all go to the proxy (final = main-out). */
	if (routing_mode === 'bypass_mainland_china')
		push(config.route.rules, {
			rule_set: ['geoip-cn', 'geosite-cn'],
			invert: true,
			action: 'route',
			outbound: 'main-out'
		});

	/* GFWList: route foreign geosites through the proxy, everything else
	   direct. */
	if (routing_mode === 'gfwlist')
		push(config.route.rules, {
			rule_set: 'geosite-noncn',
			action: 'route',
			outbound: 'main-out'
		});

	/* In these two modes the catch-all must be direct; only the matched
	   foreign/mainland-excluded traffic is proxied. */
	config.route.final = (routing_mode === 'bypass_mainland_china' || routing_mode === 'gfwlist') ? 'direct-out' : 'main-out';

	/* Rule set */
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: [
				{
					domain_keyword: direct_domain_list,
				}
			]
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: [
				{
					domain_keyword: proxy_domain_list,
				}
			]
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geoip-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs',
			path: ruleset_default_path('geoip-cn', 'binary'),
			http_client: dl_tag_for('main-out')
		});
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs',
			path: ruleset_default_path('geosite-cn', 'binary'),
			http_client: dl_tag_for('main-out')
		});
	}

	/* geosite-noncn is needed by BOTH bypass (DNS logical rule) and GFWList
	   (routing rule), so register it for either mode. */
	if (routing_mode === 'bypass_mainland_china' || routing_mode === 'gfwlist') {
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-noncn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs',
			path: ruleset_default_path('geosite-noncn', 'binary'),
			http_client: dl_tag_for('main-out')
		});
	}

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
} else if (!isEmpty(default_outbound)) {
	config.route.default_domain_resolver = {
		action: 'resolve',
		server: get_resolver(default_outbound_dns)
	};

	if (domain_strategy)
		push(config.route.rules, {
			action: 'resolve',
			strategy: domain_strategy
		});

	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (!isSectionEnabled(cfg.enabled))
			return null;

		push(config.route.rules, {
			ip_version: strToInt(cfg.ip_version),
			protocol: cfg.protocol,
			network: cfg.network,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			source_ip_cidr: cfg.source_ip_cidr,
			source_ip_is_private: strToBool(cfg.source_ip_is_private),
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			process_path_regex: cfg.process_path_regex,
			user: cfg.user,
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			rule_set_ip_cidr_accept_empty: strToBool(cfg.rule_set_ip_cidr_accept_empty),
			invert: strToBool(cfg.invert),
			action: cfg.action,
			outbound: (cfg.action === 'route') ? get_outbound(cfg.outbound) : null,
			server: (cfg.action === 'resolve') ? get_resolver(cfg.resolve_server) : null,
			strategy: (cfg.action === 'resolve') ? cfg.resolve_strategy : null,
			disable_cache: (cfg.action === 'resolve') ? strToBool(cfg.resolve_disable_cache) : null,
			rewrite_ttl: (cfg.action === 'resolve') ? strToInt(cfg.resolve_rewrite_ttl) : null,
			client_subnet: (cfg.action === 'resolve') ? cfg.resolve_client_subnet : null,
			override_address: (cfg.action in ['route', 'route-options']) ? cfg.override_address : null,
			override_port: (cfg.action in ['route', 'route-options']) ? strToInt(cfg.override_port) : null,
			udp_disable_domain_unmapping: (cfg.action in ['route', 'route-options']) ? strToBool(cfg.udp_disable_domain_unmapping) : null,
			udp_connect: (cfg.action in ['route', 'route-options']) ? strToBool(cfg.udp_connect) : null,
			udp_timeout: (cfg.action in ['route', 'route-options']) ? strToTime(cfg.udp_timeout) : null,
			tls_fragment: (cfg.action in ['route', 'route-options']) ? strToBool(cfg.tls_fragment) : null,
			tls_fragment_fallback_delay: (cfg.action in ['route', 'route-options']) ? strToTime(cfg.tls_fragment_fallback_delay) : null,
			tls_record_fragment: (cfg.action in ['route', 'route-options']) ? strToBool(cfg.tls_record_fragment) : null,
			method: (cfg.action === 'reject') ? cfg.reject_method : null,
			no_drop: (cfg.action === 'reject') ? strToBool(cfg.reject_no_drop) : null
		});
	});

	config.route.final = get_outbound(default_outbound);

	/* Rule set */
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (!isSectionEnabled(cfg.enabled))
			return null;

		const tag = !isEmpty(cfg.tag) ? cfg.tag : ('cfg-' + cfg['.name'] + '-rule');
		const path = (cfg.type === 'remote')
			? ruleset_remote_path(cfg.remote_path || cfg.path, tag, cfg.format)
			: cfg.path;

		/* A validated local copy wins over a remote fetch. sing-box loads
		   remote rule-sets while initialising — BEFORE it starts the Clash API
		   listener — so with 20+ enabled rule-sets start-up blocks for minutes
		   on a slow mirror and the panel is judged "API not ready" and never
		   downloaded. fetch_rulesets.sh keeps this cache populated. */
		if (cfg.type === 'remote' && ruleset_local_ready(path, cfg.format)) {
			push(config.route.rule_set, {
				type: 'local',
				tag: tag,
				format: cfg.format,
				path: path
			});

			return null;
		}

		push(config.route.rule_set, {
			type: cfg.type,
			tag: tag,
			format: cfg.format,
			url: cfg.url,
			path: path,
			http_client: dl_tag_for(get_outbound(cfg.outbound)),
			update_interval: (cfg.type === 'remote') ? '87600h' : null
		});
	});
}
/* Routing rules end */

/* HTTP clients for remote rule-set downloads (sing-box 1.14: replaces deprecated download_detour) */
if (!isEmpty(config.route) && !isEmpty(config.route.rule_set)) {
	http_client_map['dl-default'] = null;
	config.http_clients = map(keys(http_client_map), (t) => ({
		tag: t,
		detour: (t === 'dl-default') ? null : http_client_map[t]
	}));
	/* IMPORTANT: `default_http_client` belongs UNDER `route`, not at the top
	   level — sing-box documents it as `route.default_http_client`. Emitting
	   it as a top-level field makes sing-box abort at startup with
	   `decode config: default_http_client: json: unknown field
	   "default_http_client"`, which surfaces as "客户端配置有误". */
	config.route.default_http_client = 'dl-default';
}

/* Experimental start */
if (routing_mode in ['bypass_mainland_china', 'custom']) {
	/* `proxy_providers` now lives inside `clash_api` (not at the top level):
	   it is consumed by the patched reF1nd kernel, which synthesises the
	   /providers/proxies objects from it. A stock (unpatched) sing-box would
	   reject the unknown field, so this branch is only correct together with
	   the kernel patch. All subscription nodes are still expanded into
	   `outbounds`; the list above only teaches the panel about providers. */

	config.experimental = {
		clash_api,
		cache_file: {
			enabled: cache_file_enabled !== '0',
			path: cache_file_path || (HP_DIR + '/cache.db'),
			store_dns: strToBool(cache_store_dns),
			store_selected: cache_store_selected !== '0'
		}
	};
}
/* Experimental end */

/* 出站引用完整性 ------------------------------------------------------------
 * 0 节点（或删掉某个出站）之后，配置里会残留指向「选不出节点的分组」的引用。
 *
 * sing-box 不会因此拒绝启动，但运行期凡走该引用的连接都会失败，DNS 也一样。
 * 2026-10-28 现场：清空节点后 dns.final 指向自定义 DoH，它的 detour 是
 * 「默认代理」，而这条链的末端（各 urltest 组）虽然被降级成了 [direct-out]，
 * 却永远测不出可用成员 —— 于是整个局域网解析不了任何域名（nslookup 只回
 * No answer），订阅也就拉不回来，只能 SSH 进路由器手动救。
 *
 * 处理分两层：
 *   ① 完全没有真实节点时，整套 DNS 退回直连（final = default-dns，所有
 *      server 的 detour 一律 direct-out），route.final 也退回直连 ——
 *      没有代理可用时，直连是唯一还能上网的路径，也正是用户点「更新订阅」
 *      自救所需要的；
 *   ② 其余悬空引用（指向根本不存在的 tag，或指向成员为空的分组）统一指回
 *      direct-out。正常配置下这些引用都成立，本函数一个字段都不会改。 */
function ensure_outbound_refs(config) {
	let tags = { 'direct-out': true },
	    dns_tags = {},
	    has_proxy = false;

	for (let outbound in config.outbounds ?? []) {
		if (isEmpty(outbound.tag))
			continue;

		const kind = outbound.type;

		if (kind !== 'selector' && kind !== 'urltest' && kind !== 'direct' &&
		    kind !== 'block' && kind !== 'dns')
			has_proxy = true;

		/* 成员为空的组等于没有这个出站：指向它的连接一定选不出节点。 */
		if ((kind === 'selector' || kind === 'urltest') &&
		    length(outbound.outbounds ?? []) === 0)
			continue;

		tags[outbound.tag] = true;
	}

	for (let server in config.dns?.servers ?? [])
		if (!isEmpty(server.tag))
			dns_tags[server.tag] = true;

	function dangling(tag) {
		return type(tag) === 'string' && tags[tag] !== true;
	}

	if (!has_proxy) {
		for (let server in config.dns?.servers ?? [])
			if (server.tag !== 'system-dns')
				server.detour = 'direct-out';

		if (dns_tags['default-dns'] === true)
			config.dns.final = 'default-dns';

		config.route.final = 'direct-out';
	}

	if (dangling(config.route?.final))
		config.route.final = 'direct-out';

	for (let rule in config.route?.rules ?? []) {
		if (type(rule.outbound) === 'array') {
			for (let i = 0; i < length(rule.outbound); i++)
				if (dangling(rule.outbound[i]))
					rule.outbound[i] = 'direct-out';
		} else if (dangling(rule.outbound)) {
			rule.outbound = 'direct-out';
		}
	}

	for (let server in config.dns?.servers ?? [])
		if (dangling(server.detour))
			server.detour = 'direct-out';

	/* dns.final 指的是 DNS 服务器的 tag（不是出站 tag），单独判一次。 */
	if (type(config.dns?.final) === 'string' && dns_tags[config.dns.final] !== true &&
	    dns_tags['default-dns'] === true)
		config.dns.final = 'default-dns';
}

system('mkdir -p ' + RUN_DIR);
system('mkdir -p ' + RULESET_DIR);
ensure_outbound_refs(config);
writefile(RUN_DIR + '/sing-box-c.json', sprintf('%.J\n', removeBlankAttrs(config)));
}
