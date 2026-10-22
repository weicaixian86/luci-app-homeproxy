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
	/* Focusable for the Ctrl+A handler; show it rather than the browser's
	   default outline so it is obvious the box can be selected from. */
	outline: none;
}
#log_textarea:focus {
	outline: 1px solid #4a90d9;
	outline-offset: -1px;
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
/* Continuation line of a multi-line record (e.g. sing-box "Caused by:"),
   indented so it stays visually grouped with its timestamped first line. */
.hp-log-cont {
	padding-left: 24px;
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
   zone prefix is tolerated because some sing-box builds emit it. Accepts
   both sing-box (YYYY-MM-DD HH:MM:SS / YYYY/MM/DD HH:MM:SS) and Go log default
   forms so we can split the stream into timestamped records first. The level
   token is extracted separately (see LEVEL_RE below) so that shell-script
   logs (homeproxy, core_download, panel_download) — which have timestamps but
   no level token — still split cleanly into their own records. */
const TS_RE = /^\s*(?:[+-]\d{4}\s+)?(\d{4}[-/]\d{2}[-/]\d{2})[ T](\d{2}:\d{2}:\d{2})/;

/* Level token extraction. Matches a severity keyword (optional square
   brackets) that appears *immediately after* the timestamp suffix — i.e.
   it has to be the first token after the timestamp/zone gap, so we don't
   accidentally match descriptive words like "error" inside a shell logger's
   free-form message body. Used inside splitRecords only after TS_RE has
   already confirmed the line has a timestamp and we've trimmed the suffix. */
const LEVEL_TOKEN_RE = /^\s*\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC)\]?\b/i;

/* Severity weight: higher = more severe. A record whose level weight is
   >= the selected cutoff weight survives; others are filtered out on the
   frontend. Unknown/non-sing-box records (level = null) always pass. */
const LEVEL_ORDER = {
	trace:   0,
	debug:   1,
	info:    2,
	warn:    3,
	warning: 3,
	error:   4,
	fatal:   5,
	panic:   6
};

/* Split one log file into records: a timestamped line plus the untimestamped
   continuation lines that follow it (e.g. sing-box "Cause:" / stack traces).
   Keeping records intact means multi-line entries survive the merge.

   Records that look like sing-box output (a level token appears immediately
   after the timestamp) get a `level` (lowercase) tagged on the record;
   records from shell logger (homeproxy, core_download, panel_download) have
   timestamps but no such token → `level: null` and are always shown when the
   frontend applies its severity filter. */
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

			/* Extract level token from the region immediately after the
			   timestamp match. TS_RE does not capture trailing millis/zone
			   suffix ("+0000 123.456"), so `m[0].length` already points at
			   the first character of what should be the sing-box severity
			   token or a shell-log description. Running LEVEL_TOKEN_RE there
			   lets us distinguish the two: sing-box has a recognised keyword
			   right there; shell logs have free-form text. */
			const tail = line.slice(m[0].length);
			const lm = LEVEL_TOKEN_RE.exec(tail);
			const levelTok = lm ? lm[1].toLowerCase() : null;

			/* sing-box prefixes every line with a UTC offset ("+0000 ") from
			   Go's -0700 layout. TS_RE tolerates it for sorting, but the raw
			   prefix is noise in the rendered text, so strip it here. */
			cur = {
				ts:    m[1] + ' ' + m[2],
				level: levelTok,           /* null = non-sing-box, always shown */
				lines: [ line.replace(/^\s*[+-]\d{4}\s+/, '') ]
			};
		}
		else if (cur) {
			cur.lines.push(line);
		}
		else if (line.trim() !== '') {
			/* Lines before the first timestamp: keep as an untimed record. */
			out.push({ ts: '', level: null, lines: [ line ] });
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
   { si, ts, level, lines }, where si indexes log_sources. Records with a
   recognised sing-box level (level !== null) can be filtered later by weight;
   records with level=null (shell-script logs, errors, ...) always survive.
   Untimed notices (a missing file, for instance) sort first so they stay
   visible. Ties keep source order. */
function mergeRecords(results) {
	const all = [];

	results.forEach((r, si) => {
		if (r.error) {
			all.push({ si: si, ts: '', level: null, lines: [ r.error ] });
			return;
		}

		/* A source that simply has no output yet is skipped silently: the merged
		   box should contain real log lines only, not per-source "empty"
		   placeholders (which just added noise). The whole box still shows
		   "Log is empty." when every source is empty. */
		if (r.records.length === 0)
			return;

		for (let i = 0; i < r.records.length; i++) {
			const rec = r.records[i];
			all.push({ si: si, ts: rec.ts, level: rec.level, lines: rec.lines });
		}
	});

	all.sort((a, b) => {
		if (a.ts !== b.ts)
			return (a.ts < b.ts) ? -1 : 1;
		return a.si - b.si;
	});

	return all;
}

/* Filter a merged record list by severity cutoff. Only records whose `level`
   resolves to a weight >= cutoff_weight survive; records with level=null
   (shell logger output, errors, homeproxy, download logs, ...) and records
   whose level token is unknown are always shown, so non-sing-box sources
   are effectively immune to the dropdown. */
function filterByLevel(merged, cutoffWeight) {
	if (cutoffWeight == null)
		return merged;
	return merged.filter((rec) => {
		if (rec.level == null) return true;        /* non-sing-box, keep */
		const w = LEVEL_ORDER[rec.level];
		if (w == null) return true;                 /* unknown token, keep */
		return w >= cutoffWeight;
	});
}

/* Render merged records into the single scrollable box as plain log text.
   The first line of each record is flush; continuation lines are indented. */
function renderLogBox(merged) {
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
		/* No per-source badge: the box shows plain log text. The record's
		   first line is flush, its continuation lines (e.g. sing-box
		   "Caused by:") are indented so the grouping stays readable. */
		box.appendChild(E('div', {
			'class': it.first ? 'hp-log-line' : 'hp-log-line hp-log-cont'
		}, [ it.text === '' ? ' ' : it.text ]));
	}

	if (truncated)
		box.appendChild(E('div', { 'class': 'hp-log-trunc' },
			[ _('… (only the last %s lines are shown)').format(LOG_MAX_LINES) ]));

	return box;
}

