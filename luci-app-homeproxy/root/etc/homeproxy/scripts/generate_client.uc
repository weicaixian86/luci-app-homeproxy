#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { md5 } from 'digest';
import { access, open, readfile, writefile } from 'fs';
import { isnan } from 'math';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	isEmpty, isSectionEnabled, parseURL, shellQuote, strToBool, strToInt, strToTime,
	removeBlankAttrs, validation, HP_DIR, RUN_DIR
} from 'homeproxy';

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

let proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface');

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';

let self_mark, redirect_port, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack,
    udp_timeout,
    ebpf_cgroup_path, ebpf_bypass_private, ebpf_interface;

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
/* eBPF 四种代理模式（UI 下拉里的 4 项），值即「local 数据面 + shared 数据面」的组合。
   用显式映射表而不是字符串切分：`socket_assign_socket_assign` 这类用 '_' 切分
   会产生歧义。四种都同时启用 local 与 shared，因此既给 LAN 设备当透明代理网关，
   也让路由器本机走代理。
   枚举合法性（1.14.4 option/ebpf.go:32,52）：
     local ∈ {cgroup, socket_assign}；shared ∈ {socket_assign, packet_rewrite}。 */
const ebpf_mode_map = {
	'ebpf_cgroup_shared_socket_assign':        { local: 'cgroup',        shared: 'socket_assign' },
	'ebpf_cgroup_shared_packet_rewrite':       { local: 'cgroup',        shared: 'packet_rewrite' },
	'ebpf_socket_assign_shared_socket_assign': { local: 'socket_assign', shared: 'socket_assign' },
	'ebpf_socket_assign_shared_packet_rewrite':{ local: 'socket_assign', shared: 'packet_rewrite' }
};
let ebpf_spec = ebpf_mode_map[proxy_mode];
/* 兼容：早期版本的单一 'ebpf' 取值，等价于默认的第 1 种（cgroup + socket_assign）。 */
if (proxy_mode === 'ebpf')
	ebpf_spec = ebpf_mode_map['ebpf_cgroup_shared_socket_assign'];

/* ── eBPF 能力自检（借鉴 honk 的"启动前内核能力预检"）──────────────────────
   用户选了 eBPF 模式，但当前内核/环境不满足时，**不要**让内核以
   `eBPF inbound is not included in this build` 之类的 FATAL 把整个服务带崩
   （那样全屋断网、且日志里只有一句难懂的内核报错，用户不知道要升级到什么）。

   这里逐项检查，任何一项不满足就：
     ① 往 homeproxy.log 写一条**精确**的【eBPF 不可用】原因（缺什么、需要什么版本）；
     ② 自动回退到 redirect_tproxy 继续生成本次配置（服务能起来，只是不走 eBPF）；
     ③ 回退结果由 update_core/前端读取 —— 见 generate_client 末尾写出的
        `ebpf_fallback` 标记（前端据此在状态页提示，无需重启也不会静默）。
   检查项与判据：
     · 内核 ≥ 6.6           —— eBPF inbound（tcx/cgroup 挂载）的最低内核要求
     · 内核带 with_ebpf tag —— sing-box 编译期是否编入 eBPF（缺则 100% 不可用）
     · /sys/fs/cgroup 存在  —— local=cgroup 数据面的挂载前提
     · bpffs 可挂载/已挂载  —— sing-box eBPF 加载程序的运行前提
   （以上任一不满足 → 回退；满足则照常生成 eBPF inbound） */
function _hp_log(msg) {
	system(sprintf("printf '%%s %%s\\n' \"$(date '+%%Y-%%m-%%dT%%H:%%M:%%S')\" %s >> %s 2>/dev/null",
		shellQuote('[EBPF] ' + msg), shellQuote(RUN_DIR + '/homeproxy.log')));
}

function _hp_kernel_version() {
	const rel = trim(readfile('/proc/sys/kernel/osrelease') || '');
	const m = match(rel, /^([0-9]+)\.([0-9]+)/);
	if (!m)
		return null;
	return { major: +m[1], minor: +m[2], raw: rel };
}

