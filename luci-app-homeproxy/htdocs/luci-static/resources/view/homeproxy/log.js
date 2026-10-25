/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
'require uci';
'require ui';
'require view';

'require homeproxy as hp';
'require homeproxy.logview as logview';

/* 界面文案的中文兜底在 homeproxy/logview.js 里（zh），四个页面共用一份；
   这里的下拉显示名一律走它，界面上一律纯中文。 */

/* Build the merged "runtime log" view: everything at once, plus the two
   controls that decide what the reader sees. The reading / parsing / rendering
   half lives in homeproxy/logview.js — 插件日志 and 内核日志 show the same
   data with a narrower source list and no filters at all. */
function renderUnifiedLog() {
	/* Merged into the single timeline, in merge order. Only the file names
	   matter now that the view renders plain log text without per-source
	   badges.

	   ruleset_download 必须是直接来源：init.d 的预下载会把新增行 tail 进
	   主日志，但「保存并应用」还会走 rpcd 的脱管下载（--detach），那条路
	   没有任何搬运 —— 不直接挂上来，用户在界面上就永远看不到下载日志，
	   只能 SSH。两路同时写主日志时会出现少量重复行，时间戳一致、相邻排列，
	   可接受；看不到永远比重复糟糕。 */
	const log_sources = [
		{ file: 'homeproxy' },
		{ file: 'ruleset_download' },
		{ file: 'sing-box-c', core: true },
		{ file: 'core_download' },
		{ file: 'panel_download' },
		{ file: 'sing-box-s', core: true }
	];

	/* ── 控件一：显示视图（看什么） ──────────────────────────────────────
	   与「内核输出级别」是两件事：这里只改前端过滤，不重启任何东西。 */
	const view_choices = {
		all:   logview.zh('All',      _('All'),      '全部'),
		event: logview.zh('Events',   _('Events'),   '事件'),
		warn:  logview.zh('Warnings', _('Warnings'), '警告'),
		error: logview.zh('Errors',   _('Errors'),   '错误')
	};

	let view = logview.normalizeView(uci.get('homeproxy', 'config', 'log_view'));

	const view_sel = E('select', {
		'id': 'hp_log_view',
		'class': 'cbi-input-select',
		'style': 'margin-left: 4px; width: 8em;',
		'title': _('What to show. Purely a display filter: nothing is restarted.'),
		'change': ui.createHandlerFn(this, (ev) => {
			view = logview.normalizeView(ev.target.value);
			/* 只 commit 不 apply：改的是「看什么」，不该为此重启内核。
			   （uci.save() = 写回 /etc/config；apply 才会触发 reload。） */
			uci.set('homeproxy', 'config', 'log_view', view);
			uci.save();
			/* 立刻重画，不等下一个轮询。 */
			return page.refresh(true);
		})
	});

	Object.keys(view_choices).forEach((v) => {
		view_sel.appendChild(E('option', {
			'value': v,
			'selected': (v === view) ? '' : null
		}, [ view_choices[v] ]));
	});

	/* ── 控件二：内核输出级别（sing-box 写多少） ────────────────────────
	   这个真的会改配置并重启内核，所以单独放一个下拉、并写清后果。
	   显示名一律纯中文——界面上不出现 debug/info/warn/error 这些英文，
	   配置里存的原值是什么对操作者没有意义。 */
	const log_level_choices = {
		debug: logview.zh('Debug', _('Debug'), '调试'),
		info:  logview.zh('Info',  _('Info'),  '信息'),
		warn:  logview.zh('Warn',  _('Warn'),  '警告'),
		error: logview.zh('Error', _('Error'), '错误')
	};

	let selected = logview.normalizeLevel(uci.get('homeproxy', 'config', 'log_level'));

	/* Unified log level switcher: writes both the client (config) and the
	   server (server) section so a single control tunes sing-box verbosity.
	   Unlike the view selector above this one changes what the CORE writes,
	   so it has to be saved AND applied (which restarts sing-box). */
	const level_sel = E('select', {
		'id': 'hp_unified_log_level',
		'class': 'cbi-input-select',
		'style': 'margin-left: 4px; width: 8em;',
		'title': _('Verbosity of the sing-box core. Changing it saves and applies the config, which restarts the core.'),
		'change': ui.createHandlerFn(this, (ev) => {
			const v = ev.target.value;
			selected = v;
			uci.set('homeproxy', 'config', 'log_level', v);
			uci.set('homeproxy', 'server', 'log_level', v);
			/* save+apply restarts sing-box (kernel picks up the new level). */
			page.refresh(true);
			return this.map.save(null, true).then(() => {
				ui.changes.apply(true);
			});
		})
	});

	Object.keys(log_level_choices).forEach((v) => {
		level_sel.appendChild(E('option', {
			'value': v,
			'selected': (v === selected) ? '' : null
		}, [ log_level_choices[v] ]));
	});

	const page = logview.renderPage(this, {
		key: 'log-refresh',
		sources: log_sources,
		head: [
			E('div', { 'style': 'display:flex; align-items:center;' }, [
				_('Show:'),
				view_sel
			]),
			E('div', { 'style': 'display:flex; align-items:center;' }, [
				_('Core log level:'),
				level_sel
			])
		],
		/* 闭包读的是外面的 view，所以下拉一变、下一次 refresh 就换了过滤。 */
		filter: (merged) => logview.filterByView(merged, view)
	});

	return E(page.nodes);
}

return view.extend({
	render() {
		let m;

		hp.installCloseButtonText();

		m = new form.Map('homeproxy');
		this.map = m;

		/* Both sections must be in the map so the unified level switch can
		   commit log_level changes to config AND server. The config section
		   hosts the dummy option that renders the unified log view; the
		   server section is kept only so its log_level change gets committed
		   and is rendered as an empty node to avoid a stray empty box. */
		const s_config = m.section(form.NamedSection, 'config', 'homeproxy');
		s_config.anonymous = true;
		const s_server = m.section(form.NamedSection, 'server', 'homeproxy');
		s_server.anonymous = true;
		s_server.render = function() { return E([]); };

		const o = s_config.option(form.DummyValue, '_unified_logview');
		o.render = L.bind(renderUnifiedLog, this);

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
