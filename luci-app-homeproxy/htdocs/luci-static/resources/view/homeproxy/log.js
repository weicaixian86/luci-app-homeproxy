/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

'require homeproxy as hp';

/* Thanks to luci-app-aria2 */
const css = '				\
#log_textarea {				\
	padding: 10px;			\
	text-align: left;		\
}					\
#log_textarea pre {			\
	padding: .5rem;			\
	word-break: break-all;		\
	margin: 0;			\
}					\
.hp-log-topbar {			\
	display: flex;			\
	align-items: center;		\
	justify-content: space-between;	\
	flex-wrap: wrap;			\
	gap: 8px;			\
	padding: 8px 10px;		\
}					\
.hp-log-src {				\
	margin-bottom: 10px;		\
	border: 1px solid #ddd;		\
	border-radius: 4px;		\
	overflow: hidden;		\
}					\
.hp-log-src-head {			\
	padding: 4px 10px;		\
	font-weight: bold;		\
	color: #fff;			\
}					\
.hp-log-src pre {			\
	background: #fafafa;		\
}					\
.src-homeproxy {			\
	background: #e67e22;		\
}					\
.src-sing-box-c {			\
	background: #2980b9;		\
}					\
.src-core-download {			\
	background: #8e44ad;		\
}					\
.src-panel-download {			\
	background: #16a085;		\
}					\
.src-sing-box-s {			\
	background: #c0392b;		\
}';

const hp_dir = '/var/run/homeproxy';

/* NOTE: log_sources / log_level_choices are built inside renderUnifiedLog()
   (render time) rather than at module load, so the gettext lookups (_()) run
   after the translation catalog is guaranteed to be loaded. Defining them at
   module top-level risks capturing the English fallback if evaluated too early. */

const callLogClean = rpc.declare({
	object: 'luci.homeproxy',
	method: 'log_clean',
	params: ['type'],
	expect: { '': {} }
});

/* Max lines kept per source; older lines are dropped when exceeded. */
const LOG_MAX_LINES = 1000;

/* Read one log file and return a DOM node for its content. */
function readSourceLog(src) {
	return fs.read_direct(String.format('%s/%s.log', hp_dir, src.file), 'text')
	.then((res) => {
		let text = res.trim();
		let truncated = false;
		if (text) {
			const lines = text.split('\n');
			if (lines.length > LOG_MAX_LINES) {
				text = lines.slice(-LOG_MAX_LINES).join('\n');
				truncated = true;
			}
		}
		const body = (text || _('Log is empty.')) +
			(truncated ? '\n' + _('… (only the last %s lines are shown)').format(LOG_MAX_LINES) : '');
		return E('pre', { 'wrap': 'pre', 'class': src.cls }, [ body ]);
	}).catch((err) => {
		let body;
		if (err.toString().includes('NotFoundError'))
			body = _('Log file does not exist.');
		else
			body = _('Unknown error: %s').format(err);
		return E('pre', { 'wrap': 'pre', 'class': src.cls }, [ body ]);
	});
}

/* Build the unified log view (top bar with level switch + body) and poll. */
function renderUnifiedLog() {
	/* Source blocks, top-to-bottom, in a single view. Defined here (render
	   time) so the labels are translated against the loaded catalog. */
	const log_sources = [
		{ file: 'homeproxy',      label: _('HomeProxy'),       cls: 'src-homeproxy' },
		{ file: 'sing-box-c',     label: _('sing-box client'), cls: 'src-sing-box-c' },
		{ file: 'core_download',  label: _('Core download'),   cls: 'src-core-download' },
		{ file: 'panel_download', label: _('Panel download'),  cls: 'src-panel-download' },
		{ file: 'sing-box-s',     label: _('sing-box server'), cls: 'src-sing-box-s' }
	];

	const log_level_choices = {
		trace: _('Trace'),
		debug: _('Debug'),
		info:  _('Info'),
		warn:  _('Warn'),
		error: _('Error'),
		fatal: _('Fatal'),
		panic: _('Panic')
	};

	const selected = uci.get('homeproxy', 'config', 'log_level') || 'warn';

	/* Unified log level switcher: writes both the client (config) and the
	   server (server) section so a single control tunes sing-box verbosity. */
	const level_sel = E('select', {
		'id': 'hp_unified_log_level',
		'class': 'cbi-input-select',
		'style': 'margin-left: 4px; width: 7em;',
		'change': ui.createHandlerFn(this, (ev) => {
			const v = ev.target.value;
			uci.set('homeproxy', 'config', 'log_level', v);
			uci.set('homeproxy', 'server', 'log_level', v);
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

	const log_body = E('div', { 'id': 'log_textarea' },
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}, _('Collecting data...'))
	);

	let autoRefresh = true;

	function refresh() {
		if (!autoRefresh)
			return;
		const reads = log_sources.map((src) => {
			return readSourceLog(src).then((node) => {
				return E('div', { 'class': 'hp-log-src' }, [
					E('div', { 'class': 'hp-log-src-head ' + src.cls }, [ src.label ]),
					node
				]);
			});
		});
		return Promise.all(reads).then((blocks) => {
			dom.content(log_body, blocks);
		});
	}

	/* Auto-refresh checkbox: when checked the log reloads on every poll tick
	   (LuCI default 5s); when unchecked the view freezes on the last snapshot. */
	const auto_cb = E('input', {
		'type': 'checkbox',
		'checked': autoRefresh ? '' : null,
		'style': 'margin-left: 4px;',
		'change': ui.createHandlerFn(this, (ev) => {
			autoRefresh = ev.target.checked;
			if (autoRefresh)
				refresh();
		})
	});

	poll.add(refresh);

	return E([
		E('style', [ css ]),
		E('div', { 'class': 'cbi-map' }, [
			E('div', { 'class': 'cbi-section hp-log-topbar' }, [
			E('div', { 'style': 'display:flex; align-items:center;' }, [
				_('Log level:'),
				level_sel
			]),
			E('label', { 'style': 'display:flex; align-items:center; margin-left:16px;' }, [
				auto_cb,
				_('Auto refresh')
			]),
			E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, () => {
						return Promise.all(log_sources.map((src) =>
							L.resolveDefault(callLogClean(src.file), {})
						));
					})
				}, [ _('Clean log') ])
			]),
			E('div', { 'class': 'cbi-section' }, [
				log_body,
				E('div', { 'style': 'text-align:right' },
					E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval))
				)
			])
		])
	]);
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
