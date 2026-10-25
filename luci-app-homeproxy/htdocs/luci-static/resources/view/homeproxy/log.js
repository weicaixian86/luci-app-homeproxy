/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require uci';
'require ui';
'require view';

'require homeproxy as hp';
'require homeproxy.logview as logview';

/* 日志页：页面本身是一级菜单项「运行日志」，页面里再挂三个二级选项卡
 * （日志设置 / 插件日志 / 内核日志），它们排在运行日志**下面**。
 *
 * 为什么不是四个平级菜单项：LuCI 的菜单挂到 admin/services/homeproxy 下面，
 * 就会在页面顶部那排页签里跟「总览 / 客户端 / 服务端 / 路由设置 / DNS」并排
 * ——0.1.28 初版正是这样，看起来像四个互不相干的页面；想再往运行日志底下挂
 * 第三级，侧栏不渲染。所以三个二级选项卡由本页自己画（.hp-log-tabs），
 * 运行日志不重复出现在这一排：它已经是顶上那个页签了，回到它的方式就是点
 * 顶部「运行日志」。
 *
 * 三个日志面板共用 logview.renderPage()，各自只传一份来源清单（运行日志
 * 六个文件 + 两个下拉，插件日志四个文件、内核日志两个文件，后两者不做任何
 * 过滤）。日志设置是独立的一组控件，写 /etc/homeproxy/log.conf —— 不进 uci
 * 的理由见 logview.js 顶部：uci commit 会把隧道重启一次。
 *
 * 面板按需构建：第一次点某个选项卡才建它，切走时把它的轮询停掉。否则四个
 * 面板会同时轮询，六个日志文件每 5 秒被读四遍 —— /var/run 是内存盘，这些
 * 读全是白花的。
 */

const css = `
.hp-log-tabs {
	display: flex;
	flex-wrap: wrap;
	gap: 6px;
	margin: 0 0 10px;
	padding: 0;
	list-style: none;
}
.hp-log-tabs > li {
	margin: 0;
}
.hp-log-tabs > li > a {
	display: block;
	padding: 7px 15px;
	border: 1px solid rgba(128,128,128,.3);
	border-radius: 3px;
	background: rgba(128,128,128,.10);
	color: inherit;
	font-size: 13px;
	font-weight: 600;
	line-height: 1.2;
	text-decoration: none;
}
.hp-log-tabs > li > a:hover {
	background: rgba(128,128,128,.22);
}
.hp-log-tabs > li.hp-log-tab-active > a {
	border-color: var(--primary, #4a7dff);
	background: rgba(74,125,255,.14);
	box-shadow: inset 0 -2px 0 var(--primary, #4a7dff);
	color: var(--primary, #4a7dff);
}
.hp-log-panels {
	padding-top: 10px;
}
.hp-logset-row {
	display: flex;
	align-items: center;
	flex-wrap: wrap;
	gap: 8px;
	padding: 10px 12px;
	border-bottom: 1px solid rgba(128,128,128,.18);
}
.hp-logset-row:last-child {
	border-bottom: none;
}
.hp-logset-label {
	flex: 0 0 13em;
	font-weight: 600;
}
.hp-logset-field {
	display: flex;
	align-items: center;
	gap: 6px;
}
.hp-logset-field input[type="number"] {
	width: 7em;
}
.hp-logset-hint {
	padding: 8px 12px 0;
	color: #666;
	font-size: 12px;
	line-height: 1.6;
}
.hp-logset-buttons {
	display: flex;
	gap: 8px;
	padding: 12px;
}
`;

/* ── 面板一：运行日志 ───────────────────────────────────────────────────────
   全部六个文件合并成一条时间线，外加两个下拉：显示视图（纯前端过滤）与
   内核输出级别（真的改配置并重启内核）。 */
const log_sources = [
	{ file: 'homeproxy' },
	{ file: 'ruleset_download' },
	{ file: 'sing-box-c', core: true },
	{ file: 'core_download' },
	{ file: 'panel_download' },
	{ file: 'sing-box-s', core: true }
];

/* 插件自己写的那四个文件。 */
const plugin_sources = [
	{ file: 'homeproxy' },
	{ file: 'ruleset_download' },
	{ file: 'core_download' },
	{ file: 'panel_download' }
];

