/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require fs';
'require poll';
'require rpc';
'require ui';
'require view';

'require homeproxy as hp';

/*
 * The proxy panel mirrors what a Clash dashboard shows, but it lives inside
 * LuCI instead of talking to port 9090 from the browser:
 *
 *   - every request is forwarded by rpcd (luci.homeproxy.clash_api_*), so the
 *     API secret never reaches the front end and no CORS header is needed;
 *   - the "proxy providers" tab cannot come from the Clash API at all: sing-box
 *     only implements /providers/proxies as an empty stub and its config schema
 *     has no proxy_providers field (emitting one aborts startup), so the cards
 *     are built from the subscription metadata HomeProxy stores in UCI.
 */

const TEST_URL = 'http://www.gstatic.com/generate_204';
const TEST_TIMEOUT = 5000;
const TEST_WORKERS = 3;
const POLL_INTERVAL = 8;

const callClashGet = rpc.declare({
	object: 'luci.homeproxy',
	method: 'clash_api_get',
	params: [ 'path' ],
	expect: { '': {} }
});

const callClashSelect = rpc.declare({
	object: 'luci.homeproxy',
	method: 'clash_api_select',
	params: [ 'path', 'name' ],
	expect: { '': {} }
});

const callClashDelay = rpc.declare({
	object: 'luci.homeproxy',
	method: 'clash_api_delay',
	params: [ 'path' ],
	expect: { '': {} }
});

const callSubscriptionList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'subscription_list',
	expect: { '': { subscriptions: [] } }
});

