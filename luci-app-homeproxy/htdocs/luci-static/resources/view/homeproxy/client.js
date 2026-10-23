/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
'require network';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require homeproxy as hp';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callRCInit = rpc.declare({
	object: 'rc',
	method: 'init',
	params: ['name', 'action'],
	expect: { '': {} }
});

const callReadDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

const callCurrentNode = rpc.declare({
	object: 'luci.homeproxy',
	method: 'current_node_get',
	expect: { '': {} }
});

const callPackageVersion = rpc.declare({
	object: 'luci.homeproxy',
	method: 'package_get_version',
	expect: { '': {} }
});

const callUpdatePanel = rpc.declare({
	object: 'luci.homeproxy',
	method: 'clash_api_update_panel',
	params: ['only_if_missing', 'attempt', 'total'],
	expect: { '': {} }
});

const callRulesetStatus = rpc.declare({
	object: 'luci.homeproxy',
	method: 'ruleset_status',
	expect: { '': {} }
});

const callRulesetUpdate = rpc.declare({
	object: 'luci.homeproxy',
	method: 'ruleset_update',
	params: ['section'],
	expect: { '': {} }
});

const callDnsServerTest = rpc.declare({
	object: 'luci.homeproxy',
	method: 'dns_server_test',
	params: ['section'],
	expect: { '': {} }
});

const statusCss = `
#homeproxy_status_panel {
	margin-bottom: 1rem;
}
#homeproxy_status_panel .homeproxy-status-grid {
	display: grid;
	grid-template-columns: repeat(3, minmax(0, 1fr)) auto;
	gap: 10px;
	align-items: center;
}
#homeproxy_status_panel .homeproxy-status-field {
	min-width: 0;
}
#homeproxy_status_panel .homeproxy-status-label {
	font-weight: 600;
	text-align: center;
	margin-bottom: 6px;
}
#homeproxy_status_panel input {
	width: 100%;
	min-width: 0;
}
#homeproxy_status_panel .homeproxy-version-field input {
	width: 100%;
}
#homeproxy_status_panel .homeproxy-core-version-field input {
	width: 100%;
}
#homeproxy_status_panel .homeproxy-core-status-field input {
	width: 100%;
	text-align: center;
}
#homeproxy_status_panel .homeproxy-core-status {
	border: unset;
	font-style: italic;
	font-weight: 700;
}
#homeproxy_status_panel .homeproxy-status-actions {
	display: flex;
	flex-wrap: nowrap;
	gap: 6px;
	align-items: center;
	justify-content: flex-end;
	min-width: 0;
}
#homeproxy_status_panel .homeproxy-status-actions .btn {
	width: auto;
	min-width: 0;
	padding-left: 6px;
	padding-right: 6px;
	white-space: nowrap;
}
@media (max-width: 700px) {
	#homeproxy_status_panel .homeproxy-status-grid {
		grid-template-columns: 1fr;
	}
	#homeproxy_status_panel .homeproxy-status-actions {
		flex-wrap: wrap;
		justify-content: flex-start;
	}
	#homeproxy_status_panel .homeproxy-status-actions .btn {
		flex: 1 1 auto;
	}
}`;