/* sing-box 自己的输出（客户端 + 服务端两个实例）。 */
const core_sources = [
	{ file: 'sing-box-c', core: true },
	{ file: 'sing-box-s', core: true }
];

/* ── 控件一：显示视图（看什么） ──────────────────────────────────────────────
   与「内核输出级别」是两件事：这里只改前端过滤，不重启任何东西。 */
function renderRuntimePanel(ctx) {
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
		'change': ui.createHandlerFn(ctx, (ev) => {
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

	/* ── 控件二：内核输出级别（sing-box 写多少） ────────────────────────────
	   这个真的会改配置并重启内核，所以单独放一个下拉、并写清后果。
	   显示名一律纯中文——界面上不出现 debug/info/warn/error 这些英文，
	   配置里存的原值是什么对操作者没有意义。 */
	const level_choices = {
		debug: logview.zh('Debug', _('Debug'), '调试'),
		info:  logview.zh('Info',  _('Info'),  '信息'),
		warn:  logview.zh('Warn',  _('Warn'),  '警告'),
		error: logview.zh('Error', _('Error'), '错误')
	};

	let selected = logview.normalizeLevel(uci.get('homeproxy', 'config', 'log_level'));

	/* Unified log level switcher: writes both the client (config) and the
	   server (section) so a single control tunes sing-box verbosity.
	   Unlike the view selector above this one changes what the CORE writes,
	   so it has to be saved AND applied (which restarts sing-box). */
	const level_sel = E('select', {
		'id': 'hp_unified_log_level',
		'class': 'cbi-input-select',
		'style': 'margin-left: 4px; width: 8em;',
		'title': _('Verbosity of the sing-box core. Changing it saves and applies the config, which restarts the core.'),
		'change': ui.createHandlerFn(ctx, (ev) => {
			const v = ev.target.value;
			selected = v;
			uci.set('homeproxy', 'config', 'log_level', v);
			uci.set('homeproxy', 'server', 'log_level', v);
			/* save+apply restarts sing-box (kernel picks up the new level). */
			page.refresh(true);
			return ctx.map.save(null, true).then(() => {
				ui.changes.apply(true);
			});
		})
	});

	Object.keys(level_choices).forEach((v) => {
		level_sel.appendChild(E('option', {
			'value': v,
			'selected': (v === selected) ? '' : null
		}, [ level_choices[v] ]));
	});

	const page = logview.renderPage(ctx, {
		key: 'log-refresh',
		box_id: 'hp_log_runtime',
		lazy: true,
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

	/* nodes 保持成**数组**，不要再包一层 E()：E(array) 返回的是
	   DocumentFragment，挂上去一次就被搬空了，切回来会变成空白。 */
	return { page: page, nodes: page.nodes };
}

/* ── 面板二：日志设置 ───────────────────────────────────────────────────────
   两个数字 + 一个单位。刷新间隔只决定这几个日志页多久重读一次文件；大小
   上限是 clean_log.sh 的轮转阈值。两者都写 log.conf，谁都不重启。 */
function renderSettingsPanel(ctx, onSaved) {
	let settings = logview.normalizeSettings(logview.DEFAULT_SETTINGS);

	const refresh_in = E('input', {
		'type': 'number',
		'class': 'cbi-input-text',
		'min': String(logview.REFRESH_MIN),
		'max': String(logview.REFRESH_MAX),
		'step': '1',
		'value': String(settings.refresh)
	});

	const size_in = E('input', {
		'type': 'number',
		'class': 'cbi-input-text',
		'step': '1',
		'value': String(settings.size)
	});

	/* 单位下拉：KB / MB / GB，顺序与设计稿一致。 */
	const unit_sel = E('select', {
		'class': 'cbi-input-select',
		'change': ui.createHandlerFn(ctx, (ev) => {
			/* 换单位时保持字节数不变：1024 MB 换成 GB 就是 1，1 MB 换成 KB
			   就是 1024；被该单位的上下限夹住时按边界取值。不这么做的话，
			   「切一下单位，上限悄悄变成 1 KB」太容易发生了。 */
			const bytes = logview.settingsBytes(settings);
			const unit = logview.normalizeUnit(ev.target.value);
			const r = logview.sizeRange(unit);

			let n = Math.round(bytes / logview.UNIT_BYTES[unit]);

			if (n < r.min) n = r.min;
			if (n > r.max) n = r.max;

			settings = { refresh: settings.refresh, size: n, unit: unit };
			writeBack();
		})
	}, logview.UNIT_KEYS.map((u) => E('option', { 'value': u }, [ u ])));

	/* 生效值回显：让人一眼看到「1 MB」到底是多少字节、有没有被夹住。 */
	const effective = E('div', { 'class': 'hp-logset-hint' });

	/* 数字框的上下限跟着单位走：KB 最少 64，MB 最少 1，GB 最多 1（上限 1 GiB）。 */
	function applyRange() {
		const r = logview.sizeRange(unit_sel.value);

		size_in.setAttribute('min', String(r.min));
		size_in.setAttribute('max', String(r.max));
	}

	function paint() {
		dom.content(effective, [
			logview.zh('Currently in effect: %s per log file.',
				_('Currently in effect: %s per log file.'), '当前生效：每个日志文件 %s。').format(
				logview.formatBytes(logview.settingsBytes(settings))),
			' ',
			logview.zh('There are six log files in total.',
				_('There are six log files in total.'), '一共 6 个日志文件。')
		]);
	}

	function writeBack() {
		refresh_in.value = String(settings.refresh);
		size_in.value = String(settings.size);
		unit_sel.value = settings.unit;
		applyRange();
		paint();
	}

	writeBack();

	L.resolveDefault(logview.callSettings(), null).then((raw) => {
		settings = logview.normalizeSettings(raw ? raw : logview.DEFAULT_SETTINGS);
		writeBack();
	});

	const save_btn = E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': ui.createHandlerFn(ctx, () => {
			settings = logview.normalizeSettings({
				refresh: refresh_in.value,
				size: size_in.value,
				unit: unit_sel.value
			});

			/* 夹过的值写回控件：输入 0 或 99999 时不该让界面停在一个
			   后端根本不会采用、也不显示的数字上。 */
			writeBack();

			return logview.saveSettings(
				String(settings.refresh), String(settings.size), settings.unit
			).then((res) => {
				if (res && res.result === false)
					throw new Error(res.error || 'save failed');

				settings = logview.normalizeSettings(res || settings);
				writeBack();

				/* 已经建好的日志面板立刻按新间隔重排轮询：否则要等下次
				   打开页面才生效，用户会以为设置没保存。 */
				if (typeof onSaved === 'function')
					onSaved(settings);

				ui.addNotification(null, E('p', [
					logview.zh('Log settings saved.', _('Log settings saved.'), '日志设置已保存。')
				]), 'info');
			}).catch((e) => {
				/* 最常见的两种失败：rpcd 里还是旧版 ucode（Method not
				   found）和 /etc/homeproxy 不可写。说清该怎么办，不要
				   只回一个英文异常 —— 但原文也留着（小字），否则「为什么
				   失败」又变成了猜。 */
				ui.addNotification(null, E('div', {}, [
					E('p', [
						logview.zh('Failed to save the log settings: %s',
							_('Failed to save the log settings: %s'),
							'日志设置保存失败：%s').format(
							logview.zh('if this is a fresh upgrade, restart rpcd first (/etc/init.d/rpcd restart)',
								_('if this is a fresh upgrade, restart rpcd first (/etc/init.d/rpcd restart)'),
								'如果是刚升级完，请先重启 rpcd（/etc/init.d/rpcd restart）')
						)
					]),
					E('p', {}, [ E('small', {}, [ String((e && e.message) || e || '') ]) ])
				]), 'danger');
			});
		})
	}, [ logview.zh('Save', _('Save'), '保存') ]);

	const reset_btn = E('button', {
		'class': 'btn cbi-button',
		'click': ui.createHandlerFn(ctx, () => {
			settings = logview.normalizeSettings(logview.DEFAULT_SETTINGS);
			writeBack();
		})
	}, [ logview.zh('Restore defaults', _('Restore defaults'), '恢复默认') ]);

	const nodes = [
		E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'hp-logset-row' }, [
				E('div', { 'class': 'hp-logset-label' }, [
					logview.zh('Log refresh interval', _('Log refresh interval'), '日志刷新时间')
				]),
				E('div', { 'class': 'hp-logset-field' }, [
					refresh_in,
					E('span', {}, [ logview.zh('seconds', _('seconds'), '秒') ])
				])
			]),
			/* 值 + 单位在**一行**里（用户 0.1.28 明确要求）：单位和数字是同一件
			   事的两半，拆成「日志大小上限」和「日志大小上限单位」两行后，中间
			   还夹着别的内容时看不出它们属于同一个设置。 */
			E('div', { 'class': 'hp-logset-row' }, [
				E('div', { 'class': 'hp-logset-label' }, [
					logview.zh('Log size limit', _('Log size limit'), '日志大小上限')
				]),
				E('div', { 'class': 'hp-logset-field' }, [ size_in, unit_sel ])
			]),
			effective,
			E('div', { 'class': 'hp-logset-hint' }, [
				logview.zh('The refresh interval only decides how often these log pages re-read their files. It is stored separately from the service configuration, so changing it never restarts the core.',
					_('The refresh interval only decides how often these log pages re-read their files. It is stored separately from the service configuration, so changing it never restarts the core.'),
					'刷新时间只决定这几个日志页面多久重新读一次文件。它和服务配置分开存放，改它不会重启内核。'),
				E('br'),
				logview.zh('When a log file reaches the size limit it is copied to .1 (one generation) and then emptied, so the oldest lines are the ones that go. The log pages no longer cut the display at a fixed number of lines: whatever is in the file is shown.',
					_('When a log file reaches the size limit it is copied to .1 (one generation) and then emptied, so the oldest lines are the ones that go. The log pages no longer cut the display at a fixed number of lines: whatever is in the file is shown.'),
					'日志文件达到上限时先另存为 .1（保留一代）再清空，被丢弃的是最早的行。日志页面不再按固定条数截断显示：文件里有多少行就显示多少行。'),
				E('br'),
				logview.zh('The size limit is capped at 1 GB because the log directory lives on a RAM disk.',
					_('The size limit is capped at 1 GB because the log directory lives on a RAM disk.'),
					'大小上限最多 1 GB：日志目录在内存盘上。')
			])
		]),
		E('div', { 'class': 'hp-logset-buttons' }, [ save_btn, reset_btn ])
	];

	return { page: null, nodes: nodes };
}