const css = `
.hp-panel { display:block; }
.hp-panel-bar {
	display:flex; align-items:center; flex-wrap:wrap; gap:10px;
	padding:10px 12px; margin-bottom:14px;
	background:#fff; border:1px solid #e6eaf0; border-radius:8px;
}
.hp-tabs { display:flex; align-items:center; gap:4px; flex-wrap:wrap; }
.hp-tab {
	display:inline-flex; align-items:center; gap:6px;
	padding:6px 12px; border:0; border-radius:6px;
	background:transparent; color:#5c6675;
	font-size:14px; font-weight:600; cursor:pointer;
}
.hp-tab:hover { background:#f2f5f9; color:#2c3345; }
.hp-tab.active { background:#eef3fb; color:#1c5fbf; }
.hp-tab .hp-count {
	min-width:18px; padding:0 5px; border-radius:9px;
	background:#e8ecf2; color:#7d8aa0;
	font-size:11px; font-weight:700; line-height:18px; text-align:center;
}
.hp-tab.active .hp-count { background:#d7e4f8; color:#1c5fbf; }
.hp-spacer { flex:1 1 auto; }
.hp-search {
	width:210px; max-width:46vw; height:30px; padding:0 10px;
	border:1px solid #dfe5ed; border-radius:6px;
	font-size:13px; color:#2c3345; background:#fff;
}
.hp-search:focus { outline:none; border-color:#8fb6ec; box-shadow:0 0 0 2px rgba(74,144,217,.15); }
.hp-iconbtn {
	display:inline-flex; align-items:center; justify-content:center;
	height:30px; min-width:30px; padding:0 8px;
	border:1px solid #dfe5ed; border-radius:6px;
	background:#fff; color:#5c6675; font-size:13px; cursor:pointer;
}
.hp-iconbtn:hover { background:#f5f8fc; color:#1c5fbf; border-color:#c9d8ee; }
.hp-iconbtn[disabled] { opacity:.5; cursor:default; }

.hp-note {
	display:flex; align-items:flex-start; gap:8px;
	padding:12px 14px; margin-bottom:12px;
	border:1px solid #f2d9b8; border-radius:8px;
	background:#fdf7ee; color:#8a5a17; font-size:13px; line-height:1.6;
}
.hp-note.danger { border-color:#f2c2c2; background:#fdf1f1; color:#a12d2d; }
.hp-note > span { flex:1 1 auto; }
.hp-note a { flex:none; color:#a12d2d; font-weight:600; text-decoration:underline; white-space:nowrap; }
.hp-empty {
	padding:26px 16px; border:1px dashed #dfe5ed; border-radius:8px;
	color:#8b95a6; font-size:13px; text-align:center;
}

.hp-cards { display:grid; grid-template-columns:repeat(auto-fill, minmax(420px, 1fr)); gap:12px; align-items:start; }
.hp-card {
	border:1px solid #e6eaf0; border-radius:10px; background:#fff;
	box-shadow:0 1px 3px rgba(28,40,64,.05); overflow:hidden;
}
.hp-card-head {
	display:flex; align-items:center; gap:8px;
	padding:11px 13px; cursor:pointer; user-select:none;
}
.hp-card-head:hover { background:#fafbfd; }
.hp-card-mark {
	display:inline-flex; align-items:center; justify-content:center;
	width:18px; height:18px; border-radius:50%;
	background:#e9f7ee; color:#2f9e44; font-size:11px; font-weight:700; flex:none;
}
.hp-card-mark.auto { background:#eef3fb; color:#1c5fbf; }
.hp-card-name { font-size:14px; font-weight:700; color:#2c3345; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hp-card-type {
	padding:1px 5px; border-radius:4px; background:#f2f5f9; color:#8b95a6;
	font-size:10px; font-weight:700; letter-spacing:.04em; flex:none;
}
.hp-card-count { margin-left:auto; color:#98a2b3; font-size:12px; flex:none; }
.hp-card-action {
	flex:none; padding:0 2px; color:#b6bfcc; font-size:12px; cursor:pointer; line-height:1;
}
.hp-card-action:hover { color:#1c5fbf; }
.hp-card-caret { color:#b6bfcc; font-size:11px; flex:none; }

.hp-card-now {
	display:flex; align-items:center; gap:6px;
	padding:0 13px 8px; font-size:12px; color:#5c6675;
}
.hp-card-now .hp-dot { width:8px; height:8px; }
.hp-card-now b { font-weight:600; color:#2c3345; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hp-ms { margin-left:auto; color:#98a2b3; flex:none; }

.hp-dots { display:flex; flex-wrap:wrap; gap:3px; padding:0 13px 11px; }
.hp-dot { width:9px; height:9px; border-radius:50%; background:#d7dde6; }

.hp-members {
	display:grid; grid-template-columns:repeat(auto-fill, minmax(140px, 1fr));
	gap:6px; padding:10px 13px 13px; border-top:1px solid #f1f4f8;
}
.hp-member {
	display:flex; align-items:center; gap:6px; min-width:0;
	padding:6px 8px; border:1px solid #e6eaf0; border-radius:6px;
	background:#fff; color:#3c4657; font-size:12px; cursor:pointer; text-align:left;
}
.hp-member:hover { border-color:#bcd2ef; background:#f7faff; }
.hp-member.active { border-color:#8fb6ec; background:#eef5ff; color:#1c5fbf; font-weight:600; }
.hp-member-name { flex:1 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hp-member-ms { flex:none; color:#98a2b3; font-size:11px; }

.hp-provider {
	display:flex; gap:11px; padding:13px;
	border:1px solid #e6eaf0; border-radius:10px; background:#fff;
	box-shadow:0 1px 3px rgba(28,40,64,.05);
}
.hp-provider-avatar {
	display:flex; align-items:center; justify-content:center; flex:none;
	width:38px; height:38px; border-radius:9px;
	color:#fff; font-size:15px; font-weight:700;
}
.hp-provider-main { flex:1 1 auto; min-width:0; }
.hp-provider-title { display:flex; align-items:center; gap:7px; flex-wrap:wrap; }
.hp-provider-title b { font-size:14px; color:#2c3345; }
.hp-provider-meta { color:#98a2b3; font-size:12px; }
.hp-provider-usage {
	display:flex; align-items:center; gap:8px; flex-wrap:wrap;
	margin-top:6px; color:#5c6675; font-size:12px;
}
.hp-provider-usage .hp-expire { margin-left:auto; color:#98a2b3; }
.hp-bar { height:5px; margin-top:6px; border-radius:3px; background:#eef1f6; overflow:hidden; }
.hp-bar > i { display:block; height:100%; border-radius:3px; background:#2f9e44; }
.hp-chips { display:flex; flex-wrap:wrap; gap:4px; margin-top:9px; max-height:74px; overflow:hidden; }
.hp-chip {
	padding:2px 6px; border-radius:4px; background:#f2f5f9; color:#5c6675;
	font-size:11px; max-width:150px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
.hp-chip.more { background:#eef3fb; color:#1c5fbf; }
.hp-section-head { display:flex; align-items:center; gap:10px; margin-bottom:10px; }
.hp-section-head > span { color:#8b95a6; font-size:12px; }
.hp-section-head .btn { margin-left:auto; }
`;

