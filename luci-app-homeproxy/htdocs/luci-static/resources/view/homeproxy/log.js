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

const css = `
#log_textarea {
	text-align: left;
}
.hp-log-topbar {
	display: flex;
	align-items: center;
	justify-content: flex-start;
	flex-wrap: wrap;
	gap: 8px;
	padding: 8px 10px;
}
/* One merged log box with its own scrollbar: all five sources share this
   viewport, so the page no longer grows with the amount of history. */
.hp-log-scroll {
	max-height: 62vh;
	min-height: 240px;
	overflow-y: scroll;
	overflow-x: hidden;
	background: #fff;
	border: 1px solid #ddd;
	border-radius: 4px;
	padding: 6px 0;
	font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
	font-size: 12px;
	line-height: 1.55;
}
.hp-log-line {
	display: block;
	white-space: pre-wrap;
	word-break: break-all;
	padding: 0 10px;
	margin: 0;
}
.hp-log-tag {
	display: inline-block;
	min-width: 104px;
	margin-right: 8px;
	padding: 0 6px;
	border-radius: 3px;
	color: #fff;
	font-size: 11px;
	line-height: 16px;
	text-align: center;
	white-space: nowrap;
}
.hp-log-indent {
	display: inline-block;
	min-width: 112px;
	margin-right: 8px;
}
.hp-log-trunc {
	padding: 6px 10px;
	color: #c0392b;
	font-size: 11px;
}
.hp-log-empty {
	padding: 16px 12px;
	color: #888;
}
.src-homeproxy { background: #e67e22; }
.src-sing-box-c { background: #2980b9; }
.src-core-download { background: #8e44ad; }
.src-panel-download { background: #16a085; }
.src-sing-box-s { background: #c0392b; }
`;

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

/* Max lines shown in the merged log box; older lines are dropped. */
const LOG_MAX_LINES = 1000;

/* Leading "YYYY-MM-DD HH:MM:SS" of a log line. An optional "+0800"-style
   zone prefix is tolerated because some sing-box builds emit it. */
const TS_RE = /^\s*(?:[+-]\d{4}\s+)?(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})/;

/* Split one log file into records: a timestamped line plus the untimestamped
   continuation lines that follow it (e.g. sing-box "Cause:" / stack traces).
   Keeping records intact means multi-line entries survive the merge. */
function splitRecords(text) {
	const out = [];
	const lines = text.split('\n');
	let cur = null;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		const m = TS_RE.exec(line);

		if (m) {
			if (cur)
				out.push(cur);
			cur = { ts: m[1] + ' ' + m[2], lines: [ line ] };
		}
		else if (cur) {
			cur.lines.push(line);
		}
		else if (line.trim() !== '') {
			/* Lines before the first timestamp: keep as an untimed record. */
			out.push({ ts: '', lines: [ line ] });
		}
	}

	if (cur)
		out.push(cur);

	return out;
}

/* Read one log file and resolve to { src, records, error }. Never rejects, so
   one unreadable source cannot blank out the whole merged view. */
function readSourceLog(src) {
	return fs.read_direct(String.format('%s/%s.log', hp_dir, src.file), 'text')
	.then((res) => {
		const text = String(res || '').replace(/\r\n/g, '\n').trim();
		return { src: src, records: text ? splitRecords(text) : [], error: null };
	})
	.catch((err) => {
		const missing = err.toString().includes('NotFoundError');
		return {
			src: src,
			records: [],
			error: missing ? _('Log file does not exist.') : _('Unknown error: %s').format(err)
		};
	});
}

/* Merge records from every source into one chronological list. Each item is
   { si, ts, lines }, where si indexes log_sources. Untimed notices (a missing
   file, for instance) sort first so they stay visible. Ties keep source order. */
function mergeRecords(results, log_sources) {
	const all = [];

	results.forEach((r, si) => {
		if (r.error) {
			all.push({ si: si, ts: '', lines: [ r.error ] });
			return;
		}

		/* A source with no records and no error: surface a per-source
		   placeholder so the user can see at a glance that this source has
		   simply not produced output yet (e.g. the kernel never downloaded,
		   so sing-box never started and its logs stay empty). */
		if (r.records.length === 0) {
			all.push({ si: si, ts: '', lines:
				[ _('[%s] No log content yet.').format(log_sources[si].label) ] });
			return;
		}

		for (let i = 0; i < r.records.length; i++) {
			const rec = r.records[i];
			all.push({ si: si, ts: rec.ts, lines: rec.lines });
		}
	});

	all.sort((a, b) => {
		if (a.ts !== b.ts)
			return (a.ts < b.ts) ? -1 : 1;
		return a.si - b.si;
	});

	return all;
}

/* Render merged records into the single scrollable box. Only the first line of
   each record carries a coloured source tag; continuation lines are indented. */
function renderLogBox(merged, log_sources) {
	const box = E('div', { 'class': 'hp-log-scroll' });
	const flat = [];

	for (let i = 0; i < merged.length; i++) {
		const rec = merged[i];
		for (let j = 0; j < rec.lines.length; j++)
			flat.push({ si: rec.si, first: (j === 0), text: rec.lines[j] });
	}

	if (flat.length === 0) {
		box.appendChild(E('div', { 'class': 'hp-log-empty' }, [ _('Log is empty.') ]));
		return box;
	}

	let truncated = false;
	if (flat.length > LOG_MAX_LINES) {
		flat.splice(0, flat.length - LOG_MAX_LINES);
		truncated = true;
	}

	for (let i = 0; i < flat.length; i++) {
		const it = flat[i];
		const src = log_sources[it.si];
		const children = [];

		if (it.first)
			children.push(E('span', { 'class': 'hp-log-tag ' + src.cls }, [ src.label ]));
		else
			children.push(E('span', { 'class': 'hp-log-indent' }, [ '' ]));

		children.push(it.text === '' ? ' ' : it.text);
		box.appendChild(E('div', { 'class': 'hp-log-line' }, children));
	}

	if (truncated)
		box.appendChild(E('div', { 'class': 'hp-log-trunc' },
			[ _('… (only the last %s lines are shown)').format(LOG_MAX_LINES) ]));

	return box;
}

/* Build the unified log view (top bar with level switch + one merged box). */
function renderUnifiedLog() {
	/* Sources, in merge order. Defined here (render time) so the labels are
	   translated against the loaded catalog. */
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

	const selected = uci.get('homeproxy', 'config', 'log_level') || 'info';

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

		return Promise.all(log_sources.map(readSourceLog))
			.then((results) => {
				dom.content(log_body, renderLogBox(mergeRecords(results, log_sources), log_sources));
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
			/* All controls are left-aligned in a single row:
			   log level -> auto refresh -> clean log. */
			E('div', { 'style': 'display:flex; align-items:center; flex-wrap:wrap; gap:18px;' }, [
				E('div', { 'style': 'display:flex; align-items:center;' }, [
					_('Log level:'),
					level_sel
				]),
				E('label', { 'style': 'display:flex; align-items:center;' }, [
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
			])
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