/* ── 面板三：插件日志 ───────────────────────────────────────────────────────
   只有插件自己写的那四个文件，**一个过滤器都没有**。
   这个页面存在的意义就是「原样看全部」：运行日志页有两个下拉，排查时最怕
   的就是「明明有这行，界面上却看不到」——而问题常常只是某个过滤器还停在
   上次选的值。这里不做任何过滤，也不读 uci 里的 log_view。 */
function renderPluginPanel(ctx) {
	const page = logview.renderPage(ctx, {
		key: 'log-plugin-refresh',
		box_id: 'hp_log_plugin',
		lazy: true,
		sources: plugin_sources,
		/* 这个页签只有一个用途：把这四个文件原样摊开。框底那行「每 N 秒刷新。
		   · 先点击日志区域…」在这里没有信息量，去掉（轮询照旧）。 */
		hint: false,
		empty: _('The plugin has not written anything yet.')
	});

	/* nodes 保持成**数组**，不要再包一层 E()：E(array) 返回的是
	   DocumentFragment，挂上去一次就被搬空了，切回来会变成空白。 */
	return { page: page, nodes: page.nodes };
}

/* ── 面板四：内核日志 ───────────────────────────────────────────────────────
   只有 sing-box 自己的输出，**不分级别**，debug/trace 也照样显示。
   与插件日志分开的理由：内核的行带级别 token、时间戳可能来自 UTC（本机没有
   tzdata 时），混在插件日志里既看不清 outbound/xxx 之类的明细，也容易被
   「显示视图」的下拉一过滤就整片消失。UTC→本地 的换算说明由 logview 按
   core_tz 标记自动补上。 */