function _hp_bpffs_ready() {
	// bpffs 已挂到 /sys/fs/bpf 且可写（sing-box 在其下 pin 程序/映射）
	if (!access('/sys/fs/bpf'))
		return false;
	// 已是 bpffs：尝试在目录里建一个临时文件判断可写
	const probe = '/sys/fs/bpf/.hp_probe';
	if (system(sprintf('touch %s 2>/dev/null && rm -f %s', shellQuote(probe), shellQuote(probe))) === 0)
		return true;
	// 未挂 bpffs 但内核支持（mount -t bpf 成功即视为具备能力）
	if (system('mount -t bpf bpf /sys/fs/bpf 2>/dev/null') === 0) {
		system(sprintf('touch %s 2>/dev/null && rm -f %s', shellQuote(probe), shellQuote(probe)));
		return true;
	}
	return false;
}

let ebpf_fallback = null;   // 记录回退原因（供状态页展示）
if (ebpf_spec) {
	let feat = {};
	try { feat = ubus.call('luci.homeproxy', 'singbox_get_features') || {}; } catch (e) { feat = {}; }

	let problems = [];

	/* ① 内核版本 ≥ 6.6 */
	const kv = _hp_kernel_version();
	if (!kv)
		push(problems, '无法读取内核版本（/proc/sys/kernel/osrelease 为空）');
	else if (kv.major < 6 || (kv.major == 6 && kv.minor < 6))
		push(problems, sprintf('当前内核 %s 低于 eBPF 要求的 6.6。请升级内核：MT7981 等 ARM64 设备请用 OpenWrt 25.12+ 自带内核（6.6/6.12），或在本插件「状态 → 内核」更新到 1.14.4-reF1nd 且系统内核 ≥ 6.6', kv.raw));

	/* ② 内核/内核二进制带 with_ebpf */
	if (feat.with_ebpf !== true)
		push(problems, sprintf('当前 sing-box 未编译 eBPF 支持（缺 with_ebpf）。当前版本：%s。请到「状态 → 内核管理 → 下载/更新内核」，安装本仓库带 with_ebpf 的 1.14.4-reF1nd 内核', feat.version || '未知/未安装'));

	/* ③ cgroup v2 路径（local=cgroup 数据面） */
	if (ebpf_spec.local === 'cgroup' && !access('/sys/fs/cgroup'))
		push(problems, '缺少 /sys/fs/cgroup（cgroup v2 未启用，local=cgroup 数据面无法挂载）。请在固件中启用 cgroup v2，或改用 local=socket_assign 的 eBPF 模式');

	/* ④ bpffs */
	if (!_hp_bpffs_ready())
		push(problems, 'bpffs 不可用（/sys/fs/bpf 无法挂载或不可写）。eBPF 程序无法加载，请确认内核编译了 CONFIG_BPF_SYSCALL 且可 mount -t bpf');

	if (length(problems) > 0) {
		ebpf_fallback = problems;
		_hp_log(sprintf('eBPF 模式「%s」不可用，已自动回退到 redirect_tproxy（服务将照常运行，仅不走 eBPF）：', proxy_mode));
		for (let i = 0; i < length(problems); i++)
			_hp_log(sprintf('  [%d] %s', i + 1, problems[i]));
		_hp_log('修复上述问题后，在本页重新选择 eBPF 模式并保存即可切换。');
		/* 回退：让本次生成按 redirect_tproxy 走。三件事缺一不可（第一版只做了
		   ①，结果 inbound 里既无 ebpf 也无 redirect —— 劫持入口整个消失，全屋
		   断网；238 现场复现：google=000，nft 有规则但 5331 无监听）：
		     ① ebpf_spec = null → 不再生成 eBPF inbound；
		     ② proxy_mode = 'redirect_tproxy' → 下文 match(proxy_mode,/redirect|tproxy/)
		        的 inbound 分支（redirect-in / tproxy-in）会正常生成；
		     ③ 补设 self_mark / redirect_port / tproxy_port —— 这些在 232-238 行
		        按**原** proxy_mode 分支赋值，而那段在本自检**之前**已执行过
		        （当时 proxy_mode 还是 eBPF，三个端口都没设），必须在这里补上，
		        否则 redirect-in 的 listen_port 是 int(null)。
		   同时把生效模式与原因写进 RUN_DIR/ebpf_fallback 标记文件：
		     · firewall_post.ut 读它 —— uci 里 proxy_mode 仍是 eBPF 值，但这次
		       生效的是 redirect_tproxy，防火墙必须生成 redirect 劫持链；
		     · 前端（status.js / rpcd）读它 —— 把回退原因展示给用户。
		   内容为 JSON：{"mode":"redirect_tproxy","reasons":[...]} */
		ebpf_spec = null;
		proxy_mode = 'redirect_tproxy';
		self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';
		redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '5331';
		if (main_udp_node !== 'nil' || routing_mode === 'custom')
			tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';
		writefile(RUN_DIR + '/ebpf_fallback',
			sprintf('%.J\n', { mode: 'redirect_tproxy', reasons: problems }));
	} else {
		_hp_log(sprintf('eBPF 模式「%s」能力自检通过（内核 %s、with_ebpf、cgroup、bpffs 均满足）。',
			proxy_mode, (kv ? kv.raw : '?')));
		/* 自检通过：清掉可能残留的回退标记（上一次回退留下的）。 */
		system('rm -f ' + shellQuote(RUN_DIR + '/ebpf_fallback'));
	}
}