function getServiceStatus() {
	return L.resolveDefault(callServiceList('homeproxy'), {}).then((res) => {
		let isRunning = false;
		try {
			isRunning = res['homeproxy']['instances']['sing-box-c']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function updateCoreStatus(isRunning, currentNode) {
	let status = document.getElementById('homeproxy_core_status');
	if (!status)
		return;

	status.style.color = isRunning ? 'green' : 'red';
	status.value = currentNode ? _('Running: %s').format(currentNode) : (isRunning ? _('Running') : _('Not Running'));
}

function parseControllerPort(externalController) {
	let value = externalController || '127.0.0.1:9090';
	let idx = value.lastIndexOf(':');
	return (idx >= 0) ? value.substring(idx + 1) : '9090';
}

function getClashApiInfo() {
	let port = parseControllerPort(uci.get('homeproxy', 'clash_api', 'external_controller')),
	    secret = uci.get('homeproxy', 'clash_api', 'secret') || '';

	return {
		port,
		secret,
		baseUrl: 'http://' + window.location.hostname + ':' + port
	};
}

function updateDashboard() {
	return callUpdatePanel(false, 1, 1).then((res) => {
		if (!res?.result) {
			let message = res?.error;
			if (message === 'update_panel_failed')
				message = _('Update panel failed.');
			else if (message === 'clash_api_unavailable')
				message = _('Clash API unavailable.');
			else if (message === 'panel_backup_failed')
				message = _('Backup panel failed.');
			else if (message === 'panel_restore_failed')
				message = _('Restore panel failed.');

			throw new Error(message || _('Update failed.'));
		}
		ui.addNotification(null, E('p', _('Successfully updated.')), 'info');
	}).catch((err) => {
		ui.addNotification(null, E('p', err.message || err), 'danger');
	});
}

function ensurePanelInstalled() {
	const tryUpdate = (remaining) => callUpdatePanel(true, 3 - remaining + 1, 3).then((res) => {
		if (res?.result)
			return res;

		/* Single backend request already enforces a 120s timeout
		   (clashAPIRequest(..., 120)): each panel download that exceeds
		   120s is reported back as 'clash_api_unavailable'. On a download
		   timeout or a download failure, retry the download. The 2s gap
		   lets the homeproxy service finish restarting after 'Save & Apply'
		   before the next attempt. tryUpdate(3) = 3 download attempts in
		   total (1 initial + 2 retries). */
		if ((res?.error === 'clash_api_unavailable' || res?.error === 'update_panel_failed') && remaining > 1)
			return new Promise((resolve) => setTimeout(resolve, 2000))
				.then(() => tryUpdate(remaining - 1));

		return res;
	});

	return tryUpdate(3).then((res) => {
		if (res?.result) {
			if (!res.skipped)
				ui.addNotification(null, E('p', _('Panel downloaded.')), 'info');
			return res;
		}

		let message;
		if (res?.error === 'clash_api_unavailable')
			message = _('Panel download failed after 3 attempts (Clash API unavailable). Please install the panel manually.');
		else if (res?.error === 'update_panel_failed')
			message = _('Panel download failed after 3 attempts. Please install the panel manually.');
		else if (res?.error === 'panel_backup_failed')
			message = _('Backup panel failed.');
		else if (res?.error === 'panel_restore_failed')
			message = _('Restore panel failed.');
		else
			message = _('Update failed.');

		ui.addNotification(null, E('p', message || _('Update failed.')), 'danger');
		return res;
	}).catch(() => {});
}

function openDashboard() {
	let api = getClashApiInfo();
	let params = new URLSearchParams({
		host: window.location.hostname,
		hostname: window.location.hostname,
		secret: api.secret,
		port: api.port
	});

	window.open(api.baseUrl + '/ui/?' + params.toString(), '_blank');
	return Promise.resolve();
}

function normalizeRuleSetSectionId(tag) {
	return 'ruleset_' + tag.replace(/[^A-Za-z0-9_]/g, '_').replace(/^_+|_+$/g, '');
}

function getDnsServerDefaultPort(type) {
	switch (type) {
	case 'udp':
	case 'tcp':
		return '53';
	case 'tls':
	case 'quic':
		return '853';
	case 'https':
	case 'h3':
		return '443';
	default:
		return 'auto';
	}
}

function getDnsServerAddressPlaceholder(type) {
	switch (type) {
	case 'https':
	case 'h3':
		return '';
	case 'tls':
	case 'quic':
		return 'dns.alidns.com';
	default:
		return '';
	}
}

function validateDnsServerAddress(type, value) {
	if (!value)
		return false;

	/* 各类型对应的协议头；HTTPS/HTTP/3 均可使用 https 或 h3 协议头 */
	const allowedSchemes = {
		udp: ['udp'], tcp: ['tcp'], tls: ['tls'], quic: ['quic'],
		https: ['https'], h3: ['https', 'h3']
	}[type] || [type];

	if (value.includes('://')) {
		let url;
		try {
			url = new URL(value);
		} catch (e) {
			return false;
		}
		if (!allowedSchemes.includes(url.protocol.replace(':', '').toLowerCase()))
			return false;

		value = url.hostname;
	}

	return stubValidator.apply('hostname', value) ||
		stubValidator.apply('ip4addr', value) ||
		stubValidator.apply('ip6addr', value.match(/^\[(.+)\]$/)?.[1] || value);
}

function validateDuration(value) {
	return !value || /^[1-9]\d*(ms|s|m|h|d)$/.test(value);
}

function validateUpdateCron(value) {
	if (!value)
		return true;

	const matched = String(value).trim().match(/^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+([0-7*])$/);
	if (!matched)
		return false;

	return +matched[1] <= 59 && +matched[2] <= 23;
}

function translateKnownError(error) {
	let name = error?.name || '',
	    message = error?.message || error || '';

	if (name === 'TypeError' && String(message).match(/can't convert null to object|Cannot convert undefined or null to object/i))
		return _('Type error') + '\n' + _('Cannot convert null to object.');

	return null;
}

function installKnownErrorTranslator() {
	if (window.__homeproxyKnownErrorTranslator)
		return;

	window.__homeproxyKnownErrorTranslator = true;

	window.addEventListener('error', (ev) => {
		let message = translateKnownError(ev.error || ev.message);
		if (message) {
			ev.preventDefault();
			ui.addNotification(null, E('p', message), 'danger');
		}
	}, true);

	window.addEventListener('unhandledrejection', (ev) => {
		let message = translateKnownError(ev.reason);
		if (message) {
			ev.preventDefault();
			ui.addNotification(null, E('p', message), 'danger');
		}
	}, true);
}

function renderRuleSetAdd(section, extra_class) {
	let el = form.GridSection.prototype.renderSectionAdd.apply(section, [ extra_class ]),
	    nameEl = el.querySelector('.cbi-section-create-name'),
	    button = el.querySelector('.cbi-section-create > .cbi-button-add'),
	    uciconfig = section.uciconfig || section.map.config,
	    mapData = section.map && section.map.data;

	/* Rule set tags are also used to build the local .srs file name, so they
	   stay ASCII-only. The hint below the create box makes that explicit. */
	const baseHint = _('Used as the sing-box rule set tag and display name. Only letters, digits, ".", "_" and "-" are allowed. Chinese is not supported. It must be unique.');

	let tagEl = E('input', {
		'type': 'text',
		'class': nameEl.className
	});
	let hintEl = E('div', { 'class': 'cbi-value-description' }, baseHint);

	nameEl.style.display = 'none';

	/* Upstream wraps the hidden name input in an anonymous <div> and puts the
	   add button as a *sibling* of that wrapper. Rebuild the controls so the
	   visible tag input and the add button share one flex row and the hint sits
	   on its own line below. Otherwise the button is rendered below the input. */
	el.style.display = 'block';

	const wrapper = nameEl.parentNode;
	const row = E('div', { 'class': 'cbi-section-create-row' });
	row.style.display = 'flex';
	row.style.alignItems = 'center';
	row.style.gap = '.4em';
	row.style.flexWrap = 'wrap';

	row.appendChild(tagEl);     /* visible tag input */
	row.appendChild(nameEl);    /* hidden original, still used by handleAdd() */
	row.appendChild(button);    /* add button, same row as the input */
	el.appendChild(row);
	el.appendChild(hintEl);     /* hint below the row */

	/* The original wrapper is now empty; drop it so it cannot affect layout. */
	if (wrapper && wrapper.parentNode === el && wrapper.childElementCount === 0)
		wrapper.remove();

	/* LuCI's add button creates the section through map.data.add() and then
	   renders the edit modal synchronously. Writing the tag/label from a
	   setTimeout() therefore happens *after* the modal has already loaded, so
	   the 卷标 field shows up empty. Apply the pending tag inside
	   map.data.add() instead, i.e. before the modal is rendered. */
	if (mapData && !mapData.__hpRuleSetAdd) {
		mapData.__hpRuleSetAdd = { };

		const origAdd = mapData.add;
		mapData.add = function(config, type, name) {
			const sid = origAdd.apply(this, arguments),
			      pending = this.__hpRuleSetAdd[config + '|' + type];

			if (pending && sid) {
				uci.set(config, sid, 'tag', pending.tag);
				uci.set(config, sid, 'label', pending.tag);
				uci.set(config, sid, 'enabled', '1');
				uci.set(config, sid, 'type', 'remote');
				uci.set(config, sid, 'format', 'binary');
				uci.set(config, sid, 'remote_path', '/etc/homeproxy/ruleset/');
				uci.set(config, sid, 'auto_update', '1');
				uci.set(config, sid, 'update_interval', '0 0 * * *');
			}

			delete this.__hpRuleSetAdd[config + '|' + type];

			return sid;
		};
	}

	button.disabled = true;

	let syncSectionName = () => {
		if (mapData && mapData.__hpRuleSetAdd)
			delete mapData.__hpRuleSetAdd[uciconfig + '|ruleset'];

		let tag = (tagEl.value || '').trim();
		hintEl.textContent = baseHint;

		if (!tag) {
			nameEl.value = '';
			button.disabled = true;
			return;
		}

		if (!tag.match(/^[A-Za-z0-9_.-]+$/)) {
			nameEl.value = '';
			button.disabled = true;
			hintEl.textContent = _('Expecting: %s').format(_('valid tag'));
			return;
		}

		let duplicate = false;
		uci.sections(uciconfig, 'ruleset', (res) => {
			if ((res.tag || ('cfg-' + res['.name'] + '-rule')) === tag)
				duplicate = true;
		});

		if (duplicate) {
			nameEl.value = '';
			button.disabled = true;
			hintEl.textContent = _('Expecting: %s').format(_('unique value'));
			return;
		}

		let section_id = normalizeRuleSetSectionId(tag),
		    suffix = 1;
		while (uci.get(uciconfig, section_id))
			section_id = normalizeRuleSetSectionId(tag) + '_' + suffix++;

		nameEl.value = section_id;
		nameEl.dataset.sectionId = section_id;
		nameEl.dataset.ruleSetTag = tag;
		if (mapData && mapData.__hpRuleSetAdd)
			mapData.__hpRuleSetAdd[uciconfig + '|ruleset'] = { tag: tag };
		button.disabled = null;
	};

	tagEl.addEventListener('input', syncSectionName);
	tagEl.addEventListener('blur', syncSectionName);

	/* Run syncSectionName() in the capture phase so the pending tag is ready
	   before LuCI's own add handler (bound to the button) creates the section
	   and renders the modal; the tag itself is written by the map.data.add()
	   hook above, during the add. */
	el.addEventListener('click', (ev) => {
		if (ev.target === button || button.contains(ev.target))
			syncSectionName();
	}, true);

	return el;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

return view.extend({
	load() {
		return Promise.all([
			uci.load('homeproxy'),
			hp.getBuiltinFeatures(),
			network.getHostHints(),
			L.resolveDefault(callPackageVersion(), {})
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		installKnownErrorTranslator();
		hp.installCloseButtonText();
		hp.ensureUIStyles();

		let features = data[1],
		    hosts = data[2]?.hosts,
		    packageVersion = data[3]?.version || '-',
		    routingMode = uci.get(data[0], 'config', 'routing_mode');

		/* Cache all configured proxy nodes, they will be called multiple times */
		let proxy_nodes = {};
		let node_labels = {};
		let node_airports = {};
		let subscription_groups = {};
		let routing_groups = {};
		let normalizeFormList = function(value) {
			return Array.isArray(value) ? value : (value ? [value] : []);
		};
		/* Map each subscription (airport) URL hash to its display name so we
		   can prefix node display names with the airport they belong to. */
		let subscriptionUrls = normalizeFormList(uci.get(data[0], 'subscription', 'subscription_url')),
		    subscriptionNames = normalizeFormList(uci.get(data[0], 'subscription', 'subscription_name'));
		for (let i = 0; i < subscriptionUrls.length; i++) {
			let url = subscriptionUrls[i],
			    title = String(subscriptionNames[i] || '').trim();

			if (title)
				subscription_groups[hp.calcStringMD5(url.replace(/#.*$/, ''))] = title;
		}

		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = ((res.type === 'direct') ? res.override_address : res.address) || '',
			    nodeport = ((res.type === 'direct') ? res.override_port : res.port) || '',
			    nodefallback = (stubValidator.apply('ip6addr', nodeaddr) ?
					String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport,
			    nodelabel = res.label || nodefallback,
			    airport = (res.grouphash && subscription_groups[res.grouphash]) || '';

			/* Display name keeps the airport prefix for readability; the
			   unprefixed label is still stored in node_labels for the
			   keyword filter so its matching behaviour is unchanged. */
			let displayLabel = airport ? String.format('[%s] %s', airport, nodelabel) : nodelabel;

			node_labels[res['.name']] = nodelabel;
			node_airports[res['.name']] = airport;
			proxy_nodes[res['.name']] = String.format('[%s] %s', res.type, displayLabel);
		});
		/* Mirrors the generator's policy group node filter: keywords are
		   regexes matched against the node display name (the outbound tag). */
		let matchNodeFilter = function(node_id, filter_mode, filter_keywords) {
			if (filter_mode !== 'whitelist' && filter_mode !== 'blacklist')
				return true;

			let keywords = normalizeFormList(filter_keywords);
			if (!keywords.length)
				return true;

			let name = node_labels[node_id] || '',
			    matched = false;

			for (let keyword of keywords) {
				try {
					if (name && new RegExp(keyword).test(name)) {
						matched = true;
						break;
					}
				}
				catch (e) {}
			}

			return (filter_mode === 'whitelist') ? matched : !matched;
		};
		uci.sections(data[0], 'routing_node', (res) => {
			routing_groups[res['.name']] = res.label || res['.name'];
		});
		let collectSelectedRoutingNodes = function(groups, subscription_nodes, selected_nodes, policy_nodes, section_id, filter_mode, filter_keywords) {
			let nodes = [],
			    policies = [];
			groups = normalizeFormList(groups);
			subscription_nodes = normalizeFormList(subscription_nodes);
			selected_nodes = normalizeFormList(selected_nodes);
			policy_nodes = normalizeFormList(policy_nodes);

			uci.sections(data[0], 'node', (res) => {
				if (res.grouphash && groups.includes(res.grouphash) && !nodes.includes(res['.name']))
					nodes.push(res['.name']);
			});
			for (let node of subscription_nodes)
				if (proxy_nodes[node] && !nodes.includes(node))
					nodes.push(node);
			for (let node of selected_nodes)
				if (proxy_nodes[node] && !nodes.includes(node))
					nodes.push(node);
			for (let node of policy_nodes)
				if (node !== section_id && routing_groups[node] && !policies.includes(node))
					policies.push(node);

			let filtered = nodes.filter((node) => matchNodeFilter(node, filter_mode, filter_keywords));

			/* Same fallback as the generator: never end up with an empty list. */
			if (!filtered.length && nodes.length)
				filtered = nodes;

			return filtered.concat(policies);
		};

		m = new form.Map('homeproxy', _('HomeProxy'),
			_('OpenWrt-designed Sing-box proxy management platform. It is recommended to disable Dnsmasq DNS redirection.'));

		s = m.section(form.TypedSection);
		s.render = function () {
			const statusPoll = function () {
				return Promise.all([
					L.resolveDefault(getServiceStatus(), false),
					L.resolveDefault(callCurrentNode(), null)
				]).then((res) => {
					let isRunning = res[0],
					    current = res[1],
					    current_label = null;

					if (current?.mode === 'urltest') {
						let active = current.active || {};
						let nodeName = (active?.id && active.id !== 'urltest') ? (proxy_nodes[active.id] || active.label || active.id) : _('Invalid node');

						current_label = _('URLTest: %s').format(nodeName);
					}

					updateCoreStatus(isRunning, current_label);
					});
			};

			/* 重渲染（保存并应用）时由 hp.pollAdd 摘掉上一次注册的回调，
			   避免同一个轮询被叠加成多份、每周期多发一次 RPC。 */
			hp.pollAdd('client-status', statusPoll);

			let actions = [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, () => callRCInit('homeproxy', 'reload'))
				}, [ _('Reload Service') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(this, () => callRCInit('homeproxy', 'restart'))
				}, [ _('Restart Service') ])
			];

			/* The Clash API is enabled in both custom and
			   bypass_mainland_china modes, so expose the panel actions
			   in both instead of hiding them outside custom mode. */
			if (routingMode === 'custom' || routingMode === 'bypass_mainland_china') {
				actions.push(
					E('button', {
						'class': 'btn cbi-button cbi-button-positive',
						'click': ui.createHandlerFn(this, updateDashboard)
					}, [ _('Update Panel') ]),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, (ev) => hp.uploadPanel(null, ev))
					}, [ _('Upload Panel ZIP') ]),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, openDashboard)
					}, [ _('Open Panel') ])
				);
			}

			return E('div', { class: 'cbi-section', id: 'homeproxy_status_panel' }, [
				E('style', [ statusCss ]),
				E('h3', _('Status')),
				E('div', { class: 'homeproxy-status-grid' }, [
					E('div', { class: 'homeproxy-status-field homeproxy-version-field' }, [
						E('div', { class: 'homeproxy-status-label' }, _('Plugin Version')),
						E('input', { class: 'cbi-input-text', readonly: '', value: packageVersion })
					]),
					E('div', { class: 'homeproxy-status-field homeproxy-core-version-field' }, [
						E('div', { class: 'homeproxy-status-label' }, _('Core Version')),
						E('input', { class: 'cbi-input-text', readonly: '', value: features.version || '-' })
					]),
					E('div', { class: 'homeproxy-status-field homeproxy-core-status-field' }, [
						E('div', { class: 'homeproxy-status-label' }, _('Core Status')),
						E('input', {
							id: 'homeproxy_core_status',
							class: 'cbi-input-text homeproxy-core-status',
							readonly: '',
							value: _('Collecting data...')
						})
					]),
					E('div', { class: 'homeproxy-status-actions' }, actions)
				])
			]);
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');

		/* The "Panel Settings" tab must be hidden *entirely* (not just left
		   blank) in routing modes where the Clash API is not generated —
		   everything except `custom` and `bypass_mainland_china`. LuCI only
		   auto-hides a tab whose pane is empty; a depends-hidden option still
		   leaves its node in the DOM, so the button stays visible over an
		   empty pane. We strip the pane node ourselves based on the *live*
		   routing mode, which also covers the case where the mode is changed
		   and re-applied without a full page reload. */
		const _configSectionRender = s.render.bind(s);
		s.render = function () {
			return Promise.resolve(_configSectionRender()).then((node) => {
				let rm = routingMode;
				try {
					const live = this.formvalue('config', 'routing_mode');
					if (live != null)
						rm = live;
				} catch (e) {}

				if (rm !== 'custom' && rm !== 'bypass_mainland_china') {
					const panes = node.querySelectorAll('[data-tab="panel"]');
					for (let i = 0; i < panes.length; i++)
						panes[i].parentNode.removeChild(panes[i]);
				}
				return node;
			});
		};

		s.tab('routing', _('Routing Settings'));

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'));
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.depends({'routing_mode': 'custom', '!reverse': true});
		o.rmempty = false;

		o = s.taboption('routing', hp.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends('main_node', 'urltest');
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.default = '180';
		o.depends('main_node', 'urltest');

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.default = '50';
		o.depends('main_node', 'urltest');

		o = s.taboption('routing', form.ListValue, 'main_udp_node', _('Main UDP node'));
		o.value('nil', _('Disable'));
		o.value('same', _('Same as main node'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'same';
		o.depends({'routing_mode': /^((?!custom).)+$/, 'proxy_mode': /^((?!redirect$).)+$/});
		o.rmempty = false;

		o = s.taboption('routing', hp.CBIStaticList, 'main_udp_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends('main_udp_node', 'urltest');
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'main_udp_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.default = '180';
		o.depends('main_udp_node', 'urltest');

		o = s.taboption('routing', form.Value, 'main_udp_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.default = '50';
		o.depends('main_udp_node', 'urltest');

		o = s.taboption('routing', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://dns.cloudflare.com/dns-query', _('CloudFlare Public DNS (DoH)'));
		o.value('https://dns.google/dns-query', _('Google Public DNS (DoH)'));
		o.value('https://dns.quad9.net/dns-query', _('Quad9 Public DNS (DoH)'));
		o.value('https://dns.adguard-dns.com/dns-query', _('AdGuard Public DNS (DoH)'));
		o.value('https://dns.sb/dns-query', _('DNS.SB Public DNS (DoH)'));
		o.value('https://dns.opendns.com/dns-query', _('Cisco Public DNS (DoH)'));
		o.default = 'https://dns.quad9.net/dns-query';
		o.rmempty = false;
		o.depends({'routing_mode': 'custom', '!reverse': true});
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('https://doh-pure.onedns.net/dns-query', _('ThreatBook Public DNS (DoH)'));
		o.value('https://doh.pub/dns-query', _('Tencent Public DNS (DoH)'));
		o.value('https://dns.alidns.com/dns-query', _('AliYun Public DNS (DoH)'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.default = 'https://dns.alidns.com/dns-query';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
		o.value('gfwlist', _('GFWList'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('proxy_mainland_china', _('Only proxy mainland China'));
		o.value('custom', _('Custom routing'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;
		o.onchange = function(ev, section_id, value) {
			if (section_id && value === 'custom')
				this.map.save(null, true);
		}

		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'proxy_mode', _('Proxy mode'));
		o.value('redirect', _('Redirect TCP'));
		if (features.hp_has_tproxy)
			o.value('redirect_tproxy', _('Redirect TCP + TProxy UDP'));
		if (features.hp_has_ip_full && features.hp_has_tun) {
			o.value('redirect_tun', _('Redirect TCP + Tun UDP'));
			o.value('tun', _('Tun TCP/UDP'));
		} else {
			o.description = _('To enable Tun support, you need to install <code>ip-full</code> and <code>kmod-tun</code>');
		}
		o.default = 'redirect_tproxy';
		o.rmempty = false;

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = o.enabled;
		o.rmempty = false;

		/* Custom routing settings start */
		/* Routing settings start */
		o = s.taboption('routing', form.SectionValue, '_routing', form.NamedSection, 'routing', 'homeproxy');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		so = ss.option(form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack.'));
		if (features.with_gvisor) {
			so.value('mixed', _('Mixed'));
			so.value('gvisor', _('gVisor'));
		}
		so.value('system', _('System'));
		so.default = 'system';
		so.depends('homeproxy.config.proxy_mode', 'redirect_tun');
		so.depends('homeproxy.config.proxy_mode', 'tun');
		so.rmempty = false;
		so.onchange = function(ev, section_id, value) {
			let desc = ev.target.nextElementSibling;
			if (value === 'mixed')
				desc.innerHTML = _('Mixed <code>system</code> TCP stack and <code>gVisor</code> UDP stack.')
			else if (value === 'gvisor')
				desc.innerHTML = _('Based on google/gvisor.');
			else if (value === 'system')
				desc.innerHTML = _('Less compatibility and sometimes better performance.');
		}

		so = ss.option(form.Value, 'udp_timeout', _('UDP NAT expiration time'),
			_('In seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '300';
		so.default = '300';
		so.depends('homeproxy.config.proxy_mode', 'redirect_tproxy');
		so.depends('homeproxy.config.proxy_mode', 'redirect_tun');
		so.depends('homeproxy.config.proxy_mode', 'tun');

		so = ss.option(form.Flag, 'bypass_cn_traffic', _('Bypass CN traffic'),
			_('Bypass mainland China traffic via firewall rules by default.'));
		so.rmempty = false;

		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
			_('If set, the requested domain name will be resolved to IP before routing.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);

		so = ss.option(form.Flag, 'sniff_override', _('Override destination'),
			_('Override the connection destination address with the sniffed domain.'));
		so.default = so.enabled;
		so.rmempty = false;

		so = ss.option(form.ListValue, 'default_outbound', _('Default outbound (fallback)'),
			_('Default outbound for connections not matched by any routing rules.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('nil', _('Disable (the service)'));
			this.value('direct-out', _('Direct'));
			this.value('block-out', _('Block'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'nil';
		so.rmempty = false;

		so = ss.option(form.ListValue, 'default_outbound_dns', _('Default outbound DNS'),
			_('Default DNS server for resolving domain name in the server address.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'default-dns';
		so.rmempty = false;
		/* Routing settings end */

		/* Routing nodes start */
		s.tab('routing_node', _('Routing Nodes'));
		o = s.taboption('routing_node', form.SectionValue, '_routing_node', form.GridSection, 'routing_node');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Routing node'), _('Add a routing node'), data[0]);
		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
		/* 去掉 luci-base 额外插入的那列重复名称，名称列左移对齐 */
		hp.dedupeNameColumn(ss);
		/* 「启用」列移到名称列左侧 */
		hp.moveEnableColumn(ss);
		/* 序号列：放在最左侧（名称列之前），显示面板实际渲染顺序；
		   route.final 行会被强制置顶并标「置顶」，不参与拖动排序。 */
		hp.prependIndexColumn(ss, _('No.'));
		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss, null,
			_('Will be used as the sing-box outbound tag and display name. Chinese is supported. It must be unique and must not contain slashes, "?", "#" or "%".'),
			_('Drag policy groups by their order number from top to bottom; the pinned one cannot be dragged. This determines the order of the panel cards.'));

		/* 建议3：类型徽章列。urltest/selector 不再以英文术语裸露在表格里，
		   改为徽章显示（自动测速 / 手动选择）；urltest 的测速参数放在徽章
		   悬浮提示中。单节点包装则直接显示节点名。 */
		/* 建议1：当前节点 / 延迟列。渲染后从 sing-box Clash API
		   （GET /proxies）拉取运行时状态：沿 now 链解析实际出口节点并显示其
		   最近一次测速延迟。
		   这里以前只在 render 时拉一次 —— 只要那一次刚好碰上 sing-box 正在
		   重启（点「保存并应用」、切换节点、内核更新）或服务还没起来，整列就
		   被清空并且再也不会恢复，表现成「时不时整列空白」。现在改为：
		   轮询刷新 + 失败保留上次结果 + 未就绪时给占位符而不是留空白。 */
		const ROUTING_STATUS_SELECTOR = '.hp-rn-status[data-tag]';

		const applyRoutingProxies = function(container, proxies) {
			for (const span of container.querySelectorAll(ROUTING_STATUS_SELECTOR)) {
				/* 表格可能已经被重新渲染，写进脱离文档的旧节点没人看得见 */
				if (!span.isConnected)
					continue;

				const grp = proxies[span.getAttribute('data-tag')];

				if (!grp) {
					/* 服务未运行 / 该组未启用 / 刚启动还没注册出站：
					   有旧值就保留（标为过期态），没有就给占位符，不留空白。 */
					if (!span.textContent.trim() || span.textContent.trim() === '…') {
						span.textContent = '—';
						span.title = _('Service is not running or this policy group is disabled.');
					}

					span.classList.add('hp-rn-stale');
					continue;
				}

				span.classList.remove('hp-rn-stale');

				/* selector 嵌套策略组时沿 now 链取实际出口 */
				let cur = grp;

				for (let i = 0; cur && cur.now && proxies[cur.now] && i < 8; i++)
					cur = proxies[cur.now];

				const name = (cur && cur.name) || grp.now || '';

				if (!name) {
					if (!span.textContent.trim() || span.textContent.trim() === '…') {
						span.textContent = '—';
						span.title = _('Service is not running or this policy group is disabled.');
					}

					continue;
				}

				/* 最近一次测速延迟：优先 history，新版内核在 extra */
				let delay = null;
				const hist = (cur && cur.history) || [];

				if (hist.length)
					delay = hist[hist.length - 1].delay;
				else if (cur && cur.extra) {
					for (const key in cur.extra) {
						const h = cur.extra[key];

						if (h && h.length) {
							delay = h[h.length - 1].delay;
							break;
						}
					}
				}

				span.textContent = '';

				if (delay != null && delay > 0) {
					span.appendChild(document.createTextNode(name + ' · '));
					span.appendChild(E('span', { 'class': 'hp-rn-ms' }, String(delay) + ' ms'));
					span.title = name + ' · ' + delay + ' ms';
				}
				else {
					span.appendChild(document.createTextNode(name));
					span.title = name;
				}
			}
		};

		/* 拉一次 Clash API。失败时不清空已有内容，只把仍在转圈的「…」换成「—」。 */
		const refreshRoutingNodeStatus = function(container) {
			const api = getClashApiInfo(),
			      options = { headers: {}, cache: 'no-store' };

			if (api.secret)
				options.headers['Authorization'] = 'Bearer ' + api.secret;

			fetch(api.baseUrl + '/proxies', options)
				.then((res) => (res && res.ok) ? res.json() : Promise.reject(new Error('HTTP ' + (res && res.status))))
				.then((res) => applyRoutingProxies(container, (res && res.proxies) || {}))
				.catch(() => {
					for (const span of container.querySelectorAll(ROUTING_STATUS_SELECTOR)) {
						if (span.textContent.trim() !== '…')
							continue;

						span.textContent = '—';
						/* HTTPS 页面请求 http:// 的 API 端口会被浏览器按混合内容
						   直接拦掉，连请求都不会发出 —— 这种「全空」不是服务的问题，
						   必须给出可操作的提示，否则用户只会反复点刷新。 */
						span.title = (window.location.protocol === 'https:')
							? _('Cannot connect to the Clash API. LuCI is opened over HTTPS, so the browser blocks plain-HTTP requests to the API port; open LuCI over HTTP instead.')
							: _('Cannot connect to the Clash API. Check that the service is running and the API port is reachable.');
					}
				});
		};

		hp.appendTableColumns(ss, [
			{
				/* 该列显示「工作模式」徽章（自动选择 / 手动选择）；
				   固定成单个节点时直接显示节点名，所以表头不再叫「订阅机场」。 */
				header: _('Working mode'),
				renderCell: function(sid) {
					const node = uci.get(data[0], sid, 'node') || 'selector';

					if (node === 'urltest' || node === 'selector') {
						const badge = E('span', {
							'class': 'hp-tag ' + ((node === 'urltest') ? 'hp-tag-auto' : 'hp-tag-manual')
						}, (node === 'urltest') ? _('Auto select') : _('Manual select'));

						return badge;
					}

					return proxy_nodes[node] || node;
				}
			},
			{
				/* 该策略组实际用到的订阅机场。取三条来源的并集：
				   subscription_groups（按机场整包选）、subscription_nodes（按节点选，
				   反查所属机场）、以及自选节点（无机场，忽略）。 */
				header: _('Subscription airports'),
				renderCell: function(sid) {
					const node = uci.get(data[0], sid, 'node') || 'selector';

					if (node !== 'urltest' && node !== 'selector')
						return E('span', { 'class': 'hp-chip-empty' }, [ '—' ]);

					const names = [],
					      addName = function(name) {
						if (name && !names.includes(name))
							names.push(name);
					      };

					normalizeFormList(uci.get(data[0], sid, 'subscription_groups'))
						.forEach((hash) => addName(subscription_groups[hash] || _('Unnamed airport')));

					normalizeFormList(uci.get(data[0], sid, 'subscription_nodes'))
						.forEach((node_id) => addName(node_airports[node_id]));

					if (!names.length)
						return E('span', {
							'class': 'hp-chip-empty',
							'title': _('No subscription airport is selected.')
						}, [ '—' ]);

					/* 每行固定 5 个，超过换行（hp-chip-list-5） */
					return E('span', { 'class': 'hp-chip-list hp-chip-list-5' },
						names.map((name) => E('span', { 'class': 'hp-chip', 'title': name }, [ name ])));
				}
			},
			{
				/* 手动选择组可以把别的策略组挂成下级节点（policy_nodes），
				   顺序就是勾选顺序——内核按这个顺序构建 selector 的 outbounds。
				   自动选择组与单节点包装没有这一项。 */
				header: _('Policy nodes'),
				renderCell: function(sid) {
					const node = uci.get(data[0], sid, 'node') || 'selector';

					if (node !== 'selector')
						return E('span', { 'class': 'hp-chip-empty' }, [ '—' ]);

					const names = normalizeFormList(uci.get(data[0], sid, 'policy_nodes'))
						.map((id) => routing_groups[id] || _('Unknown policy node'));

					if (!names.length)
						return E('span', {
							'class': 'hp-chip-empty',
							'title': _('No policy node is selected.')
						}, [ '—' ]);

					/* 每行固定 5 个，超过换行（hp-chip-list-5） */
					return E('span', { 'class': 'hp-chip-list hp-chip-list-5' },
						names.map((name) => E('span', { 'class': 'hp-chip hp-chip-policy', 'title': name }, [ name ])));
				}
			},
			{
				header: _('Current node / Latency'),
				renderCell: function(sid) {
					/* 与 generate_client.uc 的 outbound tag 规则保持一致 */
					const label = uci.get(data[0], sid, 'label') || sid,
					      tag = String(label).trim()
							.replace(/[\r\n\t]+/g, ' ')
							.replace(/[\/\\?#%]+/g, '-')
							.replace(/\s+/g, ' ');

					return E('span', { 'class': 'hp-rn-status', 'data-tag': tag }, [ '…' ]);
				}
			},
			{
				/* 出站：单节点包装（自建节点 / 订阅节点）的上游出站。
				   对应 generate_client.uc 里 routed_outbound.detour = get_outbound(cfg.outbound)：
				   空值即无上游（直接由该节点拨出），有值则串到另一个路由节点的出站。
				   策略组（urltest / selector）没有这个概念，显示占位符。 */
				header: _('Outbound'),
				renderCell: function(sid) {
					const node = uci.get(data[0], sid, 'node') || 'selector';

					if (node === 'urltest' || node === 'selector')
						return E('span', {
							'class': 'hp-rn-out hp-rn-out-na',
							'title': _('Policy groups do not use an upstream outbound.')
						}, [ '—' ]);

					const upstream = uci.get(data[0], sid, 'outbound') || '';

					if (!upstream)
						return E('span', {
							'class': 'hp-rn-out hp-rn-out-direct',
							'title': _('This node dials out directly.')
						}, [ _('Direct') ]);

					let label = upstream;

					uci.sections(data[0], 'routing_node', (res) => {
						if (res['.name'] === upstream)
							label = res.label || upstream;
					});

					return E('span', {
						'class': 'hp-rn-out hp-rn-out-chain',
						'title': label + ' (' + upstream + ')'
					}, [ '→ ' + label ]);
				}
			}
		]);

		const routingNodeOrigRenderContents = ss.renderContents;

		/* 策略组排序：route.final（默认出口）强制置顶且不可拖动，其余行可
		   拖动手柄（操作列里的 ☰）重排；序号列显示面板实际顺序（final 恒为 1）。

		   注意 luci 的拖拽/触屏排序（form.js handleDrop / handleTouchEnd）只做
		   insertBefore + uci.move，**不会重绘表格**，并且会 stopPropagation，
		   所以不能靠 drop 事件回调补救；这里用 MutationObserver 盯 tbody 的
		   子节点变化，在排序落盘后再应用一次「置顶 + 重编号」。 */
		/* 「置顶」徽章：贴在名称格内、名称文字之后。
		   名称格在两种 luci-base 上都是 td.cbi-section-table-titles——
		   25.12 由内核渲染，24.10 由 hp.moveEnableColumn 用 tr[data-title]
		   补出来，因此这里不需要区分版本。找不到名称格时退回到操作列，
		   保证徽章一定可见。 */
		const addPinBadge = function(row) {
			if (row.querySelector('.hp-pin-badge'))
				return;

			const nameTd = row.querySelector('td.cbi-section-table-titles')
				|| row.querySelector('td.cbi-value-field[data-title]')
				|| row.querySelector('td.cbi-section-actions');

			if (!nameTd)
				return;

			nameTd.appendChild(E('span', {
				'class': 'hp-pin-badge',
				'title': _('Default outbound (route.final): always pinned to the top of the panel and cannot be reordered here.')
			}, _('Pinned')));
		};

		/* 封禁 final 行的拖动，两层保险：
		   ① 手柄本体克隆替换——luci 的 dragstart / touchmove / touchend 是
		      addEventListener 挂在手柄节点上的，克隆换掉原节点即连带剥离；
		      置顶行不保留灰色手柄，而是直接 display:none 把拖动按钮藏掉，
		      界面上彻底看不到 ☰，更直观；
		   ② tbody 捕获阶段拦截 dragstart / touchmove——即使某些主题把拖拽
		      监听器改挂在行或容器上，也会在这里被 preventDefault 掐断。 */
		const lockFinalRow = function(row, tbody) {
			row.dataset.hpPin = '1';
			row.setAttribute('draggable', 'false');

			const handle = row.querySelector('.drag-handle');

			if (handle && handle.dataset.hpDead !== '1') {
				const dead = handle.cloneNode(true);

				dead.dataset.hpDead = '1';
				dead.setAttribute('draggable', 'false');
				dead.setAttribute('aria-hidden', 'true');
				dead.setAttribute('title', _('Default outbound (route.final): always pinned to the top of the panel and cannot be reordered here.'));
				/* 直接隐藏拖动按钮，而非仅置灰 */
				dead.style.display = 'none';

				/* replaceChild 兼容老浏览器（replaceWith 在旧内核 WebView 上可能缺失） */
				if (handle.parentNode)
					handle.parentNode.replaceChild(dead, handle);
			}

			if (!tbody.dataset.hpPinGuard) {
				tbody.dataset.hpPinGuard = '1';

				const blockDrag = function(ev) {
					const t = ev.target,
					      tr = (t && t.closest) ? t.closest('tr[data-sid]') : null;

					if (tr && tr.dataset.hpPin === '1') {
						ev.preventDefault();
						ev.stopPropagation();
					}
				};

				tbody.addEventListener('dragstart', blockDrag, true);
				tbody.addEventListener('touchmove', blockDrag, { capture: true, passive: false });
			}
		};

		const pinFinalRoutingNode = function(el) {
			try {
				const tbody = el.querySelector('tbody.cbi-section-tbody') || el.querySelector('tbody');

				if (!tbody)
					return;

				/* route.final = routing.default_outbound 指向的 routing_node sid；
				   段名是 'routing'（见 generate_client.uc 的 uciroutingsetting），
				   不是 'routing_setting'——写错会让 uci.get 返回空、整个置顶逻辑失效。
				   nil / direct-out / block-out 不是策略组，无需置顶。 */
				const finalSid = uci.get(data[0], 'routing', 'default_outbound') || '';

				if (!finalSid || [ 'nil', 'direct-out', 'block-out' ].includes(finalSid))
					return;

				/* 数据行：真实配置段（跳过空表占位行） */
				const dataRows = function() {
					return Array.prototype.filter.call(
						tbody.querySelectorAll('tr'),
						(tr) => tr.hasAttribute('data-sid') && !tr.classList.contains('placeholder'));
				};

				let rows = dataRows();

				if (!rows.length)
					return;

				const finalRow = rows.find((tr) => tr.getAttribute('data-sid') === finalSid);

				if (!finalRow)
					return;

				/* 强制置顶：把 final 行移到 tbody 第一行 */
				if (tbody.firstElementChild !== finalRow)
					tbody.insertBefore(finalRow, tbody.firstElementChild);

				/* 按显示顺序重编号 序号 列（显示顺序 = 面板顺序，final 恒为 1） */
				let idx = 0,
				    stripe = 0;

				for (const tr of dataRows()) {
					idx++;

					/* 默认出口改成别的组后，清掉旧行的封禁标记，
					   避免它继续被捕获阶段的 dragstart 拦截 */
					if (tr !== finalRow && tr.dataset.hpPin === '1')
						delete tr.dataset.hpPin;

					const cell = tr.querySelector('td.hp-index-cell');

					if (cell && cell.textContent !== String(idx))
						cell.textContent = String(idx);

					/* 置顶搬运后重排斑马纹，避免相邻两行同色 */
					tr.classList.remove('cbi-rowstyle-1', 'cbi-rowstyle-2');
					tr.classList.add((stripe % 2 === 0) ? 'cbi-rowstyle-1' : 'cbi-rowstyle-2');
					stripe++;
				}

				/* 名称后面标「置顶」，并封禁该行的拖动手柄 */
				addPinBadge(finalRow);
				lockFinalRow(finalRow, tbody);
			}
			catch (e) {}
		};

		/* 排序落盘后（DOM 已被 luci 直接搬动、不会重绘）重新置顶并重编号。 */
		const watchRoutingNodeOrder = function(el) {
			try {
				const tbody = el.querySelector('tbody.cbi-section-tbody') || el.querySelector('tbody');

				if (!tbody || typeof MutationObserver === 'undefined')
					return;

				let queued = false;

				const observer = new MutationObserver(function() {
					/* 表格被替换后自毁，避免观察器一直持有已废弃的节点 */
					if (!tbody.isConnected) {
						observer.disconnect();
						return;
					}

					if (queued)
						return;

					queued = true;

					setTimeout(function() {
						queued = false;
						pinFinalRoutingNode(el);
					}, 0);
				});

				observer.observe(tbody, { childList: true });
			}
			catch (e) {}
		};

		ss.renderContents = function() {
			const el = routingNodeOrigRenderContents.apply(this, arguments);

			pinFinalRoutingNode(el);
			watchRoutingNodeOrder(el);
			refreshRoutingNodeStatus(el);

			/* 5 秒轮询一次。原先只在 render 时拉一次，任何一次失败都会让整列
			   永久空白；轮询让 sing-box 重启完成后自动补上。
			   hp.pollAdd 按 key 替换旧回调，反复重渲染不会叠加请求；表格被替换
			   后（离开该页或重新渲染）旧回调自行注销。 */
			hp.pollAdd('routing-node-status', function() {
				if (!el.isConnected) {
					/* 延后一拍再注销：LuCI 的 poll 是遍历数组逐个调用回调，
					   在当前回调里 splice 掉自己会让「后面那个回调」这一轮被跳过。 */
					setTimeout(function() {
						hp.pollRemove('routing-node-status');
					}, 0);

					return;
				}

				/* 标签页在后台时不拉：/proxies 在节点多时有几百 KB，
				   没人看的时候没必要每 5 秒下一次。 */
				if (document.hidden)
					return;

				refreshRoutingNodeStatus(el);
			}, 5);

			return el;
		};

		so = ss.option(form.Value, 'label', _('Label'),
			_('Will be used as the sing-box outbound tag and display name. Chinese is supported. It must be unique and must not contain slashes, "?", "#" or "%".'));
		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
		so.validate = function(section_id, value) {
			let r = hp.validateUniqueValue(data[0], 'routing_node', 'label', section_id, value);
			if (r !== true)
				return r;

			return hp.validateOutboundTag(section_id, value);
		};
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		/* 这个下拉框既选策略组的工作模式（自动测速 / 手动切换），
		   也能直接固定成某一个节点，所以标签用「工作模式」而不是「节点」。 */
		so = ss.option(form.ListValue, 'node', _('Working mode'),
			_('Auto select picks the lowest-latency node; manual select can be switched at runtime; picking a single node uses only that node.'));
		so.value('urltest', _('Auto select'));
		so.value('selector', _('Manual select'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.default = 'selector';
		so.rmempty = false;
		/* 类型在表格末尾以徽章列展示（建议3），行内不再重复显示英文术语 */
		so.modalonly = true;
		so.formvalue = function(section_id) {
			let widget = this.getUIElement(section_id),
			    cbid = this.cbid(section_id),
			    overlay = document.getElementById('modal_overlay'),
			    input = null;

			if (overlay)
				for (let el of overlay.querySelectorAll('input, select'))
					if (el.id === cbid || el.name === cbid) {
						input = el;
						break;
					}

			return widget?.getValue() ||
				input?.value ||
				uci.get(data[0], section_id, 'node') ||
				this.default ||
				'selector';
		}
		so.validate = function(section_id, value) {
			value = value || this.formvalue(section_id);

			let result = hp.validateUniqueValue(data[0], 'routing_node', 'node', section_id, value);
			if (result !== true)
				return result;

			if (section_id && (value === 'urltest' || value === 'selector')) {
				let groups = normalizeFormList(this.section.formvalue(section_id, 'subscription_groups')),
				    subscription_nodes = normalizeFormList(this.section.formvalue(section_id, 'subscription_nodes')),
				    selected = normalizeFormList(this.section.formvalue(section_id, 'selected_nodes')),
				    policy_nodes = normalizeFormList(this.section.formvalue(section_id, 'policy_nodes'));

				if (!groups.length && !subscription_nodes.length && !selected.length && !policy_nodes.length)
					return _('Expecting: %s').format(_('non-empty value'));
			}

			return true;
		}

		so = ss.option(form.ListValue, 'domain_resolver', _('Domain resolver'),
			_('For resolving domain name in the server address.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Default'));
			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.depends('node', /^((?!(urltest|selector)$).)+$/);
		so.modalonly = true;

		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
			_('The domain strategy for resolving the domain name in the address.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);
		so.depends('node', /^((?!(urltest|selector)$).)+$/);
		so.modalonly = true;

		so = ss.option(widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('The network interface to bind to.'));
		so.multiple = false;
		so.noaliases = true;
		so.depends({'outbound': '', 'node': /^((?!(urltest|selector)$).)+$/});
		so.modalonly = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('The tag of the upstream outbound.<br/>Other dial fields will be ignored when enabled.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res['.name'] !== section_id && res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let node = this.section.formvalue(section_id, 'node');

				let conflict = false;
				uci.sections(data[0], 'routing_node', (res) => {
					if (res['.name'] !== section_id) {
						if (res.outbound === section_id && res['.name'] == value)
							conflict = true;
						else if (res.node === 'urltest' && normalizeFormList(res.urltest_nodes).includes(node) && res['.name'] == value)
							conflict = true;
						else if (res.node === 'urltest' && normalizeFormList(res.subscription_nodes).includes(node) && res['.name'] == value)
							conflict = true;
						else if (res.node === 'urltest' && normalizeFormList(res.selected_nodes).includes(node) && res['.name'] == value)
							conflict = true;
						else if (res.node === 'selector' && normalizeFormList(res.selected_nodes).includes(node) && res['.name'] == value)
							conflict = true;
						else if (res.node === 'selector' && normalizeFormList(res.subscription_nodes).includes(node) && res['.name'] == value)
							conflict = true;
					}
				});
				if (conflict)
					return _('Recursive outbound detected!');
			}

			return true;
		}
		so.depends('node', /^((?!(urltest|selector)$).)+$/);
		so.editable = true;
		/* 出站节点只在单节点包装时生效（点击下拉菜单手动选），
		   策略组表格里显示这列对多数人含义不明，改为仅在弹窗中展示。 */
		so.modalonly = true;

		so = ss.option(hp.CBIMultiValue, 'subscription_groups', _('Subscription airports'));
		for (let hash in subscription_groups)
			so.value(hash, subscription_groups[hash]);
		so.depends('node', 'urltest');
		so.depends('node', 'selector');
		so.rmempty = true;
		so.modalonly = true;

		so = ss.option(hp.CBIMultiValue, 'subscription_nodes', _('Subscription nodes'),
			_('List of nodes from subscriptions.'));
		uci.sections(data[0], 'node', (res) => {
			if (res.grouphash)
				so.value(res['.name'], proxy_nodes[res['.name']]);
		});
		so.depends('node', 'urltest');
		so.depends('node', 'selector');
		so.rmempty = true;
		so.modalonly = true;

		so = ss.option(hp.CBIMultiValue, 'selected_nodes', _('Custom nodes'));
		uci.sections(data[0], 'node', (res) => {
			if (!res.grouphash)
				so.value(res['.name'], proxy_nodes[res['.name']]);
		});
		so.depends('node', 'urltest');
		so.depends('node', 'selector');
		so.rmempty = true;
		so.modalonly = true;

		so = ss.option(form.ListValue, 'filter_nodes', _('Filter nodes'),
			_('Drop/keep specific nodes from outbounds.'));
		so.value('disabled', _('Disable'));
		so.value('blacklist', _('Blacklist mode'));
		so.value('whitelist', _('Whitelist mode'));
		so.default = 'disabled';
		so.rmempty = false;
		so.depends('node', 'urltest');
		so.depends('node', 'selector');
		so.modalonly = true;

		so = ss.option(form.DynamicList, 'filter_keywords', _('Filter keywords'),
			_('Drop/keep nodes that contain the specific keywords. <a target="_blank" href="https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_Expressions">Regex</a> is supported.'));
		so.depends({ 'node': /^(urltest|selector)$/, 'filter_nodes': /^(blacklist|whitelist)$/ });
		so.modalonly = true;

		so = ss.option(hp.CBIMultiValue, 'policy_nodes', _('Policy nodes'),
			_('List of policy groups. The ticking order decides the node order in the panel, and the first ticked node is used by default.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			uci.sections(data[0], 'routing_node', (res) => {
				if (res['.name'] !== section_id && res.enabled === '1' && ['urltest', 'selector'].includes(res.node))
					this.value(res['.name'], res.label || res['.name']);
			});

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (normalizeFormList(value).includes(section_id))
				return _('Recursive outbound detected!');

			return true;
		}
		so.depends('node', 'selector');
		so.rmempty = true;
		so.modalonly = true;

		so = ss.option(form.ListValue, 'selector_default', _('Default node'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			let groups = normalizeFormList(this.section.formvalue(section_id, 'subscription_groups')),
			    subscription_nodes = normalizeFormList(this.section.formvalue(section_id, 'subscription_nodes')),
			    selected = normalizeFormList(this.section.formvalue(section_id, 'selected_nodes')),
			    policy_nodes = normalizeFormList(this.section.formvalue(section_id, 'policy_nodes')),
			    filter_mode = this.section.formvalue(section_id, 'filter_nodes'),
			    filter_keywords = normalizeFormList(this.section.formvalue(section_id, 'filter_keywords'));

			this.value('', _('Default'));
			for (let node of collectSelectedRoutingNodes(groups, subscription_nodes, selected, policy_nodes, section_id, filter_mode, filter_keywords))
				this.value(node, proxy_nodes[node] || routing_groups[node]);

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (!value)
				return true;

			let groups = normalizeFormList(this.section.formvalue(section_id, 'subscription_groups')),
			    subscription_nodes = normalizeFormList(this.section.formvalue(section_id, 'subscription_nodes')),
			    selected = normalizeFormList(this.section.formvalue(section_id, 'selected_nodes')),
			    policy_nodes = normalizeFormList(this.section.formvalue(section_id, 'policy_nodes')),
			    filter_mode = this.section.formvalue(section_id, 'filter_nodes'),
			    filter_keywords = normalizeFormList(this.section.formvalue(section_id, 'filter_keywords'));

			if (!collectSelectedRoutingNodes(groups, subscription_nodes, selected, policy_nodes, section_id, filter_mode, filter_keywords).includes(value))
				return _('Invalid node');

			return true;
		}
		so.depends('node', 'selector');
		so.modalonly = true;

		so = ss.option(form.Flag, 'selector_interrupt_exist_connections', _('Interrupt existing connections'),
			_('Interrupt existing connections when the selected outbound has changed.'));
		so.depends('node', 'selector');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_url', _('Test URL'),
			_('The URL to test.'));
		so.placeholder = 'https://www.gstatic.com/generate_204';
		so.default = 'https://www.gstatic.com/generate_204';
		so.validate = function(section_id, value) {
			if (section_id && value) {
				try {
					let url = new URL(value);
					if (!url.hostname)
						return _('Expecting: %s').format(_('valid URL'));
				}
				catch(e) {
					return _('Expecting: %s').format(_('valid URL'));
				}
			}

			return true;
		}
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '180';
		so.default = '180';
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let idle_timeout = this.section.formvalue(section_id, 'idle_timeout') || '1800';
				if (parseInt(value) > parseInt(idle_timeout))
					return _('Test interval must be less or equal than idle timeout.');
			}

			return true;
		}
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '50';
		so.default = '50';
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Value, 'urltest_idle_timeout', _('Idle timeout'),
			_('The idle timeout in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '1800';
		so.default = '1800';
		so.depends('node', 'urltest');
		so.modalonly = true;

		so = ss.option(form.Flag, 'urltest_interrupt_exist_connections', _('Interrupt existing connections'),
			_('Interrupt existing connections when the selected outbound has changed.'));
		so.depends('node', 'urltest');
		so.modalonly = true;
		/* Routing nodes end */

		/* Routing rules start */
		s.tab('routing_rule', _('Routing Rules'));
		o = s.taboption('routing_rule', form.SectionValue, '_routing_rule', form.GridSection, 'routing_rule');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Routing rule'), _('Add a routing rule'), data[0]);
		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
		/* 去掉 luci-base 额外插入的那列重复名称，见 hp.dedupeNameColumn */
		hp.dedupeNameColumn(ss);
		/* 「启用」列移到名称列左侧 */
		hp.moveEnableColumn(ss);
		/* 建议4：名称列左侧显示序号列（列头「序号」）；添加框上方说明匹配顺序 */
		hp.prependIndexColumn(ss, _('Sequence'));
		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss, null,
			_('Used as the displayed routing rule name. Chinese is supported. It must be unique.'),
			_('Rules are matched by sequence number from top to bottom; matching stops at the first hit.'));
		/* 建议6：表格末尾以 chip 标签直观显示本条规则引用的规则集 */
		hp.appendTableColumns(ss, [{
			header: _('Rule set'),
			renderCell: function(sid) {
				let values = normalizeFormList(uci.get(data[0], sid, 'rule_set'));

				if (!values.length)
					return '—';

				let labels = {};

				uci.sections(data[0], 'ruleset', (res) => {
					labels[res['.name']] = res.tag || res.label || res['.name'];
				});

				return E('span', { 'class': 'hp-chips' },
					values.map((v) => E('span', { 'class': 'hp-chip' }, labels[v] || v)));
			}
		}]);

		ss.tab('field_other', _('Other fields'));
		ss.tab('field_host', _('Host/IP fields'));
		ss.tab('field_port', _('Port fields'));
		ss.tab('fields_process', _('Process fields'));

		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'routing_rule', 'label');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
			_('In default mode, rule fields are matched by category. Any condition in the same category can match, while different categories must match at the same time. Rule sets are merged into the rule for matching and are not treated as separate sub-rules.'));
		so.value('default', _('Default'));
		so.default = 'default';
		so.rmempty = false;
		so.readonly = true;

		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'),
			_('4 or 6. Not limited if empty.'));
		so.value('4', _('IPv4'));
		so.value('6', _('IPv6'));
		so.value('', _('Both'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
		so.value('bittorrent', _('BitTorrent'));
		so.value('dns', _('DNS'));
		so.value('dtls', _('DTLS'));
		so.value('http', _('HTTP'));
		so.value('quic', _('QUIC'));
		so.value('rdp', _('RDP'));
		so.value('ssh', _('SSH'));
		so.value('stun', _('STUN'));
		so.value('tls', _('TLS'));

		so = ss.taboption('field_other', form.Value, 'client', _('Client'),
			_('Sniffed client type (QUIC client type or SSH client name).'));
		so.value('chromium', _('Chromium / Cronet'));
		so.value('firefox', _('Firefox / uquic firefox'));
		so.value('quic-go', _('quic-go / uquic chrome'));
		so.value('safari', _('Safari / Apple Network API'));
		so.depends('protocol', 'quic');
		so.depends('protocol', 'ssh');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
		so.value('tcp', _('TCP'));
		so.value('udp', _('UDP'));
		so.value('', _('Both'));

		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
			_('Match user name.'));
		so.modalonly = true;

		so = ss.taboption('field_other', hp.CBIMultiValue, 'rule_set', _('Rule set'),
			_('Match rule set.'));
		uci.sections(data[0], 'ruleset', (res) => {
			if (res.enabled === '1')
				so.value(res['.name'], res.tag || res.label);
		});
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
			_('Make IP CIDR in rule set used to match the source IP.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
			_('Invert match result.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
		so.value('route', _('Route'));
		so.value('route-options', _('Route options'));
		so.value('reject', _('Reject'));
		so.value('resolve', _('Resolve'));
		so.default = 'route';
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'outbound', _('Outbound'),
			_('Tag of the target outbound.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.rmempty = false;
		so.depends('action', 'route');
		so.editable = true;

		so = ss.taboption('field_other', form.Value, 'override_address', _('Override address'),
			_('Override the connection destination address.'));
		so.datatype = 'ipaddr';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'override_port', _('Override port'),
			_('Override the connection destination port.'));
		so.datatype = 'port';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'udp_disable_domain_unmapping', _('Disable UDP domain unmapping'),
			_('If enabled, for UDP proxy requests addressed to a domain, the original packet address will be sent in the response instead of the mapped domain.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'udp_connect', _('connect UDP connections'),
			_('If enabled, attempts to connect UDP connection to the destination instead of listen.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'udp_timeout', _('UDP timeout'),
			_('Timeout for UDP connections.<br/>Setting a larger value than the UDP timeout in inbounds will have no effect.'));
		so.datatype = 'uinteger';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'tls_record_fragment', _('TLS record fragment'),
			_('Fragment TLS handshake into multiple TLS records.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'tls_fragment', _('TLS fragment'),
			_('Fragment TLS handshakes. Due to poor performance, try <code>%s</code> first.').format(
				_('TLS record fragment')));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'tls_fragment_fallback_delay', _('Fragment fallback delay'),
			_('The fallback value in milliseconds used when TLS segmentation cannot automatically determine the wait time.'));
		so.datatype = 'uinteger';
		so.placeholder = '500';
		so.depends('tls_fragment', '1');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'resolve_server', _('DNS server'),
			_('Specifies DNS server tag to use instead of selecting through DNS routing.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Default'));
			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
		so.value('default', _('Reply with TCP RST / ICMP port unreachable'));
		so.value('drop', _('Drop packets'));
		so.depends('action', 'reject');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop packets'),
			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
			_('Method'), _('Drop packets')));
		so.depends('reject_method', 'default');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'resolve_strategy', _('Resolve strategy'),
			_('Domain strategy for resolving the domain names.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'resolve_disable_cache', _('Disable DNS memory cache'),
			_('Disable DNS memory cache in this query.'));
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'resolve_rewrite_ttl', _('Rewrite TTL'),
			_('Rewrite TTL in DNS responses.'));
		so.datatype = 'uinteger';
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'resolve_client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.depends('action', 'resolve');
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domain name'),
			_('Match full domain.'));
		so.datatype = 'hostname';
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
			_('Match domain suffix.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
			_('Match domain using keyword.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
			_('Match domain using regular expression.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
			_('Match source IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
			_('Match IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'));
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
			_('Match source port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
			_('Match source port range. Format as START:/:END/START:END.'));
		so.validate = hp.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
			_('Match port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
			_('Match port range. Format as START:/:END/START:END.'));
		so.validate = hp.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
			_('Match process name.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
			_('Match process path.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
			_('Match process path using regular expression.'));
		so.modalonly = true;
		/* Routing rules end */

		/* DNS settings start */
		s.tab('dns', _('DNS Settings'));
		o = s.taboption('dns', form.SectionValue, '_dns', form.NamedSection, 'dns', 'homeproxy');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		so = ss.option(form.ListValue, 'default_strategy', _('Default DNS strategy'),
			_('The DNS strategy for resolving the domain name in the address.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);

		so = ss.option(form.ListValue, 'default_server', _('Default DNS server'),
			_('Daily domain name resolution for clients. Choose an overseas DNS if DNS leak protection is required.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'default-dns';
		so.rmempty = false;

		so = ss.option(form.Flag, 'disable_cache', _('Disable DNS memory cache'));

		so = ss.option(form.Flag, 'disable_cache_expire', _('Disable DNS memory cache expiration'));
		so.depends('disable_cache', '0');

		so = ss.option(form.Value, 'client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';

		/* DNS settings end */

		/* DNS servers start */
		s.tab('dns_server', _('DNS Servers'));
		o = s.taboption('dns_server', form.SectionValue, '_dns_server', form.GridSection, 'dns_server');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('DNS server'), _('Add a DNS server'), data[0]);
		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
		/* 去掉 luci-base 额外插入的那列重复名称，见 hp.dedupeNameColumn */
		hp.dedupeNameColumn(ss);
		/* 「启用」列移到名称列左侧 */
		hp.moveEnableColumn(ss);
		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss, null,
			_('Used as the displayed DNS server name. Chinese is supported. It must be unique.'));

		so = ss.option(form.Value, 'label', _('Label'));
		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'dns_server', 'label');
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'type', _('Type'));
		so.value('udp', _('UDP'));
		so.value('tcp', _('TCP'));
		so.value('tls', _('TLS'));
		so.value('https', _('HTTPS'));
		so.value('h3', _('HTTP/3'));
		so.value('quic', _('QUIC'));
		so.default = 'udp';
		so.rmempty = false;

		so = ss.option(form.Value, 'server', _('Address'),
			_('Examples:<br/>UDP: udp://223.5.5.5<br/>TCP: tcp://223.5.5.5<br/>TLS: tls://dns.alidns.com<br/>HTTPS: https://dns.alidns.com/dns-query<br/>HTTP/3: h3://dns.alidns.com/dns-query<br/>QUIC: quic://dns.alidns.com<br/>Note: for TLS/QUIC, if an IP address is used, the real domain (e.g. dns.alidns.com) must be set in "TLS SNI" below, otherwise certificate verification fails.'));
		so.placeholder = '';
		so.validate = function(section_id, value) {
			let type = this.section.formvalue(section_id, 'type') ||
				uci.get(data[0], section_id, 'type') ||
				'udp';

			if (!validateDnsServerAddress(type, value))
				return _('Expecting: %s').format(_('valid DNS server address'));

			return true;
		}
		so.renderWidget = function(section_id, option_index, cfgvalue) {
			let node = form.Value.prototype.renderWidget.apply(this, arguments),
			    input = node.querySelector('input'),
			    update = () => {
				let type = this.section.formvalue(section_id, 'type') ||
					uci.get(data[0], section_id, 'type') ||
					'udp';
				if (input)
					input.placeholder = getDnsServerAddressPlaceholder(type);
			};

			update();
			requestAnimationFrame(() => {
				let type_input = document.getElementById(this.cbid(section_id).replace(/\.server$/, '.type'));
				if (type_input) {
					type_input.addEventListener('change', update);
					update();
				}
			});

			return node;
		}
		so.rmempty = false;

		so = ss.option(form.Value, 'server_port', _('Port'),
			_('Leave empty to use the default port.'));
		so.placeholder = '53';
		so.datatype = 'port';
		so.renderWidget = function(section_id, option_index, cfgvalue) {
			let node = form.Value.prototype.renderWidget.apply(this, arguments),
			    input = node.querySelector('input'),
			    update = () => {
				let type = this.section.formvalue(section_id, 'type') ||
					uci.get(data[0], section_id, 'type') ||
					'udp';
				if (input)
					input.placeholder = getDnsServerDefaultPort(type);
			};

			update();
			requestAnimationFrame(() => {
				let type_input = document.getElementById(this.cbid(section_id).replace(/\.server_port$/, '.type'));
				if (type_input) {
					type_input.addEventListener('change', update);
					update();
				}
			});

			return node;
		}
		so.depends('type', 'udp');
		so.depends('type', 'tcp');
		so.depends('type', 'tls');
		so.depends('type', 'quic');

		so = ss.option(form.DynamicList, 'headers', _('Headers'),
			_('Additional headers to be sent to the DNS server.'));
		so.depends('type', 'https');
		so.depends('type', 'h3');
		so.modalonly = true;

		so = ss.option(form.Value, 'tls_sni', _('TLS SNI'),
			_('Used to verify the hostname on the returned certificates.'));
		so.depends('type', 'tls');
		so.depends('type', 'https');
		so.depends('type', 'h3');
		so.depends('type', 'quic');
		so.modalonly = true;

		so = ss.option(form.ListValue, 'address_resolver', _('Address resolver'),
			_('Used to resolve DNS server addresses in domain form. IP addresses do not require it.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('None'));
			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res['.name'] !== section_id && res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.validate = function(section_id, value) {
			if (section_id && value) {
				let conflict = false;
				uci.sections(data[0], 'dns_server', (res) => {
					if (res['.name'] !== section_id)
						if (res.address_resolver === section_id && res['.name'] == value)
							conflict = true;
				});
				if (conflict)
					return _('Recursive resolver detected!');
			}

			return true;
		}
		so.modalonly = true;

		so = ss.option(form.ListValue, 'address_strategy', _('Address strategy'),
			_('The domain strategy for resolving the domain name in the address.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);
		so.depends({'address_resolver': '', '!reverse': true});
		so.modalonly = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('Tag of an outbound for connecting to the dns server.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'direct-out';
		so.rmempty = false;
		so.editable = true;

		/* 建议 11：DNS 服务器行内延迟测试。单列「延迟」内联显示数值与
		   「测试」按钮：HTTPS(DoH) 测 curl TLS 握手耗时(time_appconnect)，
		   UDP/TCP/TLS(DoT)/HTTP3(DoH3)/QUIC 测 ping 往返。点击按钮异步调用
		   rpcd dns_server_test；数值按 <100ms 绿 / <300ms 橙 / >=300ms 红分级。 */
		hp.appendTableColumns(ss, [
			{
				header: _('Latency'),
				renderCell: function(sid) {
					const latSpan = E('span', { 'class': 'hp-dns-lat', 'data-sid': sid }, [ '—' ]);
					const btn = E('button', {
						'class': 'btn cbi-button cbi-button-action hp-dns-test-btn',
						'type': 'button'
					}, _('Test'));

					btn.addEventListener('click', (ev) => {
						/* 阻止冒泡：GridSection 数据行点击会打开编辑弹窗 */
						ev.preventDefault();
						ev.stopPropagation();

						btn.disabled = true;
						btn.textContent = _('Testing...');
						latSpan.textContent = '';
						latSpan.appendChild(E('span', { 'class': 'hp-dns-loading' }, [ '…' ]));

						/* rpc.declare 声明的是 params:['section']，即位置参数：
						   必须直接传 section id，传对象会让 rpcd 收到
						   args.section = { section: ... }，被 /^[A-Za-z0-9_]+$/
						   判为 illegal section，测试永远失败。 */
						/* 不用 L.resolveDefault 包一层：它会把 ubus 的 reject 吞成 {}，
						   那样「Method not found」这类关键信息就丢了，界面只剩一句
						   通用的「无响应」。下面的 .catch 已经统一兜住。 */
						callDnsServerTest(sid)
							.then((ret) => {
								btn.disabled = false;
								btn.textContent = _('Test');
								latSpan.textContent = '';

								if (ret && ret.result && ret.latency_ms > 0) {
									const ms = ret.latency_ms;
									const cls = (ms < 100) ? 'hp-lat-good'
									          : (ms < 300) ? 'hp-lat-mid'
									          : 'hp-lat-bad';

									/* 各协议口径不同（TLS 握手 / TCP 建连 / ICMP 往返），
									   用 title 标出来，避免把 ICMP 值当成 DoH 握手耗时比较。 */
									const kind = (ret.kind === 'ping') ? 'ICMP'
									           : (ret.kind === 'tcp') ? 'TCP' : 'TLS';

									const cell = E('span', { 'class': cls }, String(ms) + 'ms');
									cell.title = ret.port ? (kind + ' :' + ret.port) : kind;
									latSpan.appendChild(cell);
							} else {
								/* 有 rpcd 返回的 error 就直接显示；连响应都没有（方法未注册，
								   典型原因是装完新包没重启 rpcd）时给一句可操作的提示。 */
								const msg = (ret && ret.error)
									? String(ret.error)
									: _('No response from rpcd. Restart rpcd (or the router) and try again.');

								const err = E('span', { 'class': 'hp-dns-err' }, _('Failed'));
								err.title = msg;
								latSpan.appendChild(err);
								latSpan.appendChild(hp.dnsFailDetail(msg));
							}
							})
							.catch((e) => {
								btn.disabled = false;
								btn.textContent = _('Test');
								latSpan.textContent = '';

								/* ubus 层面的失败（Method not found / Object not found /
								   Permission denied）走这里。把原始 message 一并显示，
								   否则界面上只有「失败」，看不出是 rpcd 还在跑旧方法表。 */
								const fallback = _('No response from rpcd. Restart rpcd (or the router) and try again.');
								const msg = (e && e.message) ? String(e.message) : fallback;

								const err = E('span', { 'class': 'hp-dns-err' }, _('Failed'));
								err.title = msg;
								latSpan.appendChild(err);
								latSpan.appendChild(hp.dnsFailDetail(msg));
							});
					});

					return E('span', { 'class': 'hp-dns-lat-cell' }, [ latSpan, btn ]);
				}
			}
		]);

		/* DNS servers end */

		/* DNS rules start */
		s.tab('dns_rule', _('DNS Rules'));

		/* 把 DNS 服务器 id 解析成「名称 + 出站」。outbound 为 null 表示直连
		   （WAN 下发 DNS / 系统 DNS / 服务器自身出站为 direct-out）。 */
		const resolveDnsTarget = function(server_id) {
			const id = server_id || 'default-dns';

			if (id === 'default-dns')
				return { label: _('Default DNS (issued by WAN)'), outbound: null };
			else if (id === 'system-dns')
				return { label: _('System DNS'), outbound: null };

			let label = id;

			uci.sections(data[0], 'dns_server', (res) => {
				if (res['.name'] === id)
					label = res.label || id;
			});

			const outbound_id = uci.get(data[0], id, 'outbound') || 'direct-out';

			if (outbound_id === 'direct-out' || outbound_id === '')
				return { label: label, outbound: null };

			let outbound = outbound_id;

			uci.sections(data[0], 'routing_node', (res) => {
				if (res['.name'] === outbound_id)
					outbound = res.label || outbound_id;
			});

			return { label: label, outbound: outbound };
		};

		/* 目标的文字形式：直连显示「名称（直连）」，走代理显示「名称（出站：X）」。 */
		const dnsTargetLabel = function(t) {
			return (t.outbound == null)
				? _('%s (direct)').format(t.label)
				: _('%s (via outbound: %s)').format(t.label, t.outbound);
		};

		/* 单条 DNS 规则的匹配条件摘要。每类最多列 3 项，超出用「…」省略；
		   一条规则没有任何匹配条件时即「所有查询」。
		   label_sep 是「类别」与「取值」之间的分隔符：列表里用「：」，
		   一句话模式传空格，避免和句首的冒号叠成双冒号。 */
		const dnsRuleCondition = function(cfg, label_sep) {
			const sep = (label_sep != null) ? label_sep : '：',
			      toList = (v) => (v == null ? [] : (Array.isArray(v) ? v : [ v ])),
			      parts = [],
			      add = (label, v) => {
				const vals = toList(v).filter((x) => x !== '' && x != null);

				if (!vals.length)
					return;

				parts.push(label + sep + vals.slice(0, 3).join('、') +
					(vals.length > 3 ? ' …' : ''));
			};

			add(_('Domain name'), cfg.domain);
			add(_('Domain suffix'), cfg.domain_suffix);
			add(_('Domain keyword'), cfg.domain_keyword);
			add(_('Domain regex'), cfg.domain_regex);

			const rulesets = toList(cfg.rule_set);

			if (rulesets.length) {
				const labels = {};

				uci.sections(data[0], 'ruleset', (res) => {
					labels[res['.name']] = res.tag || res.label || res['.name'];
				});

				add(_('Rule set'), rulesets.map((r) => labels[r] || r));
			}

			if (!parts.length)
				return _('All queries');

			return (cfg.invert === '1' ? _('Invert') + '：' : '') + parts.join('；');
		};

		/* 解析流程说明：动态汇总当前每条 DNS 规则「匹配什么 → 走直连还是走代理」。
		   只有一条规则时压成一句话（新手最容易读），多条才用列表；
		   只有默认 DNS 真的直连出去时才追加防泄漏提示。
		   通过 renderSectionAdd 的 topHint 显示在「添加」输入框上方，见下方绑定。 */
		const renderDnsBanner = function() {
			const list = [];

			uci.sections(data[0], 'dns_rule', (cfg) => {
				if (cfg.enabled === '0')
					return;

				list.push(cfg);
			});

			const def = resolveDnsTarget(uci.get(data[0], 'dns', 'default_server') || 'default-dns'),
			      leakTip = _('Leak warning: queries that match no rule are resolved by the default DNS server. If it goes out directly, your local network or ISP can see the domains you visit (DNS leak). Add rules for sensitive domains, or set the default DNS server to one that goes through a proxy.');

			/* 规则命中后去哪：route 落到具体服务器，其余动作只有语义标签。 */
			const dnsActionLabel = function(server_id, action) {
				if (action !== 'route')
					return (action === 'reject') ? _('Reject')
						: (action === 'predefined') ? _('Predefined')
						: _('Route options');

				return dnsTargetLabel(resolveDnsTarget(server_id));
			};

			/* 多条规则的列表：目标格用加粗 + 直连警示色，便于扫读 */
			const targetNode = function(server_id, action) {
				if (action !== 'route')
					return E('span', { 'class': 'hp-dns-flow-target' }, dnsActionLabel(server_id, action));

				const t = resolveDnsTarget(server_id),
				      el = E('span', { 'class': 'hp-dns-flow-target' }, dnsTargetLabel(t));

				/* 直连解析等于把域名明文暴露给运营商/局域网，用警示色标出来。 */
				if (t.outbound == null)
					el.classList.add('hp-dns-flow-direct');

				return el;
			};

			/* 一条规则一个匹配条件都没有 = 命中所有查询；
			   此时「其余域名走默认服务器」并不成立，必须换措辞。 */
			const dnsRuleMatchesAll = function(cfg) {
				return [ 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'rule_set' ]
					.every((k) => {
						const v = cfg[k];
						return (v == null) || (Array.isArray(v) ? v.length === 0 : v === '');
					});
			};

			/* 只有一条规则：一句话说清「谁直连、谁走代理、其余去哪」。
			   整句是纯文本（不加粗、不染色），并用带 %s 的整句模板承载；
			   msgid 不能带尾部空格——那种串在翻译查找时很容易对不上，
			   一旦对不上就整句回落成英文。 */
			if (list.length === 1) {
				const cfg = list[0],
				      action = cfg.action || 'route',
				      catch_all = dnsRuleMatchesAll(cfg),
				      target = dnsActionLabel(cfg.server, action);

				let text;

				if (catch_all)
					text = _('Current DNS resolution flow: all queries → %s.').format(target);
				else
					text = _('Current DNS resolution flow: %s → %s; all other domains → default server %s.')
						.format(dnsRuleCondition(cfg, ' '), target, dnsTargetLabel(def));

				const box = [
					/* 表格已有「序号」列，这里说明匹配顺序（与路由规则页同一句文案） */
					E('div', { 'class': 'hp-dns-flow-note' },
						_('Rules are matched by sequence number from top to bottom; matching stops at the first hit.')),
					E('div', { 'class': 'hp-dns-flow-compact' }, [ text ])
				];

				/* 所有查询都被这条规则拦住时，默认 DNS 根本用不到，不必提示泄漏 */
				if (!catch_all && def.outbound == null)
					box.push(E('div', { 'class': 'hp-dns-flow-tip' }, leakTip));

				return E('div', { 'class': 'hp-dns-banner hp-dns-banner-compact' }, box);
			}

			const rows = list.map((cfg, i) => E('div', { 'class': 'hp-dns-flow-row' }, [
				E('span', { 'class': 'hp-dns-flow-idx' }, (i + 1) + '.'),
				E('span', { 'class': 'hp-dns-flow-cond' }, dnsRuleCondition(cfg)),
				E('span', { 'class': 'hp-dns-flow-arrow' }, '→'),
				targetNode(cfg.server, cfg.action || 'route')
			]));

			if (rows.length === 0)
				rows.push(E('div', { 'class': 'hp-dns-flow-row hp-dns-flow-empty' },
					_('No DNS rule is configured; all queries go to the default DNS server.')));

			return E('div', { 'class': 'hp-dns-banner' }, [
				E('div', { 'class': 'hp-dns-flow-title' },
					_('Client DNS queries match DNS rules from top to bottom; matching stops at the first hit, and unmatched queries go to the default DNS server.')),
				E('div', { 'class': 'hp-dns-flow-list' }, rows),
				E('div', { 'class': 'hp-dns-flow-default' },
					_('Default DNS server: %s (via outbound: %s)').format(def.label, def.outbound || _('Direct'))),
				E('div', { 'class': 'hp-dns-flow-tip' }, leakTip)
			]);
		};

		o = s.taboption('dns_rule', form.SectionValue, '_dns_rule', form.GridSection, 'dns_rule');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('DNS rule'), _('Add a DNS rule'), data[0]);
		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
		/* 去掉 luci-base 额外插入的那列重复名称，见 hp.dedupeNameColumn */
		hp.dedupeNameColumn(ss);
		/* 「启用」列移到名称列左侧 */
		hp.moveEnableColumn(ss);
		/* 「启用」左侧显示序号列（列头「序号」），与路由规则页一致 */
		hp.prependIndexColumn(ss, _('Sequence'));
		/* 第 4 个预绑定实参是 topHint：传函数而非节点，让每次重绘都重新读取
		   uci 数据，汇总内容随规则增删/启停实时变化，且显示在「添加」输入框上方。 */
		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss, null,
			_('Used as the displayed DNS rule name. Chinese is supported. It must be unique.'),
			renderDnsBanner);

		ss.tab('field_other', _('Other fields'));
		ss.tab('field_host', _('Host/IP fields'));
		ss.tab('field_port', _('Port fields'));
		ss.tab('fields_process', _('Process fields'));

		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'dns_rule', 'label');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
			_('In default mode, rule fields are matched by category. Any condition in the same category can match, while different categories must match at the same time. Rule sets are merged into the rule for matching and are not treated as separate sub-rules.'));
		so.value('default', _('Default'));
		so.default = 'default';
		so.rmempty = false;
		so.readonly = true;
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'));
		so.value('4', _('IPv4'));
		so.value('6', _('IPv6'));
		so.value('', _('Both'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'query_type', _('Query type'),
			_('Match query type.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
		so.value('tcp', _('TCP'));
		so.value('udp', _('UDP'));
		so.value('', _('Both'));

		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
		so.value('bittorrent', _('BitTorrent'));
		so.value('dtls', _('DTLS'));
		so.value('http', _('HTTP'));
		so.value('quic', _('QUIC'));
		so.value('rdp', _('RDP'));
		so.value('ssh', _('SSH'));
		so.value('stun', _('STUN'));
		so.value('tls', _('TLS'));

		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
			_('Match user name.'));
		so.modalonly = true;

		so = ss.taboption('field_other', hp.CBIMultiValue, 'rule_set', _('Rule set'),
			_('Match rule set.'));
		uci.sections(data[0], 'ruleset', (res) => {
			if (res.enabled === '1')
				so.value(res['.name'], res.tag || res.label);
		});
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
			_('Make IP CIDR in rule sets match the source IP.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_accept_empty', _('Accept empty query response'),
			_('Make IP CIDR in rule-sets accept empty query response.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
			_('Invert match result.'));
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
		so.value('route', _('Route'));
		so.value('route-options', _('Route options'));
		so.value('reject', _('Reject'));
		so.value('predefined', _('Predefined'));
		so.default = 'route';
		so.rmempty = false;
		so.editable = true;

		so = ss.taboption('field_other', form.ListValue, 'server', _('Server'),
			_('Tag of the target dns server.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('default-dns', _('Default DNS (issued by WAN)'));
			this.value('system-dns', _('System DNS'));
			uci.sections(data[0], 'dns_server', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.rmempty = false;
		so.editable = true;
		so.depends('action', 'route');

		so = ss.taboption('field_other', form.ListValue, 'domain_strategy', _('Domain strategy'),
			_('Set domain strategy for this query.'));
		for (let i in hp.dns_strategy)
			so.value(i, hp.dns_strategy[i]);
		so.depends('action', 'route');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'dns_disable_cache', _('Disable DNS memory cache'),
			_('Disable DNS memory cache and persistent cache in this query.'));
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'rewrite_ttl', _('Rewrite TTL'),
			_('Rewrite TTL in DNS responses.'));
		so.datatype = 'uinteger';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Value, 'client_subnet', _('EDNS Client subnet'),
			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.depends('action', 'route');
		so.depends('action', 'route-options');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
		so.value('default', _('Reply with REFUSED'));
		so.value('drop', _('Drop requests'));
		so.default = 'default';
		so.depends('action', 'reject');
		so.modalonly = true;

		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop requests'),
			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
				_('Method'), _('Drop requests')));
		so.depends('reject_method', 'default');
		so.modalonly = true;

		so = ss.taboption('field_other', form.ListValue, 'predefined_rcode', _('RCode'),
			_('The response code.'));
		so.value('NOERROR');
		so.value('FORMERR');
		so.value('SERVFAIL');
		so.value('NXDOMAIN');
		so.value('NOTIMP');
		so.value('REFUSED');
		so.default = 'NOERROR';
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_answer', _('Answer'),
			_('List of text DNS record to respond as answers.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_ns', _('NS'),
			_('List of text DNS record to respond as name servers.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_other', form.DynamicList, 'predefined_extra', _('Extra records'),
			_('List of text DNS record to respond as extra records.'));
		so.depends('action', 'predefined');
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domain name'),
			_('Match full domain.'));
		so.datatype = 'hostname';
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
			_('Match domain suffix.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
			_('Match domain using keyword.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
			_('Match domain using regular expression.'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
			_('Match source IP CIDR.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
		so.modalonly = true;

		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
			_('Match IP CIDR with query response. Current rule will be skipped if not match.'));
		so.datatype = 'or(cidr, ipaddr)';
		so.modalonly = true;

		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'),
			_('Match private IP with query response.'));
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
			_('Match source port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
			_('Match source port range. Format as START:/:END/START:END.'));
		so.validate = hp.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
			_('Match port.'));
		so.datatype = 'port';
		so.modalonly = true;

		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
			_('Match port range. Format as START:/:END/START:END.'));
		so.validate = hp.validatePortRange;
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
			_('Match process name.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
			_('Match process path.'));
		so.modalonly = true;

		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
			_('Match process path using regular expression.'));
		so.modalonly = true;

		/* 「规则集」列：把这条规则引用的规则集以标签形式列出来。
		   规则集字段只存在于「其他字段」弹窗里，表格里原本完全看不到；
		   有大量 geosite/geoip 规则时，靠它才能一眼分清哪条规则靠哪些规则集匹配。 */
		hp.appendTableColumns(ss, [{
			header: _('Rule set'),
			renderCell: function(sid) {
				const raw = uci.get(data[0], sid, 'rule_set'),
				      ids = Array.isArray(raw) ? raw : (raw ? [ raw ] : []);

				if (!ids.length)
					return E('span', { 'class': 'hp-chip-empty', 'title': _('No rule set is referenced.') }, [ '—' ]);

				const labels = {},
				      names = [];

				uci.sections(data[0], 'ruleset', (res) => {
					labels[res['.name']] = res.tag || res.label || res['.name'];
				});

				for (const id of ids) {
					const name = labels[id] || id;

					if (!names.includes(name))
						names.push(name);
				}

				return E('span', { 'class': 'hp-chip-list' },
					names.map((name) => E('span', {
						'class': 'hp-chip hp-chip-ruleset',
						'title': name
					}, [ name ])));
			}
		}]);

		/* DNS rules end */
		/* Custom routing settings end */

		/* Rule set settings start */
		s.tab('ruleset', _('Rule Set'));
		o = s.taboption('ruleset', form.SectionValue, '_ruleset', form.GridSection, 'ruleset');
		o.depends('routing_mode', 'custom');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Rule set'), _('Add a rule set'), data[0]);
		ss.sectiontitle = function(section_id) {
			return uci.get(data[0], section_id, 'tag') ||
				uci.get(data[0], section_id, 'label') || section_id;
		};
		/* 去掉 luci-base 额外插入的那列重复名称，见 hp.dedupeNameColumn */
		hp.dedupeNameColumn(ss);
		/* 「启用」列移到名称列左侧 */
		hp.moveEnableColumn(ss);
		ss.renderSectionAdd = L.bind(renderRuleSetAdd, this, ss);

		/* 建议7/9：本地文件状态列 + 立即更新按钮列。状态由 rpcd ruleset_status
		   异步填充（绿点=有效·时间·大小，红点=下载失败/文件无效，灰点=未下载）；
		   更新按钮调用 rpcd ruleset_update，内部执行
		   fetch_rulesets.sh --force --only <section>，单条预算 90 秒。 */
		const rulesetHumanSize = function(n) {
			n = +n || 0;
			if (n >= 1048576)
				return (n / 1048576).toFixed(1) + ' MB';
			else if (n >= 1024)
				return (n / 1024).toFixed(1) + ' KB';
			return n + ' B';
		};

		const refreshRulesetStatus = function(container) {
			L.resolveDefault(callRulesetStatus(), {}).then((status) => {
				for (const span of container.querySelectorAll('.hp-rs-status[data-sid]')) {
					const sid = span.getAttribute('data-sid'),
					      info = status ? status[sid] : null;

					span.textContent = '';

					if (!info) {
						span.appendChild(E('span', { 'class': 'hp-rs-dot hp-dot-none' }));
						continue;
					}

					if (info.valid) {
						const d = new Date((info.mtime || 0) * 1000);
						span.appendChild(E('span', { 'class': 'hp-rs-dot hp-dot-ok' }));
						span.appendChild(document.createTextNode(String.format(
							'%02d-%02d %02d:%02d', d.getMonth() + 1, d.getDate(),
							d.getHours(), d.getMinutes()) + ' · ' + rulesetHumanSize(info.size)));
					} else if (info.unavailable) {
						span.appendChild(E('span', { 'class': 'hp-rs-dot hp-dot-bad' }));
						span.appendChild(document.createTextNode(_('Download failed')));
					} else if (info.exists) {
						span.appendChild(E('span', { 'class': 'hp-rs-dot hp-dot-bad' }));
						span.appendChild(document.createTextNode(_('Invalid file')));
					} else {
						span.appendChild(E('span', { 'class': 'hp-rs-dot hp-dot-none' }));
						span.appendChild(document.createTextNode(
							((uci.get(data[0], sid, 'type') || 'remote') === 'local')
								? _('File missing') : _('Not downloaded')));
					}
				}
			});
		};

		let rulesetTableEl = null;

		hp.appendTableColumns(ss, [
			{
				header: _('Download time/size'),
				renderCell: function(sid) {
					return E('span', { 'class': 'hp-rs-status', 'data-sid': sid }, [ '…' ]);
				}
			},
			{
				header: '',
				renderCell: function(sid) {
					if ((uci.get(data[0], sid, 'type') || 'remote') !== 'remote')
						return '—';

					const btn = E('button', {
						'class': 'btn cbi-button hp-rs-update',
						'data-sid': sid
					}, [ _('Update now') ]);

					btn.addEventListener('click', function() {
						this.disabled = true;
						this.textContent = _('Updating...');

						L.resolveDefault(callRulesetUpdate(this.getAttribute('data-sid')), {})
							.then((ret) => {
								this.disabled = false;
								this.textContent = _('Update now');

								if (ret && ret.result === true)
									ui.addNotification(null, E('p', _('Rule set updated successfully.')), 'info');
								else
									ui.addNotification(null, E('p', _('Failed to update rule set: %s')
										.format((ret && ret.error) || _('unknown error'))), 'error');

								if (rulesetTableEl)
									refreshRulesetStatus(rulesetTableEl);
							})
							.catch(() => {
								this.disabled = false;
								this.textContent = _('Update now');
							});
					});

					return btn;
				}
			}
		]);

		const rulesetOrigRenderContents = ss.renderContents;

		ss.renderContents = function() {
			const el = rulesetOrigRenderContents.apply(this, arguments);
			rulesetTableEl = el;
			refreshRulesetStatus(el);
			return el;
		};

		so = ss.option(form.Value, 'tag', _('Label'),
			_('Used as the sing-box rule set tag and display name. Only letters, digits, ".", "_" and "-" are allowed. Chinese is not supported. It must be unique.'));
		so.rmempty = false;
		so.load = function(section_id) {
			if (!section_id)
				return '';

			return uci.get(data[0], section_id, 'tag') ||
				uci.get(data[0], section_id, 'label') || '';
		}
		so.write = function(section_id, value) {
			if (value != null) {
				uci.set(data[0], section_id, 'tag', value);
				uci.set(data[0], section_id, 'label', value);
			} else {
				uci.unset(data[0], section_id, 'tag');
				uci.unset(data[0], section_id, 'label');
			}
		}
		so.validate = function(section_id, value) {
			if (section_id) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));
				if (!value.match(/^[A-Za-z0-9_.-]+$/))
					return _('Expecting: %s').format(_('valid tag'));

				let duplicate = false;
				uci.sections(data[0], 'ruleset', (res) => {
					if (res['.name'] !== section_id)
						if ((res.tag || ('cfg-' + res['.name'] + '-rule')) === value)
							duplicate = true;
				});
				if (duplicate)
					return _('Expecting: %s').format(_('unique value'));
			}

			return true;
		}
		so.modalonly = true;

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'type', _('Type'));
		so.value('local', _('Local'));
		so.value('remote', _('Remote'));
		so.default = 'remote';
		so.rmempty = false;

		so = ss.option(form.ListValue, 'format', _('Format'));
		so.value('binary', _('Binary file'));
		so.value('source', _('Source file'));
		so.default = 'binary';
		so.rmempty = false;

		so = ss.option(form.Value, 'path', _('Path'),
			_('The default rule set directory is /etc/homeproxy/ruleset/.'));
		so.datatype = 'file';
		so.rmempty = false;
		so.depends('type', 'local');
		so.modalonly = true;

		so = ss.option(form.Value, 'url', _('Rule set URL'));
		so.validate = function(section_id, value) {
			if (section_id) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value);
					if (!url.hostname)
						return _('Expecting: %s').format(_('valid URL'));
				}
				catch(e) {
					return _('Expecting: %s').format(_('valid URL'));
				}
			}

			return true;
		}
		so.rmempty = false;
		so.depends('type', 'remote');
		so.modalonly = true;

		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
			_('Tag of the outbound to download rule set.'));
		so.load = function(section_id) {
			delete this.keylist;
			delete this.vallist;

			this.value('', _('Default outbound (fallback)'));
			this.value('direct-out', _('Direct'));
			uci.sections(data[0], 'routing_node', (res) => {
				if (res.enabled === '1')
					this.value(res['.name'], res.label);
			});

			return this.super('load', section_id);
		}
		so.default = 'direct-out';
		so.depends('type', 'remote');

		so = ss.option(form.Value, 'remote_path', _('Path'));
		so.default = '/etc/homeproxy/ruleset/';
		so.placeholder = '/etc/homeproxy/ruleset/';
		so.validate = function(section_id, value) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));
			if (!value.match(/^\//))
				return _('Expecting: %s').format(_('absolute path'));

			return true;
		}
		so.rmempty = false;
		so.depends('type', 'remote');
		so.modalonly = true;

		so = ss.option(form.Flag, 'auto_update', _('Auto update'));
		so.default = '1';
		so.rmempty = false;
		so.depends('type', 'remote');
		so.modalonly = true;

		so = ss.option(form.Value, 'update_interval', _('Scheduled update time'));
		so.renderWidget = function() {
			return hp.renderCronSelector.apply(this, arguments);
		};
		/* 建议8：表格中以「每天 04:30 / 每周五 04:30」形式显示，弹窗内仍为选择器 */
		so.textvalue = function(section_id) {
			return hp.cronToHuman(this.cfgvalue(section_id) || this.default || '0 0 * * *');
		};
		so.default = '0 0 * * *';
		so.rmempty = false;
		so.validate = function(section_id, value) {
			value = value || this.formvalue(section_id);
			if (!validateUpdateCron(value))
				return _('Expecting: %s').format(_('valid cron expression'));

			return true;
		};
		so.depends('type', 'remote');
		/* Rule set settings end */

		s.tab('control', _('Access Control'));

		/* NTP settings start */
		s.tab('ntp', _('NTP Settings'));
		o = s.taboption('ntp', form.SectionValue, '_ntp', form.NamedSection, 'ntp', 'homeproxy');
		o.depends('routing_mode', 'custom');
		ss = o.subsection;

		so = ss.option(form.Flag, 'enabled', _('Enable NTP'));
		so.default = so.enabled;
		so.rmempty = false;

		so = ss.option(form.Value, 'server', _('NTP server address'));
		so.default = 'ntp.aliyun.com';
		so.placeholder = 'ntp.aliyun.com';
		so.rmempty = false;
		so.validate = function(_section_id, value) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));

			return stubValidator.apply('hostname', value) ||
				stubValidator.apply('ip4addr', value) ||
				stubValidator.apply('ip6addr', value);
		};
		so.depends('enabled', '1');

		so = ss.option(form.Value, 'server_port', _('NTP server port'));
		so.default = '123';
		so.placeholder = '123';
		so.datatype = 'port';
		so.rmempty = false;
		so.validate = function(_section_id, value) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));

			return stubValidator.apply('port', value);
		};
		so.depends('enabled', '1');

		so = ss.option(form.Value, 'interval', _('NTP time synchronization interval'),
			_('NTP service always uses direct connection and mainly provides accurate time for sing-box features that depend on it, such as TLS certificate verification, VMess, Reality/uTLS and other time-sensitive connection scenarios.') + '<br />' +
			_('Time format examples: 1m = 1 minute, 1h = 1 hour, 1d = 1 day.'));
		so.default = '30m';
		so.placeholder = '30m';
		so.rmempty = false;
		so.validate = function(_section_id, value) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));
			if (!validateDuration(value))
				return _('Expecting: %s').format(_('valid duration'));

			return true;
		};
		so.depends('enabled', '1');
		/* NTP settings end */

		/* Cache settings start */
		s.tab('cache', _('Persistent Cache Settings'));
		o = s.taboption('cache', form.SectionValue, '_cache', form.NamedSection, 'cache', 'homeproxy');
		o.depends('routing_mode', 'custom');
		ss = o.subsection;

		so = ss.option(form.ListValue, 'enabled', _('Enable cache file'));
		so.value('1', _('Enable'));
		so.value('0', _('Disable'));
		so.default = '1';
		so.rmempty = false;
		so.description = _('Master switch for Persist DNS cache and Save Proxy Selection');
		/* 规则1：缓存文件关闭时，持久化 DNS 缓存 / 保存代理选择 自动关闭 */
		var o_cache_enabled = so;
		o_cache_enabled.onchange = function(ev, section_id, value) {
			if (value === '0') {
				o_cache_store_dns.setValue(section_id, '0');
				o_cache_store_selected.setValue(section_id, '0');
			}
		};

		so = ss.option(form.Value, 'path', _('Persistent cache file path'));
		so.placeholder = '/etc/homeproxy/cache.db';
		so.default = '/etc/homeproxy/cache.db';
		so.depends('enabled', '1');

		so = ss.option(form.ListValue, 'store_dns', _('Persist DNS cache'));
		so.value('1', _('Enable'));
		so.value('0', _('Disable'));
		so.default = '1';
		so.rmempty = false;
		so.depends('enabled', '1');
		/* 规则2：持久化 DNS 缓存启用时，缓存文件自动启用（与保存代理选择无关） */
		var o_cache_store_dns = so;
		o_cache_store_dns.onchange = function(ev, section_id, value) {
			if (value === '1')
				o_cache_enabled.setValue(section_id, '1');
		};

		so = ss.option(form.ListValue, 'store_selected', _('Save Proxy Selection'));
		so.value('1', _('Enable'));
		so.value('0', _('Disable'));
		/* 默认启用：打过补丁的内核（003-add-cache-file-store-selected）会持久化
		   用户在面板里选中的节点，重启后仍然是上一次的选择；关掉才会在每次
		   启动时回到默认出口。此处的 '0' 只在上面的「缓存文件」总开关被关掉
		   时由规则 1 写入，不是本项自身的默认值。 */
		so.default = '1';
		so.rmempty = false;
		so.depends('enabled', '1');
		/* 规则3：保存代理选择启用时，缓存文件自动启用（与持久化 DNS 缓存无关） */
		var o_cache_store_selected = so;
		o_cache_store_selected.onchange = function(ev, section_id, value) {
			if (value === '1')
				o_cache_enabled.setValue(section_id, '1');
		};

		/* Cache settings end */

		/* ACL settings start */
		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
		ss = o.subsection;

		/* Interface control start */
		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;
		/* Interface control end */

		/* LAN IP policy start */
		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = ss.taboption('lan_ip_policy', form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		so.value('disabled', _('Disable'));
		so.value('listed_only', _('Proxy listed only'));
		so.value('except_listed', _('Proxy all except listed'));
		so.default = 'disabled';
		so.rmempty = false;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Direct IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv6_ips', _('Direct IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'except_listed', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Direct MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'listed_only', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Proxy MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv4_ips', _('Gaming mode IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv6_ips', _('Gaming mode IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends('homeproxy.config.ipv6_support', '1');

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_gaming_mode_mac_addrs', _('Gaming mode MAC-s'), null, hosts);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv4_ips', _('Global proxy IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends({'homeproxy.config.routing_mode': 'custom', '!reverse': true});

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv6_ips', _('Global proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'homeproxy.config.routing_mode': /^((?!custom).)+$/, 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_global_proxy_mac_addrs', _('Global proxy MAC-s'), null, hosts);
		so.depends({'homeproxy.config.routing_mode': 'custom', '!reverse': true});
		/* LAN IP policy end */

		/* WAN IP policy start */
		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Direct IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Direct IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');
		/* WAN IP policy end */

		/* Proxy domain list start */
		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends({'homeproxy.config.routing_mode': 'custom', '!reverse': true});
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('proxy_list', value);
		}
		so.remove = function(/* ... */) {
			let routing_mode = this.section.formvalue('config', 'routing_mode');
			if (routing_mode !== 'custom')
				return callWriteDomainList('proxy_list', '');
			return true;
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Proxy domain list end */

		/* Direct domain list start */
		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.depends({'homeproxy.config.routing_mode': 'custom', '!reverse': true});
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('direct_list', value);
		}
		so.remove = function(/* ... */) {
			let routing_mode = this.section.formvalue('config', 'routing_mode');
			if (routing_mode !== 'custom')
				return callWriteDomainList('direct_list', '');
			return true;
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Direct domain list end */
		/* ACL settings end */

		/* Panel settings start — only register the tab when the Clash API is
		   actually generated (custom / bypass_mainland_china). In other modes
		   the section render override above strips the (otherwise blank) pane. */
		if (routingMode === 'custom' || routingMode === 'bypass_mainland_china') {
		s.tab('panel', _('Panel Settings'));
		o = s.taboption('panel', form.SectionValue, '_clash_api', form.NamedSection, 'clash_api', 'homeproxy');
		o.depends({'routing_mode': /^(custom|bypass_mainland_china)$/});
		ss = o.subsection;

		so = ss.option(form.Value, 'external_ui', _('UI path'));
		so.placeholder = '/etc/homeproxy/run/ui';
		so.default = '/etc/homeproxy/run/ui';
		/* 该路径会被 rpcd 侧直接 rm -rf / mv（安装、更新、回滚面板），
		   界面必须拦住根目录、系统目录与 `..` 回溯；判定规则与
		   luci.homeproxy 的 sanitizePanelDir()、fetch_panel.sh 保持一致。 */
		so.validate = function(section_id, value) {
			value = (value || '').trim();

			if (!value)
				return true;

			const normalized = value.replace(/\/+/g, '/').replace(/\/+$/, ''),
			      protectedPrefix = /^\/(bin|sbin|lib|usr|proc|sys|dev|overlay|rom|boot|tmp|var)\//;

			if (!normalized.startsWith('/')
				|| !/^\/[^\/]+\/[^\/]+/.test(normalized)
				|| /(^|\/)\.\.($|\/)/.test(normalized)
				|| protectedPrefix.test(normalized)
				|| (normalized.startsWith('/etc/') && !normalized.startsWith('/etc/homeproxy/')))
				return _('Invalid UI path: it must not be a system directory (/, /etc, /usr, /tmp, ...) and must not contain "..".');

			return true;
		};

		const panelPresetUrls = {
			'https://ghproxy.net/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip': 'Zashboard 完整版 (ghproxy.net)',
			'https://ghproxy.net/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip': 'Zashboard CDN Fonts (ghproxy.net)',
			'https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip': 'Zashboard CDN Fonts (gh-proxy)',
			'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip': 'Zashboard CDN Fonts',
			'https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip': 'Zashboard 完整版 (gh-proxy)',
			'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip': 'Zashboard 完整版',
			'https://gh-proxy.com/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip': 'MetaCubeXD (gh-proxy)',
			'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip': 'MetaCubeXD',
			'https://gh-proxy.com/https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip': 'YACD (gh-proxy)',
			'https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip': 'YACD',
			'https://gh-proxy.com/https://github.com/MetaCubeX/Razord-meta/archive/refs/heads/gh-pages.zip': 'Razord (gh-proxy)',
			'https://github.com/MetaCubeX/Razord-meta/archive/refs/heads/gh-pages.zip': 'Razord'
		};

		so = ss.option(form.ListValue, 'external_ui_download_url', _('UI download URL'));
		/* gh-proxy.com leads: direct GitHub measured faster (~89 KB/s vs
		   ~22 KB/s) but is unreliable — usually unreachable, and a half-open
		   connection stalls until the timeout expires, so the download never
		   completes. Reliability beats peak throughput here. */
		so.value('https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip', 'Zashboard 完整版 (gh-proxy，推荐)');
		so.value('https://ghproxy.net/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip', 'Zashboard 完整版 (ghproxy.net)');
		so.value('https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip', 'Zashboard 完整版（直连）');
		so.value('https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip', 'Zashboard CDN Fonts (gh-proxy)');
		so.value('https://ghproxy.net/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip', 'Zashboard CDN Fonts (ghproxy.net)');
		so.value('https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip', 'Zashboard CDN Fonts（直连）');
		so.value('https://gh-proxy.com/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip', 'MetaCubeXD (gh-proxy)');
		so.value('https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip', 'MetaCubeXD');
		so.value('https://gh-proxy.com/https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip', 'YACD (gh-proxy)');
		so.value('https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip', 'YACD');
		so.value('https://gh-proxy.com/https://github.com/MetaCubeX/Razord-meta/archive/refs/heads/gh-pages.zip', 'Razord (gh-proxy)');
		so.value('https://github.com/MetaCubeX/Razord-meta/archive/refs/heads/gh-pages.zip', 'Razord');
		so.value('__custom__', _('Custom'));
		so.default = 'https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip';
		so.load = function(section_id) {
			const value = uci.get(data[0], section_id, 'external_ui_download_url') ?? this.default;
			return (value in panelPresetUrls) ? value : '__custom__';
		};
		so.write = function(section_id, value) {
			if (value === '__custom__') {
				const customValue = (this.section?.formvalue(section_id, 'external_ui_download_url_custom') || '').trim();
				uci.set(data[0], section_id, 'external_ui_download_url', customValue);
			} else {
				uci.set(data[0], section_id, 'external_ui_download_url', value);
			}
		};

		so = ss.option(form.Value, 'external_ui_download_url_custom', _('Custom URL'));
		so.placeholder = 'https://example.com/dist.zip';
		so.depends('external_ui_download_url', '__custom__');
		so.load = function(section_id) {
			const value = (uci.get(data[0], section_id, 'external_ui_download_url') || '').trim();
			return (value in panelPresetUrls) ? '' : value;
		};
		so.write = function(section_id, value) {
			uci.set(data[0], section_id, 'external_ui_download_url_custom', (value || '').trim());
		};
		so.remove = function(section_id) {
			uci.unset(data[0], section_id, 'external_ui_download_url_custom');
		};

		so = ss.option(form.ListValue, 'external_ui_download_detour', _('UI download detour'));
		so.value('', _('Default'));
		so.value('direct-out', _('Direct'));
		uci.sections(data[0], 'routing_node', (res) => {
			if (res.enabled === '1')
				so.value(res['.name'], res.label);
		});
		so.default = 'direct-out';

		so = ss.option(form.Value, 'external_controller', _('API listen'),
			_('Use 0.0.0.0:port to open the panel from your browser.'));
		so.placeholder = '0.0.0.0:9095';
		so.default = '0.0.0.0:9095';
		so.datatype = 'ipaddrport(1)';
		so.rmempty = false;

		so = ss.option(form.Value, 'secret', _('API password'));
		so.password = true;

		so = ss.option(form.ListValue, 'default_mode', _('Default mode'));
		so.value('rule', _('Rule'));
		so.value('global', _('Global'));
		so.value('direct', _('Direct'));
		so.default = 'rule';
		so.rmempty = false;
		} /* Panel settings end (tab only registered for Clash-API-enabled routing modes) */

		/* After "Save & Apply" in custom mode, make sure the panel is installed.
		 * The real download is triggered by the init script in the background
		 * when the service restarts (ensure_panel in /etc/init.d/homeproxy), so
		 * we must NOT await the synchronous /upgrade/ui call here: on a slow
		 * mirror that download takes ~10 minutes and would freeze this screen
		 * the whole time. Fire it off without blocking Save & Apply. */
		if (typeof m.handleSaveApply === 'function') {
			const handleSaveApply = m.handleSaveApply;

			m.handleSaveApply = function(ev, mode) {
				const result = handleSaveApply.call(this, ev, mode);
				// Non-blocking: the panel auto-installs in the background via
				// the init script, so just kick this off and return immediately.
				ensurePanelInstalled();

				/* 「保存并应用」原本完全依赖 procd 的 config.change 触发器去重启
				   服务。但 procd 只会重启「已经有运行实例」的服务，而本插件在
				   「没配节点、也没开服务端」时会提前 return，一个实例都不创建，
				   触发器于是什么也不做 —— start_service 不执行，sync_rulesets
				   也就不跑，现象就是「点了保存并应用，日志里连一行规则集都没
				   有」。这里在服务确实没在跑时补一次显式 reload 兜底；服务在跑
				   时触发器已经完成重启（reload_service = stop + start），不再重复
				   重启，避免连接被断开两次。 */
				if (result && typeof result.then === 'function')
					result.then(() => getServiceStatus()).then((running) => {
						if (!running)
							return callRCInit('homeproxy', 'reload');
					}).catch(() => {});

				return result;
			};
		}

		const node = m.render();

		/* 表格列文字统一居中：名称列原本左对齐，与「启用/节点/出站」等
		   已居中的列不一致。只作用于本页表格单元格，弹窗（modal）在
		   独立 overlay 中，不受影响。 */
		if (node && node.nodeType === 1) {
			node.classList.add('homeproxy-client-form');
			node.insertBefore(E('style', [ `
				.homeproxy-client-form .cbi-section-table th,
				.homeproxy-client-form .cbi-section-table td { text-align: center; }
				.homeproxy-client-form .cbi-section-table td input,
				.homeproxy-client-form .cbi-section-table td select { text-align: center; }
			` ]), node.firstChild);
		}

		return node;
	}
});