const GROUP_TYPES = {
	selector: 'SELECTOR',
	urltest: 'URLTEST',
	fallback: 'FALLBACK',
	loadbalance: 'LOAD BALANCE'
};

const VIEW_COLORS = [ '#e8564b', '#2f9e44', '#1c5fbf', '#f0ad4e', '#8e44ad', '#16a085', '#d35400', '#34495e' ];

const state = {
	tab: 'proxy',
	loading: true,
	error: null,
	proxies: {},
	groups: [],
	tested: {},
	testing: false,
	expanded: {},
	search: '',
	subscriptions: null,
	subLoading: false,
	body: null,
	bar: null
};

/* DOM nodes that need repainting while a URL test runs, keyed by node name.
   Rebuilding the whole panel for every single result would flicker and lose
   the expanded group the user is looking at. */
let live = { dots: {}, delays: {} };

function isGroup(proxy) {
	return proxy && Array.isArray(proxy.all) &&
		GROUP_TYPES[String(proxy.type || '').toLowerCase()] != null;
}

function isSelector(group) {
	return String(group.type || '').toLowerCase() === 'selector';
}

function buildGroups(proxies) {
	const groups = [];

	for (const name in proxies) {
		const proxy = proxies[name];

		if (!isGroup(proxy))
			continue;

		groups.push({
			name: name,
			type: proxy.type,
			now: proxy.now || '',
			members: proxy.all.slice()
		});
	}

	/* GLOBAL is a synthetic group sing-box appends to every /proxies reply;
	   dashboards always park it at the bottom. */
	groups.sort((a, b) => {
		const ga = (a.name === 'GLOBAL') ? 1 : 0,
		      gb = (b.name === 'GLOBAL') ? 1 : 0;

		return ga - gb;
	});

	return groups;
}

function lastDelay(name) {
	if (name in state.tested)
		return state.tested[name];

	const proxy = state.proxies[name],
	      history = (proxy && Array.isArray(proxy.history)) ? proxy.history : null;

	if (history && history.length) {
		const delay = parseInt(history[history.length - 1].delay, 10);
		return isNaN(delay) ? null : delay;
	}

	return null;
}

function delayColor(delay) {
	if (delay == null)
		return '#d7dde6';

	if (delay <= 0)
		return '#e03131';

	if (delay < 300)
		return '#2f9e44';

	if (delay < 800)
		return '#f0ad4e';

	return '#e8590c';
}

function fmtDelay(delay) {
	if (delay == null)
		return '';

	return (delay > 0) ? '%d ms'.format(delay) : _('Timeout');
}

function fmtBytes(bytes) {
	const value = parseInt(bytes, 10);

	if (isNaN(value) || value < 0)
		return '-';

	if (value === 0)
		return '0 B';

	const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let size = value, unit = 0;

	while (size >= 1024 && unit < units.length - 1) {
		size /= 1024;
		unit++;
	}

	return (unit === 0 || size >= 100)
		? '%d %s'.format(Math.round(size), units[unit])
		: '%s %s'.format(size.toFixed(1), units[unit]);
}

function pad2(value) {
	return (value < 10) ? '0' + value : '' + value;
}

/* Subscription-Userinfo carries Unix seconds; 0 / missing means "no expiry". */
function fmtDate(seconds) {
	const value = parseInt(seconds, 10);

	if (isNaN(value) || value <= 0)
		return _('Unlimited');

	const date = new Date(value * 1000);

	return '%d-%s-%s'.format(date.getFullYear(), pad2(date.getMonth() + 1), pad2(date.getDate()));
}

/* `updated_at` is written by update_subscriptions.uc through homeproxy.uc's
   getTime(), i.e. an already formatted "YYYY-MM-DD HH:MM:SS" string, while
   `expire` comes straight from Subscription-Userinfo as Unix seconds. */
