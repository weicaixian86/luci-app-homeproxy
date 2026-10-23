/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require rpc';
'require ui';
'require view';

'require homeproxy as hp';

const css = '				\
.homeproxy-connect-grid {		\
	display: grid;			\
	grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));\
	gap: 12px;			\
}					\
.homeproxy-connect-card {		\
	display: grid;			\
	grid-template-columns: 44px 1fr;	\
	gap: 10px;			\
	align-items: center;		\
	min-height: 64px;		\
	padding: 8px 10px;		\
	border-radius: 6px;		\
	background: #fff;		\
	box-shadow: 0 1px 4px rgba(0, 0, 0, .08);\
}					\
.homeproxy-connect-icon {		\
	display: flex;			\
	align-items: center;		\
	justify-content: center;		\
	width: 38px;			\
	height: 38px;			\
	border-radius: 50%;		\
	background: #f4f6f9;		\
}					\
.homeproxy-connect-icon svg {		\
	display: block;			\
	width: 24px;			\
	height: 24px;			\
}					\
.homeproxy-connect-info {		\
	min-height: 42px;		\
	padding: 7px 12px;		\
	border-radius: 8px;		\
	background: #e9edf2;		\
}					\
.homeproxy-connect-title {		\
	color: #7d8aa0;			\
	font-weight: 700;		\
	font-size: 13px;		\
	line-height: 1.2;		\
}					\
.homeproxy-connect-result {		\
	margin-top: 2px;		\
	color: #ff4d35;			\
	font-weight: 700;		\
	font-size: 13px;		\
	cursor: pointer;		\
	line-height: 1.2;		\
}';

function getConnStat(o, site) {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxy',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConnStat(site), {}).then((ret) => {
					let ele = o.default.firstElementChild.nextElementSibling;
					if (ret.result) {
						ele.style.setProperty('color', 'green');
						ele.innerHTML = _('passed');
					} else {
						ele.style.setProperty('color', 'red');
						ele.innerHTML = _('failed');
					}
				});
			})
		}, [ _('Check') ]),
		' ',
		E('strong', { 'style': 'color:gray' }, _('unchecked')),
	]);
}

/* Brand logos are inlined so the cards render without external assets and
   without pulling remote images into the router's web UI. */
const connLogos = {
	aliyun: '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ff6a00" d="M7.2 18.6a4.7 4.7 0 0 1 0-9.4 6.6 6.6 0 0 1 12.4 1.6 4 4 0 0 1-1.1 7.8z"/>' +
		'</svg>',
	google: '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ea4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>' +
		'<path fill="#4285f4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>' +
		'<path fill="#fbbc05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>' +
		'<path fill="#34a853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>' +
		'</svg>',
	github: '<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#1f2328" d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.04-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68.78 1.31.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/>' +
		'</svg>',
	youtube: '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ff0033" d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/>' +
		'</svg>'
};

function renderConnCards() {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxy',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	const items = [
		{ site: 'aliyun', title: _('Aliyun Connection') },
		{ site: 'google', title: _('Google Connection') },
		{ site: 'github', title: _('GitHub Connection') },
		{ site: 'youtube', title: _('YouTube Connection') }
	];

	return E('div', { 'class': 'homeproxy-connect-grid' }, items.map((item) => {
		const icon = E('div', { 'class': 'homeproxy-connect-icon' });
		icon.innerHTML = connLogos[item.site] || '';
		let result = E('div', {
			'class': 'homeproxy-connect-result',
			'title': _('HTTP request latency: time from sending the request to receiving the first byte. DNS, TCP and TLS handshakes are NOT included, so the value is much smaller than ping or node latency. Same metric as Passwall.'),
			'click': ui.createHandlerFn(this, () => {
				result.textContent = _('Checking...');
				result.style.setProperty('color', '#f0ad4e');
				result.title = _('Checking...');

				return L.resolveDefault(callConnStat(item.site), {}).then((ret) => {
					if (ret.result && ret.latency != null) {
						result.style.setProperty('color', 'green');
						/* 主数字只放 HTTP 请求延迟（与 passwall 一致），
						   握手时间、HTTP 状态码放 tooltip —— passwall 也是
						   这么分层显示的，两者数值可以直接对比。 */
						result.textContent = '%s ms'.format(ret.latency);
						result.title = _('HTTP request latency: %s ms (handshake excluded)')
							.format(ret.latency)
							+ '\n' + _('DNS + TCP + TLS handshake: %s ms').format(ret.handshake)
							+ '\n' + _('Time to first byte: %s ms').format(ret.total)
							+ '\n' + _('HTTP status code: %s').format(ret.code);
					} else {
						result.style.setProperty('color', '#ff4d35');
						result.textContent = _('failed');
						result.title = ret.error
							? _('Failed: %s').format(ret.error)
							: _('Failed. The target did not return a complete HTTP response.');
					}
				});
			})
		}, [ _('Click to check') ]);

		return E('div', { 'class': 'homeproxy-connect-card' }, [
			icon,
			E('div', { 'class': 'homeproxy-connect-info' }, [
				E('div', { 'class': 'homeproxy-connect-title' }, [ item.title ]),
				result
			])
		]);
	}));
}