if (ebpf_spec) {
	/* eBPF 透明代理：由 sing-box 的内核 eBPF inbound 直接接管流量，不再使用
	   nftables 的 redirect/tproxy 劫持链（firewall_post.ut 里 redirect/tproxy/tun
	   三类分支都不会命中，故不会生成劫持规则）。
	   - local（本机进程）：cgroup 数据面挂 cgroup 钩子；socket_assign 数据面走 tcx。
	   - shared（LAN 转发）：socket_assign 或 packet_rewrite，均通过 tcx 附着网卡。
	   data_plane 完全由所选模式决定，不再有单独的开关。 */
	ebpf_cgroup_path = uci.get(uciconfig, ucimain, 'ebpf_cgroup_path');
	ebpf_bypass_private = uci.get(uciconfig, ucimain, 'ebpf_bypass_private');
	/* shared 数据面必须指定接管哪个网卡（sing-box: "shared.interface
	   must not be empty"）。取值优先级：UI 显式 ebpf_interface → control.listen_interfaces
	   第一项 → network.lan.device → eth0。 */
	ebpf_interface = uci.get(uciconfig, ucimain, 'ebpf_interface');
	if (isEmpty(ebpf_interface)) {
		let li = uci.get(uciconfig, 'control', 'listen_interfaces');
		if (type(li) === 'array' && length(li) > 0)
			ebpf_interface = li[0];
	}
	if (isEmpty(ebpf_interface))
		ebpf_interface = uci.get('network', 'lan', 'device') || uci.get('network', 'lan', 'ifname') || 'eth0';
}

/* Only the four levels the UI offers are accepted by sing-box. A hand-edited
   or restored config carrying anything else (e.g. "warning") would make
   `sing-box check` fail and the whole service refuse to start, so clamp it
   instead of trusting UCI verbatim.
   默认与兜底都是 warn：info 级别会把**每一条**连接写进日志（现场实测 30 秒 122 行、
   约 350 KB/天），而这个日志落在 tmpfs（/var/run）上，等于直接吃内存；繁忙网络 +
   小内存路由会明显受影响。要看连接记录，去「运行日志」页把级别临时调成 info。 */
const log_level_uci = uci.get(uciconfig, ucimain, 'log_level') || 'warn';

const log_level = (log_level_uci == 'debug' || log_level_uci == 'info' ||
	log_level_uci == 'warn' || log_level_uci == 'error') ? log_level_uci : 'warn';

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

/* 内核 remote provider 的「种子」文件路径。update_subscriptions.uc 在每次
   成功更新订阅后把**原始正文**写到这里；reF1nd 的 provider/remote 在
   没有 bbolt 缓存时会读 initial_path（remote.go: `loadInitialPath()`），
   因此内核启动**不需要联网拉订阅** —— 这点很关键：源码 `StartContext()`
   只有在「既没缓存也没 initial_path」时才同步 `fetch()`，一旦 fetch 失败
   就直接返回错误，整个 sing-box 起不来（实测：`start provider/...: no
   servers found` → FATAL）。 */
function provider_seed_path(group_hash) {
	return sprintf('%s/providers/%s.sub', HP_DIR, group_hash);
}