function fmtDateTime(value) {
	if (value == null || value === '')
		return '-';

	if (typeof value === 'string' && !/^\d+$/.test(value))
		return value;

	const seconds = parseInt(value, 10);

	if (isNaN(seconds) || seconds <= 0)
		return '-';

	const date = new Date(seconds * 1000);

	return '%d-%s-%s %s:%s'.format(date.getFullYear(), pad2(date.getMonth() + 1),
		pad2(date.getDate()), pad2(date.getHours()), pad2(date.getMinutes()));
}

function errorText(code) {
	switch (code) {
	case 'clash_api_unavailable':
		return _('Clash API is unreachable. It is only generated in the "Custom" and "Bypass mainland China" modes, and the service has to be running.');

	case 'invalid_path':
	case 'invalid_argument':
		return _('Invalid request.');

	default:
		return _('Failed to read the Clash API: %s').format(code || _('unknown error'));
	}
}

function notify(message, level) {
	ui.addNotification(null, E('p', {}, message), level || 'info');
}

/* Keep the search box usable as a regex like the dashboards do, but never let
   an unfinished pattern (e.g. "香港(") break the whole list. */
function matchSearch(name, search) {
	if (!search)
		return true;

	try {
		return new RegExp(search, 'i').test(name);
	} catch (e) {
		return name.toLowerCase().indexOf(search.toLowerCase()) !== -1;
	}
}

function filteredGroups() {
	const search = state.search.trim();

	return state.groups.filter((group) => {
		if (!search)
			return true;

		if (matchSearch(group.name, search))
			return true;

		return group.members.some((member) => matchSearch(member, search));
	});
}

function renderDots(group) {
	return E('div', { 'class': 'hp-dots' }, group.members.map((member) => {
		const dot = E('span', {
			'class': 'hp-dot',
			'title': member,
			'style': 'background:%s'.format(delayColor(lastDelay(member)))
		});

		(live.dots[member] = live.dots[member] || []).push(dot);

		return dot;
	}));
}

function renderMember(group, member) {
	const delay = lastDelay(member),
	      ms = E('span', {
		'class': 'hp-member-ms',
		'style': 'color:%s'.format((delay != null && delay > 0) ? delayColor(delay) : '#98a2b3')
	      }, [ fmtDelay(delay) ]);

	(live.delays[member] = live.delays[member] || []).push(ms);

	return E('button', {
		'class': 'hp-member' + (member === group.now ? ' active' : ''),
		'title': member,
		'click': () => selectMember(group, member)
	}, [
		E('span', { 'class': 'hp-member-name' }, [ member ]),
		ms
	]);
}

function renderGroup(group) {
	const expanded = !!state.expanded[group.name],
	      nowDelay = group.now ? lastDelay(group.now) : null,
	      selector = isSelector(group);

	const children = [
		E('div', {
			'class': 'hp-card-head',
			'click': () => {
				state.expanded[group.name] = !state.expanded[group.name];
				renderBody();
			}
		}, [
			E('span', {
				'class': 'hp-card-mark' + (selector ? '' : ' auto'),
				'title': selector ? _('Manual selection') : _('Automatic selection')
			}, [ selector ? '✓' : 'A' ]),
			E('span', { 'class': 'hp-card-name', 'title': group.name }, [ group.name ]),
			E('span', { 'class': 'hp-card-type' }, [ GROUP_TYPES[String(group.type).toLowerCase()] ]),
			E('span', { 'class': 'hp-card-count' }, [ _('%d nodes').format(group.members.length) ]),
			E('span', {
				'class': 'hp-card-action',
				'title': _('Test latency of this group'),
				'click': (ev) => {
					ev.stopPropagation();
					return testGroup(group, ev.currentTarget);
				}
			}, [ '⚡' ]),
			E('span', { 'class': 'hp-card-caret' }, [ expanded ? '▲' : '▼' ])
		])
	];

	if (group.now) {
		const nowDot = E('span', { 'class': 'hp-dot', 'style': 'background:%s'.format(delayColor(nowDelay)) }),
		      ms = E('span', { 'class': 'hp-ms' }, [ fmtDelay(nowDelay) ]);

		(live.dots[group.now] = live.dots[group.now] || []).push(nowDot);
		(live.delays[group.now] = live.delays[group.now] || []).push(ms);

		children.push(E('div', { 'class': 'hp-card-now' }, [
			nowDot,
			E('b', { 'title': group.now }, [ group.now ]),
			ms
		]));
	}

	children.push(renderDots(group));

	if (expanded)
		children.push(E('div', { 'class': 'hp-members' },
			group.members.map((member) => renderMember(group, member))));

	return E('div', { 'class': 'hp-card' }, children);
}