function getResVersion(o, type) {
	const callResVersion = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_get_version',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdate = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update',
		params: ['type'],
		expect: { '': {} }
	});

	return L.resolveDefault(callResVersion(type), {}).then((res) => {
		let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, () => {
					return L.resolveDefault(callResUpdate(type), {}).then((res) => {
						switch (res.status) {
						case 0:
							o.description = _('Successfully updated.');
							break;
						case 1:
							o.description = _('Update failed.');
							break;
						case 2:
							o.description = _('Already in updating.');
							break;
						case 3:
							o.description = _('Already at the latest version.');
							break;
						default:
							o.description = _('Unknown error.');
							break;
						}

						return o.map.reset();
					});
				})
			}, [ _('Check update') ]),
			' ',
			E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
				[ res.error ? 'not found' : res.version ]
			),
		]);

		o.default = spanTemp;
	});
}

return view.extend({
	render() {
		let m, s, o;

		/* The card styles below are not part of any stylesheet shipped with
		   the package, so they have to be injected here. Without them the
		   brand SVGs keep their intrinsic size and overflow the page. */
		if (!document.getElementById('homeproxy-connect-css')) {
			const style = E('style', { 'id': 'homeproxy-connect-css' });
			style.textContent = css;
			document.head.appendChild(style);
		}

		hp.installCloseButtonText();

		m = new form.Map('homeproxy');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_connection_check');
		o.rawhtml = true;
		o.render = renderConnCards;

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
		o.rawhtml = true;

		o = s.option(form.Value, 'github_token', _('GitHub token'));
		o.password = true;
		o.description = _('Optional. It is only used when checking resource updates, to raise the GitHub API rate limit from 60 to 5000 requests per hour. Leave it empty unless updates keep failing with "Failed to get the latest version". Note that the token is stored in plain text in /etc/config/homeproxy, so use a read-only one.');
		o.renderWidget = function() {
			let node = form.Value.prototype.renderWidget.apply(this, arguments);

			(node.querySelector('.control-group') || node).appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'title': _('Save'),
				'click': ui.createHandlerFn(this, () => {
					return this.map.save(null, true).then(() => {
						ui.changes.apply(true);
					});
				}, this.option)
			}, [ _('Save') ]));

			return node;
		}

	s = m.section(form.NamedSection, 'config', 'homeproxy', _('sing-box core management'));
	s.anonymous = true;

	const callCoreStatus = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_status',
		expect: { '': {} }
	});

	const callCoreUpdate = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_update',
		expect: { '': {} }
	});

	const callCoreProgress = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_progress',
		expect: { '': {} }
	});

	/* A 34 MB core tarball needs anywhere from 4 to 33 minutes on the mirrors
	   we ship, so the update now runs detached on the router and this page
	   polls for progress. Holding one request open for the whole transfer is
	   what used to make the download fail halfway with an empty log. */
	const CORE_POLL_INTERVAL = 3000;

	function coreLastLogLine(text) {
		const lines = (text || '').split('\n').map(l => l.trim()).filter(l => l);

		if (!lines.length)
			return '';

		/* The progress lines contain full mirror URLs (100+ chars); showing
		   one verbatim next to the button would blow out the row layout. */
		const line = lines[lines.length - 1];
		return (line.length > 90) ? line.slice(0, 90) + '…' : line;
	}

	o = s.option(form.DummyValue, '_singbox_core', _('reF1nd sing-box core'));
	o.rawhtml = true;
	o.render = function() {
		const self = this;
		let polling = false;

		const statusEl = E('strong', { 'style': 'color:#7d8aa0' }, [ _('loading...') ]);

		function showResult(res) {
			polling = false;
			btn.disabled = false;

			let msg, level;
			if (res.result) {
				msg = _('Download / update succeeded.');
				level = 'info';
			}
			else if (res.output && res.output.indexOf('unsupported') !== -1) {
				msg = _('Current architecture is not supported by reF1nd yet.');
				level = 'danger';
			}
			else if (res.output && res.output.indexOf('no_asset') !== -1) {
				msg = _('No matching binary for this architecture yet.');
				level = 'danger';
			}
			else {
				msg = _('Download / update failed. See log for details.');
				const tail = (res.log || '').split('\n').filter(l => l.trim()).slice(-4).join(' ; ');
				if (tail)
					msg += ' ' + tail;
				level = 'danger';
			}

			/* self.description is not rendered by this custom DummyValue
			   render, so surface the outcome as a toast — otherwise a failed
			   update looked like a dead button. */
			ui.addNotification(null, E('p', msg), level);
			return self.map.reset();
		}

		function startPolling() {
			if (polling)
				return;

			polling = true;
			btn.disabled = true;
			dom.content(statusEl, _('Downloading sing-box core…'));

			const tick = () => {
				/* The user may have navigated away while a 30-minute download
				   ran. Polling is detached from this view's lifecycle, so bail
				   out once our node is gone instead of resetting a form that
				   no longer exists. */
				if (!document.body.contains(statusEl)) {
					polling = false;
					return;
				}

				L.resolveDefault(callCoreProgress(), {}).then((res) => {
					if (res.running) {
						const line = coreLastLogLine(res.log);
						if (line)
							dom.content(statusEl, line);
						window.setTimeout(tick, CORE_POLL_INTERVAL);
						return;
					}
					showResult(res);
				}).catch(() => {
					/* A transient rpc error (rpcd restart, page reload race)
					   must not orphan a download that is still running on the
					   router: keep polling instead of declaring failure. */
					window.setTimeout(tick, CORE_POLL_INTERVAL);
				});
			};

			/* Give the detached wrapper a moment to create its pid file. */
			window.setTimeout(tick, 1500);
		}

		const btn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				if (polling)
					return;

				btn.disabled = true;
				dom.content(statusEl, _('Starting download…'));

				return L.resolveDefault(callCoreUpdate(), {}).then((res) => {
					/* Running (freshly started, or already in progress from an
					   earlier click) — switch to polling instead of waiting
					   for a response that will not arrive for many minutes. */
					if (res.running || res.started) {
						startPolling();
						return;
					}

					btn.disabled = false;
					dom.content(statusEl, res.log || _('unavailable'));
					ui.addNotification(null, E('p', res.log || _('Download / update failed. See log for details.')), 'danger');
					return null;
				}).catch(() => {
					btn.disabled = false;
				});
			})
		}, [ _('Download / update core') ]);

		let content = E('div', { 'style': 'cbi-value-field' }, [ btn, ' ', statusEl ]);

		/* Resume the display when the page is reopened mid-download: the
		   helper keeps running detached, so a reload must not lose progress. */
		L.resolveDefault(callCoreProgress(), {}).then((res) => {
			if (res.running) {
				startPolling();
				return null;
			}

			return L.resolveDefault(callCoreStatus(), {}).then((sres) => {
				let detail;
				if (sres.installed_version && sres.installed_version !== '-')
					detail = _('Installed: %s').format(sres.installed_version);
				else
					detail = _('Not installed');

				detail += ' / ' + _('Arch: %s').format(sres.arch || '-');

				/* 目标版本用「完整版本串」（1.14.3-reF1nd_<发布版本>），
				   与安装后 sing-box version 报出来的完全一致；旧后端没有
				   target_version 时回落到基础版本号。 */
				if (sres.asset_available)
					detail += ' / ' + _('Target: %s').format(sres.target_version || sres.refind_version || '-');
				else
					detail += ' / ' + _('No binary for this arch yet');

				dom.content(statusEl, detail);
			});
		}).catch(() => {
			dom.content(statusEl, _('unavailable'));
		});

		return content;
	};

	return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