function renderCorePanel(ctx) {
	const page = logview.renderPage(ctx, {
		key: 'log-core-refresh',
		box_id: 'hp_log_core',
		lazy: true,
		sources: core_sources,
		/* 与插件日志同理：只保留 UTC→本地 的换算说明（由 logview 按 core_tz
		   标记自动插到最上面），框底那行刷新提示不要。 */
		hint: false,
		empty: _('The core has not written anything yet.')
	});

	/* nodes 保持成**数组**，不要再包一层 E()：E(array) 返回的是
	   DocumentFragment，挂上去一次就被搬空了，切回来会变成空白。 */
	return { page: page, nodes: page.nodes };
}

/* ── 选项卡外壳 ────────────────────────────────────────────────────────────
   runtime 带 base: true —— 它是页面本身（顶上那个「运行日志」页签），**不进**
   这排二级选项卡，否则同一个名字会在两级各出现一次。另外三个才是这一排的
   成员，顺序就是需求给的顺序。 */
const TABS = [
	{ id: 'runtime',  base: true, title: () => logview.zh('Runtime Log', _('Runtime Log'), '运行日志'), build: renderRuntimePanel },
	{ id: 'settings', title: () => logview.zh('Log Settings', _('Log Settings'), '日志设置'),      build: renderSettingsPanel },
	{ id: 'plugin',   title: () => logview.zh('Plugin Log', _('Plugin Log'), '插件日志'),          build: renderPluginPanel },
	{ id: 'core',     title: () => logview.zh('Core Log', _('Core Log'), '内核日志'),              build: renderCorePanel }
];