function renderProxyTab() {
	const groups = filteredGroups();

	if (!groups.length) {
		return E('div', { 'class': 'hp-empty' }, [
			state.search ? _('No proxy group matches "%s".').format(state.search)
			             : _('No proxy group found. Add policy groups in "Node Settings" first.')
		]);
	}

	return E('div', { 'class': 'hp-cards' }, groups.map(renderGroup));
}

function providerColor(name) {
	let sum = 0;

	for (let i = 0; i < name.length; i++)
		sum += name.charCodeAt(i);

	return VIEW_COLORS[sum % VIEW_COLORS.length];
}

function renderProvider(provider) {
	const used = (parseInt(provider.upload, 10) || 0) + (parseInt(provider.download, 10) || 0),
	      total = parseInt(provider.total, 10) || 0,
	      percent = (total > 0) ? Math.min(100, Math.round(used / total * 100)) : 0,
	      barColor = (percent >= 90) ? '#e03131' : (percent >= 70 ? '#f0ad4e' : '#2f9e44');

	const usage = E('div', { 'class': 'hp-provider-usage' }, [
		E('span', {}, [
			(total > 0)
				? _('%s of %s used (%d%%)').format(fmtBytes(used), fmtBytes(total), percent)
				: _('This subscription reports no traffic information.')
		]),
		E('span', { 'class': 'hp-expire' }, [ _('Expires: %s').format(fmtDate(provider.expire)) ])
	]);

	const chips = provider.nodes.slice(0, 48).map((node) =>
		E('span', { 'class': 'hp-chip', 'title': node }, [ node ]));

	if (provider.nodes.length > 48)
		chips.push(E('span', { 'class': 'hp-chip more' }, [ '+%d'.format(provider.nodes.length - 48) ]));

	return E('div', { 'class': 'hp-provider' }, [
		E('div', { 'class': 'hp-provider-avatar', 'style': 'background:%s'.format(providerColor(provider.name)) },
			[ provider.name.slice(0, 1).toUpperCase() ]),
		E('div', { 'class': 'hp-provider-main' }, [
			E('div', { 'class': 'hp-provider-title' }, [
				E('b', {}, [ provider.name ]),
				E('span', { 'class': 'hp-provider-meta' }, [ _('%d nodes').format(provider.count) ]),
				E('span', { 'class': 'hp-provider-meta' }, [ _('Updated: %s').format(fmtDateTime(provider.updated_at)) ])
			]),
			usage,
			(total > 0) ? E('div', { 'class': 'hp-bar' }, [
				E('i', { 'style': 'width:%d%%; background:%s'.format(Math.max(percent, 1), barColor) })
			]) : null,
			chips.length ? E('div', { 'class': 'hp-chips' }, chips) : null
		])
	]);
}

function updateSubscriptions(ev) {
	const btn = ev.currentTarget;

	btn.disabled = true;
	btn.textContent = _('Updating…');

	const restore = () => {
		btn.disabled = false;
		btn.textContent = _('Update subscriptions');
	};

	return fs.exec_direct('/etc/homeproxy/scripts/update_subscriptions.uc').then((res) => {
		restore();

		if (res && res.code === 0) {
			notify(_('Subscriptions updated.'), 'info');
			return loadProviders();
		}

		notify(_('Updating subscriptions failed. See the runtime log for details.'), 'danger');
		return null;
	}, (err) => {
		restore();
		notify(_('Updating subscriptions failed: %s').format(err), 'danger');
		return null;
	});
}