/* Build the unified log view (top bar with level switch + one merged box). */
function renderUnifiedLog() {
	/* Log files merged into the single timeline, in merge order. Only the file
	   names matter now that the view renders plain log text without per-source
	   badges. */
	const log_sources = [
		{ file: 'homeproxy' },
		{ file: 'sing-box-c' },
		{ file: 'core_download' },
		{ file: 'panel_download' },
		{ file: 'sing-box-s' }
	];

	const log_level_choices = {
		debug: _('Debug'),
		info:  _('Info'),
		warn:  _('Warn'),
		error: _('Error')
	};

	let selected = uci.get('homeproxy', 'config', 'log_level') || 'info';

	/* Unified log level switcher: writes both the client (config) and the
	   server (server) section so a single control tunes sing-box verbosity,
	   AND immediately triggers a frontend re-filter so the view updates
	   without waiting for the 5 s poll tick. */
	const level_sel = E('select', {
		'id': 'hp_unified_log_level',
		'class': 'cbi-input-select',
		'style': 'margin-left: 4px; width: 7em;',
		'change': ui.createHandlerFn(this, (ev) => {
			const v = ev.target.value;
			selected = v;
			uci.set('homeproxy', 'config', 'log_level', v);
			uci.set('homeproxy', 'server', 'log_level', v);
			/* save+apply restarts sing-box (kernel picks up the new level),
			   but we also re-filter the currently-shown logs right now so
			   the UI reacts instantly; wait for apply to finish afterwards. */
			refresh();
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

	const log_body = E('div', {
		'id': 'log_textarea',
		/* Focusable so a click inside the box gives it focus; without this
		   Ctrl+A never reaches our handler and selects the whole LuCI page. */
		'tabindex': '0'
	},
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}, _('Collecting data...'))
	);

	/* The log box is a <div> (per-line colouring needs markup, which a
	   <textarea> cannot do), so the browser's built-in "select all" climbs to
	   the document and selects the entire page. Handle the shortcut here:
	   Ctrl/Cmd+A while the box has focus selects only the log text. */
	log_body.addEventListener('keydown', function(ev) {
		if (!(ev.ctrlKey || ev.metaKey) || (ev.key !== 'a' && ev.key !== 'A'))
			return;

		ev.preventDefault();
		ev.stopPropagation();

		const selection = window.getSelection();
		const range = document.createRange();
		range.selectNodeContents(log_body);
		selection.removeAllRanges();
		selection.addRange(range);
	});

	/* Copy the whole log as plain text. navigator.clipboard is unavailable
	   over plain http (the usual way LuCI is reached on a LAN address), so
	   fall back to the execCommand path, which works everywhere. */
	function copyLogText() {
		/* innerText preserves the line breaks that block elements (one <div>
		   per log line) render between rows — textContent concatenates them
		   without newlines, which is why copy gave one long line while Ctrl+A
		   (browser-rendered selection) kept the breaks. Fall back to
		   textContent only if innerText is unavailable. */
		const text = (log_body.innerText || log_body.textContent || '').trim();

		if (!text.length)
			return false;

		const scratch = document.createElement('textarea');
		scratch.value = text;
		scratch.setAttribute('readonly', '');
		scratch.style.position = 'fixed';
		scratch.style.top = '-1000px';
		document.body.appendChild(scratch);
		scratch.select();

		let copied = false;
		try {
			copied = document.execCommand('copy');
		} catch (e) {
			copied = false;
		}

		document.body.removeChild(scratch);
		return copied;
	}

	let autoRefresh = true;

	/* Compute the severity cutoff weight from the current dropdown value.
	   null means "show everything" — but the dropdown's options table has
	   entries for debug/info/warn/error only, so in practice cutoff is
	   always set from the dropdown default (info) or the user's pick. */
	function cutoffWeight() {
		return LEVEL_ORDER[selected] != null ? LEVEL_ORDER[selected] : null;
	}

	function refresh() {
		if (!autoRefresh)
			return;

		/* Never clobber a selection: with auto-refresh on, the box is rebuilt
		   every 5 s, which wipes whatever the user selected and makes copying
		   impossible. Skip this tick while a selection lives inside the box. */
		const selection = window.getSelection();
		if (selection && !selection.isCollapsed &&
			log_body.contains(selection.anchorNode))
			return;

		return Promise.all(log_sources.map(readSourceLog))
			.then((results) => {
				let merged = mergeRecords(results);
				merged = filterByLevel(merged, cutoffWeight());
				dom.content(log_body, renderLogBox(merged));
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
					}, [ _('Clean log') ]),
				/* Selecting with Ctrl+A only works while the box has focus,
				   which is easy to miss; this always copies everything. */
				E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, () => {
							const ok = copyLogText();
							ui.addNotification(null,
								E('p', ok ? _('Log copied to clipboard.') : _('Nothing to copy.')),
								ok ? 'info' : 'warning');
						})
					}, [ _('Copy log') ])
			])
			]),
			E('div', { 'class': 'cbi-section' }, [
				log_body,
				E('div', { 'style': 'text-align:right' },
					E('small', {}, [
						_('Refresh every %s seconds.').format(L.env.pollinterval),
						' · ',
						_('Click the log first, then Ctrl+A selects it all.')
					])
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