function provider_seed_exists(group_hash) {
	let fp = null;
	try {
		fp = open(provider_seed_path(group_hash), 'r');
	} catch (e) {
		return false;
	}
	if (!fp)
		return false;
	try { fp.close(); } catch (e) {}
	return true;
}

/* 全局面板测速地址：取第一个配了 urltest_url 的分组，兜底 google
   generate_204（与 urltest 出站的默认值保持同一口径，别用 gstatic ——
   它在 china_list 里且实测会把可用节点判成不可用）。 */
function provider_probe_url() {
	let url = null;
	uci.foreach(uciconfig, uciroutingsetting, (cfg) => {
		if (url !== null)
			return;
		const candidate = trim(cfg.urltest_url ?? '');
		if (!isEmpty(candidate))
			url = candidate;
	});
	return url ?? 'https://www.google.com/generate_204';
}

/* 原生 `providers`（reF1nd 1.14.4 的顶层字段）——恢复面板「代理供应商」页。
   与已归档的 002 补丁（`clash_api.proxy_providers`，tags-only）不同，
   原生 provider 的 outbounds 由内核自己解析订阅正文生成，因此：

   · `initial_path` 指向插件写好的种子 → 启动不联网、不会因机场挂掉而
     拖垮整个服务；内核随后按 `update_interval` 后台更新并自行填充
     `subscriptionInfo`（已用/总量/到期）。
   · provider 的节点会**同时**出现在 `/proxies` 里（名字形如 `机场名/节点名`），
     这是原生设计的固有行为。
   · 以下三种情况一律**不下发** provider（都会让内核起不来）：
     1) `cache_file` 关闭 —— 内核报 `provider initial_path requires cache_file`；
     2) 该机场一个节点都没有 —— 内核报 `no servers found`；
     3) 种子文件还不存在（全新安装尚未成功更新过订阅）—— 会退化成启动时
        同步拉取，机场不可达即 FATAL。等第一次订阅更新写入种子后自然出现。 */