function renderProvidersTab() {
	if (state.subLoading && !state.subscriptions)
		return E('div', { 'class': 'hp-empty' }, [ _('Loading subscriptions…') ]);

	const providers = state.subscriptions || [];

	if (!providers.length) {
		return E('div', { 'class': 'hp-empty' }, [
			_('No subscription configured. Add one in "Node Settings" to see it here.')
		]);
	}

	return E('div', {}, [
		E('div', { 'class': 'hp-section-head' }, [
			E('span', {}, [ _('%d subscriptions').format(providers.length) ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': updateSubscriptions
			}, [ _('Update subscriptions') ])
		]),
		E('div', { 'class': 'hp-cards' }, providers.map(renderProvider))
	]);
}

function updateCounts() {
	if (!state.bar)
		return;

	const proxyCount = state.bar.querySelector('[data-hp-count="proxy"]'),
	      providerCount = state.bar.querySelector('[data-hp-count="providers"]');

	if (proxyCount)
		proxyCount.textContent = state.groups.length;

	if (providerCount)
		providerCount.textContent = (state.subscriptions || []).length;
}

function renderBody() {
	if (!state.body)
		return;

	live = { dots: {}, delays: {} };

	if (state.loading && !state.groups.length) {
		dom.content(state.body, E('div', { 'class': 'hp-empty' }, [ _('Loading…') ]));
		return;
	}

	if (state.tab === 'proxy' && state.error) {
		dom.content(state.body, E('div', { 'class': 'hp-note danger' }, [
			E('span', {}, [ errorText(state.error) ]),
			(state.error === 'clash_api_unavailable')
				? E('a', { 'href': L.url('admin/services/homeproxy/client') }, [ _('Client Settings') ])
				: null
		]));
		return;
	}

	dom.content(state.body, (state.tab === 'proxy') ? renderProxyTab() : renderProvidersTab());
	updateCounts();
}

function loadProxies(silent) {
	if (!silent) {
		state.loading = true;
		renderBody();
	}

	return L.resolveDefault(callClashGet('/proxies'), {}).then((res) => {
		if (!res || res.error || !res.data) {
			state.error = (res && res.error) ? res.error : 'invalid_response';

			if (silent !== true) {
				state.proxies = {};
				state.groups = [];
			}
		} else {
			state.error = null;
			state.proxies = res.data.proxies || {};
			state.groups = buildGroups(state.proxies);
		}

		state.loading = false;
		renderBody();
	});
}

function loadProviders() {
	state.subLoading = true;
	renderBody();

	return L.resolveDefault(callSubscriptionList(), { subscriptions: [] }).then((res) => {
		state.subscriptions = res.subscriptions || [];
		state.subLoading = false;
		renderBody();
	});
}

function delayPath(name) {
	return '/proxies/%s/delay?url=%s&timeout=%d'.format(
		encodeURIComponent(name), encodeURIComponent(TEST_URL), TEST_TIMEOUT);
}

/* url-test every member, at most TEST_WORKERS requests in flight: rpcd spawns
   one wget per call, so a 40-node group would otherwise queue for a minute. */
function testNames(names) {
	const queue = names.slice();
	let index = 0;

	function next() {
		if (index >= queue.length)
			return Promise.resolve();

		const name = queue[index++];

		return L.resolveDefault(callClashDelay(delayPath(name)), {})
			.then((res) => {
				state.tested[name] = (res && res.delay) ? res.delay : 0;
				paintNode(name);
				return next();
			});
	}

	const workers = [];

	for (let i = 0; i < Math.min(TEST_WORKERS, queue.length); i++)
		workers.push(next());

	return Promise.all(workers);
}

/* Latency test for one group, triggered from the card header. */
function testGroup(group, btn) {
	if (state.testing)
		return Promise.resolve();

	state.testing = true;
	btn.textContent = '…';

	const done = () => {
		state.testing = false;
		btn.textContent = '⚡';
	};

	return testNames(group.members).then(done, done);
}

function paintNode(name) {
	const delay = lastDelay(name),
	      color = delayColor(delay),
	      text = fmtDelay(delay);

	(live.dots[name] || []).forEach((dot) => { dot.style.background = color; });
	(live.delays[name] || []).forEach((ms) => {
		ms.textContent = text;
		ms.style.color = (delay != null && delay > 0) ? color : '#98a2b3';
	});
}