const BASE_TAB = TABS.filter((t) => t.base)[0];
const SUB_TABS = TABS.filter((t) => !t.base);

function renderTabs(ctx) {
	const bar = E('ul', { 'class': 'hp-log-tabs' });
	const host = E('div', { 'class': 'hp-log-panels' });
	const built = {};

	/* null = 正在看运行日志本身：这时候三个二级选项卡都不高亮。 */
	let active = null;

	function markTab(id) {
		for (let i = 0; i < bar.children.length; i++) {
			const li = bar.children[i];

			li.className = (id && li.getAttribute('data-tab') === id) ? 'hp-log-tab-active' : '';
		}
	}

	/* 换面板 = 把旧节点摘下来、把新节点挂上去。面板节点只建一次并留着，
	   这样切回来还是原来那一份（滚动位置、已读到的内容都在），不会重建。 */
	function mount(nodes) {
		while (host.firstChild)
			host.removeChild(host.firstChild);

		const list = Array.isArray(nodes) ? nodes : [ nodes ];

		for (let i = 0; i < list.length; i++) {
			if (list[i])
				host.appendChild(list[i]);
		}
	}

	/* 设置保存成功后，让已经建好的日志面板按新间隔重排轮询。 */
	function retune(next) {
		Object.keys(built).forEach((k) => {
			const p = built[k].page;

			if (p && typeof p.retune === 'function')
				p.retune(next.refresh);
		});
	}

	function activate(id) {
		if (active === id)
			return null;

		const prev = active ? built[active] : null;

		/* 切走就停轮询：否则每访问过一个选项卡就多一个定时器。 */
		if (prev && prev.page && typeof prev.page.stop === 'function')
			prev.page.stop();

		active = id;
		markTab(id);

		if (!built[id])
			built[id] = TABS.filter((t) => t.id === id)[0].build(ctx, retune);

		mount(built[id].nodes);

		const cur = built[id];

		if (cur.page && typeof cur.page.start === 'function')
			return cur.page.start();

		return null;
	}

	/* 三个二级选项卡。运行日志不在这里：它是页面本身，回到它点顶部那个
	   「运行日志」页签（LuCI 会重新渲染这一页，正好回到默认面板）。 */
	SUB_TABS.forEach((t) => {
		bar.appendChild(E('li', { 'data-tab': t.id }, [
			E('a', {
				'href': '#',
				'click': ui.createHandlerFn(ctx, (ev) => {
					ev.preventDefault();
					return activate(t.id);
				})
			}, [ t.title() ])
		]));
	});

	/* 打开这一页先看运行日志，此时三个选项卡都不高亮。 */
	activate(BASE_TAB.id);

	return E([ E('style', [ css ]), bar, host ]);
}

return view.extend({
	render() {
		let m;

		hp.installCloseButtonText();

		m = new form.Map('homeproxy');
		this.map = m;

		/* Both sections must be in the map so the unified level switch can
		   commit log_level changes to config AND server. The config section
		   hosts the dummy option that renders the tabbed log page; the
		   server section is kept only so its log_level change gets committed
		   and is rendered as an empty node to avoid a stray empty box. */
		const s_config = m.section(form.NamedSection, 'config', 'homeproxy');
		s_config.anonymous = true;
		const s_server = m.section(form.NamedSection, 'server', 'homeproxy');
		s_server.anonymous = true;
		s_server.render = function() { return E([]); };

		const o = s_config.option(form.DummyValue, '_unified_logview');
		o.render = L.bind(renderTabs, this);

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