function build_native_providers() {
	if (cache_file_enabled === '0')
		return [];

	let providers = [],
	    used_names = {},
	    subscription_names = normalize_list(uci.get(uciconfig, 'subscription', 'subscription_name')),
	    probe_url = provider_probe_url(),
	    sub_index = 0;

	for (let suburl in normalize_list(uci.get(uciconfig, 'subscription', 'subscription_url'))) {
		const subscription_name = subscription_names[sub_index];
		sub_index++;

		if (isEmpty(suburl) || isEmpty(trim(subscription_name ?? '')))
			continue;

		const url = replace(suburl, /#.*$/, ''),
		      group_hash = md5(url);

		let has_nodes = false;
		uci.foreach(uciconfig, ucinode, (cfg) => {
			if (cfg.grouphash === group_hash)
				has_nodes = true;
		});
		if (!has_nodes)
			continue;

		if (!provider_seed_exists(group_hash))
			continue;

		push(providers, {
			type: 'remote',
			tag: unique_provider_name(subscription_provider_name(subscription_name), used_names),
			url: url,
			initial_path: provider_seed_path(group_hash),
			/* provider 更新订阅 URL 时要自己解析机场域名。sing-box 1.14 **不**
			   让 provider 继承 route.default_domain_resolver（实测 237：
			   default_domain_resolver=dnspod 已设仍报错），缺省时内核去找隐式
			   "local" 解析器并报 `domain resolver not found: local`，
			   provider 更新全部失败（订阅运行期内永不更新）。显式指向
			   default-dns（直连 UDP 223.5.5.5）——机场域名就该直连解析。 */
			domain_resolver: { server: 'default-dns' },
			/* info 节点（剩余流量/到期等）导致的 provider 更新失败（
			   `domain resolver not found: local`）见需求书 99 —— 内核侧
			   provider filter 实测不生效（invert 语义未确认），插件 seed
			   过滤需 base64 解码重编码，均留待单独一轮。 */
			/* 24h：与常见的机场流量刷新节奏相当；间隔过长会让面板的
			   已用/到期长期不动，过短则等于每次重启都多下一遍订阅。 */
			update_interval: '24h',
			/* 不指定 `http_client`：内核会用「默认出站」下载（并打印一条
			   1.14 的 deprecated 警告，功能到 1.16 前都有效）。
			   试过 `http_client: {detour: 'direct-out'}` —— 实测被内核拒绝：
			   `detour to an empty direct outbound makes no sense`
			   （common/dialer/detour.go:64：显式 detour 指向「空 direct」即报错，
			   只有 `defaultOutbound` 走的隐式路径才跳过该检查，而本项目的
			   `direct-out` 正是空 direct）。 */
			health_check: {
				enabled: true,
				url: probe_url,
				interval: '10m',
				timeout: '6s'
			}
		});
	}

	return providers;
}

/* 【当前不再被调用，保留作参考/后续重做原生 providers 的蓝本】
   这是旧 002 补丁（已归档到 tools/sing-box-patches/archive-1.14.3/）的
   `clash_api.proxy_providers` 数据结构：补丁内核会据此合成
   `/providers/proxies`，`proxies` 里放的是 outbound tag 字符串而不是 proxy 对象，
   键名沿用 Clash API 的 snake_case（`vehicle_type`/`updated_at`/`update_id`/
   `subscription_info`）。
   reF1nd 1.14.4 内核不再接受该字段，且其原生 providers 是顶层 `providers`
   （内核自行拉订阅、自行生成 outbound），与本插件「订阅解析后展开成 outbound」
   的模型重复，因此这里暂不下发。若日后改用原生 providers，可基于本函数改造。 */
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
	   Clash API abort. The reF1nd 1.14.4-reF1nd kernel (like 1.14.3) still lacks the
	   `store_selected` option on the global cache_file, so this repo's build-deploy.yml
	   applies tools/sing-box-patches/003-add-cache-file-store-selected-1.14.4.patch which
	   adds it back, so the patched kernel accepts cache_file.store_selected and persists
	   the selected outbound across restarts. Outdated stock kernels without that patch
	   would reject it as an unknown field. */
	/* 不再下发 `proxy_providers`：它是旧 002 补丁的自定义字段，reF1nd 1.14.4 内核
	   不认识（`unknown field "proxy_providers"` → 服务拒绝启动）。1.14.4 原生
	   providers 是顶层字段且会自行拉订阅生成 outbound，与本插件模型重复，故不用。
	   影响：面板的「代理供应商」页不再有数据（需要旧补丁内核才有该页），
	   代理/分流/节点测速等功能不受影响。 */
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
		/* 不下发 detour 字段：本项目 direct-out 是「空 direct」出站，
		   sing-box 1.14 会直接拒绝（common/dialer/detour.go:64
		   "detour to an empty direct outbound makes no sense"），表现为
		   `ERROR ntp: initialize time: detour to an empty direct outbound makes no sense`
		   —— 时间同步完全失效（237 实测）。省略 detour 时内核用隐式默认出站，正常。 */
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
/* 默认路由接口：从 /proc/net/route 里找 Destination=00000000 的那一行。
   用于判断「配置给 shared 的接口」是不是本机的默认出口接口（单网口设备
   LAN/WAN 同一个 eth0 就属于这种情况）。 */
function default_route_interface() {
	const content = readfile('/proc/net/route');
	if (isEmpty(content))
		return null;

	/* 注意：ucode 的 `for (x in array)` 遍历的是**元素**而不是下标，
	   所以这里直接用 line 元素本身，不能按数组下标去取。 */
	for (let line in split(content, '\n')) {
		const fields = split(trim(line), '\t');
		if (length(fields) < 8 || isEmpty(fields[0]))
			continue;
		/* 表头那行 fields[1] 是 "Destination"，自然被排除。 */
		if (fields[1] !== '00000000')
			continue;

		return fields[0];
	}

	return null;
}

if (ebpf_spec) {
	/* 内核 eBPF 透明代理 inbound。字段遵循 sing-box 1.14.4 的 option.EBPFInboundOptions：
	   local/shared 各自 {enabled, data_plane, ...}。四种模式都已确定
	   local/shared 的 data_plane，这里直接照搬，不再做开关判断。 */
	let ebpf_inbound = {
		type: 'ebpf',
		tag: 'ebpf-in',
		network: ['tcp', 'udp']
	};
	let local_opt = { enabled: true, data_plane: ebpf_spec.local };
	/* DNS 必须交给正常的劫持链（nft dstnat :53 → redirect to :5333）处理，不能让
	   eBPF 在 TC/cgroup 层先截走。默认 dns_mode=hijack 时，eBPF 在 netfilter 之前
	   就吃掉发往本机 53 的查询，却又没转交给 sing-box 的 DNS 入口（5333），
	   结果是**静默丢弃**。192.168.0.23 现场：网关+DNS 指向 237 后局域网 WEB 能开
	   （TCP 转发正常）、国内外域名全部解析失败；237 上
	   `nslookup www.baidu.com 192.168.0.237` 超时，而 `127.0.0.1:53` 与
	   `192.168.0.237:5333` 均正常；把 proxy_mode 临时改为 redirect_tproxy
	   （无 eBPF）后 `192.168.0.237:53` 立刻恢复 —— 由此定位。
	   取值：off（默认，完全交给 nft 的 dstnat 劫持链）/ respect_policy / hijack。
	   实测：respect_policy / hijack 仍会让 192.168.0.237:53 超时，只有 off 恢复。 */
	const ebpf_dns_mode = uci.get(uciconfig, uciinfra, 'ebpf_dns_mode') || 'off';
	local_opt.dns_mode = ebpf_dns_mode;
	/* cgroup_path 只在 local=cgroup 时合法（sing-box: "local.cgroup_path requires
	   local.data_plane=cgroup"），socket_assign 下不得下发。 */
	if (ebpf_spec.local === 'cgroup' && !isEmpty(ebpf_cgroup_path))
		local_opt.cgroup_path = ebpf_cgroup_path;
	/* 默认跳过私有地址：LAN 内部访问不该被劫持（ebpf_bypass_private 默认开）。 */
	if (ebpf_bypass_private === '1')
		local_opt.bypass_private_address = true;
	ebpf_inbound.local = local_opt;

	let shared_opt = { enabled: true, data_plane: ebpf_spec.shared };
	/* 与 local 同理：shared 侧的 DNS 也不能被 eBPF 抢在 netfilter 之前截走，
	   否则 LAN 设备的 DNS 请求会静默丢失（192.168.0.23 现场）。 */
	shared_opt.dns_mode = ebpf_dns_mode;
	/* shared 数据面必须绑定网卡接口（sing-box 要求非空）。 */
	if (!isEmpty(ebpf_interface)) {
		shared_opt.interface = [ ebpf_interface ];

		/* 关键：sing-box 的 activeSharedInterfaces() 会**把默认路由接口从
		   shared.interface 里删掉**，除非显式 default_interface=true：
		       if includeDefaultInterface { return configured }
		       return DeleteFunc(configured, n => n == defaultInterface)
		   单网口设备（x86 软路由 LAN 与 WAN 同为 eth0）配置的接口正好就是默认
		   路由接口，于是 shared 列表被删空，inbound 永远停在
		       state=waiting_for_interface, waiting_paths=["shared"]
		   —— 本机(local)照常工作、**LAN 设备却完全不被代理**，正是 237 实测
		   到的现象（切换 socket_assign / packet_rewrite 都一样）。
		   多网口设备（eth0=LAN、eth1=WAN）两者不相等，不会置位，行为不变。 */
		if (ebpf_interface === default_route_interface())
			shared_opt.default_interface = true;
	}
	if (ebpf_bypass_private === '1')
		shared_opt.bypass_private_address = true;
	ebpf_inbound.shared = shared_opt;

	push(config.inbounds, ebpf_inbound);
}
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
			const urltest_base = collect_group_nodes(cfg.subscription_groups, cfg.subscription_nodes, cfg.selected_nodes, legacy_nodes, cfg.filter_nodes, cfg.filter_keywords);
			/* 手动挂的策略组（policy_nodes）同样参与自动选择（三种工作模式
			   统一，UI 与生成行为一致）。 */
			const urltest_policy = collect_policy_nodes(cfg.policy_nodes, cfg['.name']);
			const urltest_list = [...urltest_base, ...filter(urltest_policy, (l) => !~index(urltest_base, l))];
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
		} else if (cfg.node === 'score') {
			/* 综合评分组（工作模式=自动选择(综合评分)）：生成 selector，成员
			   收集与 urltest 相同，default 可由用户设初始值（selector_default），
			   运行期由 score_nodes.uc 按「日志失败观测 + 有界实测」动态切换
			   （对齐 honk 的 Score 语义）。评分器按 uci node=='score' 识别本组。 */
			const score_base = collect_group_nodes(cfg.subscription_groups, cfg.subscription_nodes, cfg.selected_nodes, null, cfg.filter_nodes, cfg.filter_keywords);
			const score_policy = collect_policy_nodes(cfg.policy_nodes, cfg['.name']);
			const score_node_list = [...score_base, ...filter(score_policy, (l) => !~index(score_base, l))];
			const score_tags = map(score_node_list, (k) => get_section_outbound_tag(k));
			/* 综合评分组**不设 default**：初始选中由评分器第一轮实测后 PUT 写入
			   （评分语义 = 评分器全权，UI 也不提供默认成员选项 —— 用户确认）。 */
			push(config.outbounds, {
				type: 'selector',
				tag: get_section_outbound_tag(cfg['.name']),
				outbounds: length(score_tags) ? score_tags : [ 'direct-out' ],
				interrupt_exist_connections: false
			});
			urltest_nodes = [...urltest_nodes, ...filter(score_node_list, (l) => !~index(urltest_nodes, l))];
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
/* 必须**无条件**生成：`clash_api` 是面板（zashboard 等）唯一的入口，
   `cache_file` 负责选中节点/FakeIP/DNS 缓存。
   0.4.0 之前这段被 `if (routing_mode in ['bypass_mainland_china', 'custom'])`
   包住，导致 gfwlist / proxy_mainland_china / global 三种路由模式下**根本没有
   clash_api**（9095 不监听、面板连不上）也没有 cache_file —— 既有缺陷，随本次
   一并修正（面板与路由模式无关）。

   关于 `proxy_providers`：它是旧 002 补丁（已归档）的自定义字段，reF1nd 1.14.4
   内核不认识它，`sing-box check` 直接报
   `experimental.clash_api.proxy_providers: json: unknown field "proxy_providers"`
   并拒绝启动；而 1.14.4 原生的 providers 是**顶层**字段、由内核自己拉订阅并生成
   outbound，与本插件「订阅解析后展开成 outbound」的模型重复（会多出一批无人引用
   的 outbound 并重复下载订阅），因此不再下发该字段。 */
config.experimental = {
	clash_api,
	cache_file: {
		enabled: cache_file_enabled !== '0',
		path: cache_file_path || (HP_DIR + '/cache.db'),
		store_dns: strToBool(cache_store_dns),
		store_selected: cache_store_selected !== '0'
	}
};
/* Experimental end */

/* Native providers（reF1nd 1.14.4 顶层字段）——面板「代理供应商」页的数据源。
   条件不满足时返回空数组，removeBlankAttrs 会把空字段删掉，等于不下发。 */
const native_providers = build_native_providers();
if (length(native_providers) > 0)
	config.providers = native_providers;
/* Native providers end */

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
		/* 明确告警：本次生成的配置里没有任何“真实节点”出站，DNS/路由全部退回
		   直连。常见原因：① 确实没配节点；② routing_mode=bypass_mainland_china
		   但 main_node 为空；③ custom 模式但 default_outbound 指向的段不存在；
		   ④ 装包覆盖后 config 段丢失（routing_mode 读空 → 走默认 bypass →
		   main_node 空）。把 uci 里实际 node 段数一并记下，避免“静默变直连”。
		   —— 2026-11 现场：某次装 0.4.15 后 config.uci.bak 缺 config 段，
		   82 个节点全在、服务却“启动成功”跑直连，就是这个分支。 */
		let _hp_node_n = 0;
		try { uci.foreach(uciconfig, ucinode, () => { _hp_node_n++; }); } catch (e) { _hp_node_n = -1; }
		_hp_log(sprintf('警告：客户端配置没有任何节点出站（DNS/路由全部退回直连）。uci node 段=%d，routing_mode=%s，main_node=%s。若 node 段>0 却无出站，请检查 routing_mode / main_node / default_outbound（装包覆盖后 config 段可能丢失，可在 LuCI 设置页重新保存一次）。',
			_hp_node_n, routing_mode ?? '?', main_node ?? '?'));

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