function selectMember(group, member) {
	if (!isSelector(group)) {
		notify(_('This group selects its node automatically; nothing to switch.'), 'warning');
		return Promise.resolve();
	}

	return L.resolveDefault(callClashSelect('/proxies/' + encodeURIComponent(group.name), member), {})
		.then((res) => {
			if (res && res.result) {
				group.now = member;
				renderBody();
				notify(_('Switched to %s.').format(member), 'info');
			} else {
				notify(_('Failed to switch node: %s').format(
					(res && res.status) ? ('HTTP ' + res.status)
						: ((res && res.error) || _('unknown error'))), 'danger');
			}
		});
}

function renderBar() {
	const proxyTab = E('button', {
		'class': 'hp-tab' + ((state.tab === 'proxy') ? ' active' : ''),
		'click': () => {
			if (state.tab === 'proxy')
				return;

			state.tab = 'proxy';
			renderBar();
			renderBody();
		}
	}, [
		_('Proxies'),
		E('span', { 'class': 'hp-count', 'data-hp-count': 'proxy' }, [ state.groups.length ])
	]);

	const providerTab = E('button', {
		'class': 'hp-tab' + ((state.tab === 'providers') ? ' active' : ''),
		'click': () => {
			if (state.tab === 'providers')
				return;

			state.tab = 'providers';
			renderBar();

			if (state.subscriptions == null)
				return loadProviders();

			renderBody();
			return null;
		}
	}, [
		_('Proxy providers'),
		E('span', { 'class': 'hp-count', 'data-hp-count': 'providers' }, [ (state.subscriptions || []).length ])
	]);

	const search = E('input', {
		'class': 'hp-search',
		'type': 'text',
		'placeholder': _('Search groups | Regex'),
		'value': state.search,
		'input': (ev) => {
			state.search = ev.target.value;
			renderBody();
		}
	});

	const refreshBtn = E('button', {
		'class': 'hp-iconbtn',
		'title': _('Refresh'),
		'click': (ev) => {
			const btn = ev.currentTarget;
			btn.disabled = true;

			const done = () => { btn.disabled = false; };

			return (state.tab === 'providers')
				? loadProviders().then(done, done)
				: loadProxies().then(done, done);
		}
	}, [ '↻' ]);

	const testBtn = E('button', {
		'class': 'hp-iconbtn',
		'title': _('Test latency of every node'),
		'click': (ev) => {
			const btn = ev.currentTarget;

			if (state.testing)
				return null;

			const names = [];

			state.groups.forEach((group) => {
				group.members.forEach((member) => {
					if (names.indexOf(member) === -1)
						names.push(member);
				});
			});

			if (!names.length)
				return null;

			state.testing = true;
			btn.disabled = true;
			btn.textContent = '…';

			return testNames(names).then(() => {
				state.testing = false;
				btn.disabled = false;
				btn.textContent = '⚡';
			}, () => {
				state.testing = false;
				btn.disabled = false;
				btn.textContent = '⚡';
			});
		}
	}, [ '⚡' ]);

	state.bar = E('div', { 'class': 'hp-panel-bar' }, [
		E('div', { 'class': 'hp-tabs' }, [ proxyTab, providerTab ]),
		E('span', { 'class': 'hp-spacer' }),
		search,
		testBtn,
		refreshBtn
	]);

	if (state.barHost)
		dom.content(state.barHost, state.bar);

	return state.bar;
}

return view.extend({
	render() {
		hp.installCloseButtonText();

		const barHost = E('div', {}),
		      body = E('div', { 'class': 'hp-panel-body' });

		state.barHost = barHost;
		state.body = body;

		/* Poll silently: a running URL test already repaints dots by itself and
		   must not be interrupted by a full reload. */
		poll.add(() => {
			if (state.tab !== 'proxy' || state.testing)
				return;

			/* The user may have navigated away while polling was still armed;
			   rendering into a detached node would leak requests forever. */
			if (!state.body || !document.body.contains(state.body))
				return;

			return loadProxies(true);
		}, POLL_INTERVAL);

		renderBar();
		loadProxies();

		return E([
			E('style', [ css ]),
			E('div', { 'class': 'cbi-map' }, [ barHost, body ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
