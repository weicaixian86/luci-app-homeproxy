/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

/* 日志页的共用部分：读文件 → 切记录 → 合并成一条时间线 → 过滤 → 渲染成
 * 一个可滚动的框，外加顶栏（自动刷新 / 清空 / 复制）与轮询注册。
 *
 * 0.1.28 之前这一整套都写在 view/homeproxy/log.js 里，只有一个「运行日志」
 * 页面。现在页面里有四个选项卡（运行日志 / 日志设置 / 插件日志 / 内核日志），
 * 三种日志视图各传一份来源清单，于是解析与渲染必须只有一份：两份拷贝意味
 * 着以后改一次解析规则要记得改两处，而忘掉的那一处不会有任何报错 —— 它只
 * 会安静地显示错的东西。
 */

'use strict';
'require dom';
'require fs';
'require rpc';
'require ui';

'require homeproxy as hp';

const RUN_DIR = '/var/run/homeproxy';

/* init.d records whether the core actually got a usable timezone in
   CORE_TZ_FILE: "local" when it did, "utc <seconds east of UTC>" when the
   image has no tzdata and sing-box therefore logs in UTC. Go cannot parse
   OpenWrt's POSIX /etc/TZ ("CST-8"), which is what used to leave the core
   eight hours behind every other source — and, because the merged timeline
   sorts on the stamp text, out of order too. */
const CORE_TZ_FILE = RUN_DIR + '/core_tz';

/* ── 日志设置 ────────────────────────────────────────────────────────────────
   存在 /etc/homeproxy/log.conf 而不是 uci：这不是服务配置，改它不该重启内核。
   uci commit 会改 /etc/config/homeproxy 的 mtime → procd 的 config.change
   触发器 → reload_service（= stop + start，所有连接断一次）。为了一个刷新
   间隔去重启隧道显然不能接受，所以单独放一个文件，界面与 clean_log.sh
   各读一次，两边用的是同一份阈值。 */
const DEFAULT_SETTINGS = { refresh: 5, size: 1, unit: 'MB' };
const REFRESH_MIN = 2;
const REFRESH_MAX = 120;
/* 单位只有 KB / MB / GB 三档（与设计稿的下拉一致）。这张表是前端的唯一
   口径，rpcd 与 clean_log.sh 里各有一份等价的换算，改档位要三处一起改。 */
const UNIT_BYTES = { KB: 1024, MB: 1024 * 1024, GB: 1024 * 1024 * 1024 };
const UNIT_KEYS = [ 'KB', 'MB', 'GB' ];
/* 下界 64 KiB：把上限设成 0 或几 KB 会让日志一行都留不下。
   上界 1 GiB：/var/run 是内存盘，六个日志文件共用一个阈值，填得更大只会
   把内存吃光。所以「GB」这一档实际只能填 1——数字框的上限是按单位算出来的
   （见 sizeRange），不是写死的 1024。 */
const MIN_BYTES = 64 * 1024;
const MAX_BYTES = 1024 * 1024 * 1024;

const callLogClean = rpc.declare({
	object: 'luci.homeproxy',
	method: 'log_clean',
	params: ['type'],
	expect: { '': {} }
});

const callLogSettings = rpc.declare({
	object: 'luci.homeproxy',
	method: 'log_settings'
});

const callLogSettingsSave = rpc.declare({
	object: 'luci.homeproxy',
	method: 'log_settings_save',
	params: ['refresh', 'size', 'unit']
});

function clampInt(v, lo, hi, dflt) {
	const n = parseInt(v, 10);

	if (!isFinite(n))
		return dflt;

	return (n < lo) ? lo : ((n > hi) ? hi : n);
}

/* 界面文案的中文兜底。`_()` 只在 homeproxy 的 .lmo 被加载时才翻译，否则
   原样返回英文 msgid —— 于是「内核日志级别」下拉里直接冒出 Debug / Info /
   Warn / Error（这四个词 luci-base 里也有同名条目，靠继承不保险）。
   面板文案要求全中文，所以再压一层：翻译没命中就用内置中文名。
   en 用来判断「到底命中没有」；translated 必须是对 _() 的直接字面量调用，
   而不是把变量传进去，否则 Rescan-Translation 提取不到 msgid，po 里的
   条目会被当成死条目清掉。（注意注释里也别写带引号的 _() 调用：pocheck
   把整份源码当文本扫，会把它当成一个真的 msgid 去 po 里找。） */
function zh(en, translated, fallback) {
	return (translated && translated !== en) ? translated : fallback;
}

function normalizeUnit(u) {
	const s = String(u || '').toUpperCase();

	return (UNIT_KEYS.indexOf(s) >= 0) ? s : DEFAULT_SETTINGS.unit;
}

/* 当前单位下数字框能填的范围：换算成字节后必须落在 [64 KiB, 1 GiB] 里。
   KB 的下限是 64（= 64 KiB），MB 是 1，GB 的上限是 1（= 1 GiB）。 */
function sizeRange(unit) {
	const u = normalizeUnit(unit),
	      hi = Math.floor(MAX_BYTES / UNIT_BYTES[u]),
	      lo = (u === 'KB') ? Math.ceil(MIN_BYTES / UNIT_BYTES[u]) : 1;

	return { min: lo, max: (hi < lo) ? lo : hi };
}

/* Accepts whatever the backend (or a hand-edited log.conf) hands over and
   returns values the UI can render without further checks. */
function normalizeSettings(raw) {
	const s = raw || {};
	const unit = normalizeUnit(s.unit);
	const r = sizeRange(unit);

	return {
		refresh: clampInt(s.refresh, REFRESH_MIN, REFRESH_MAX, DEFAULT_SETTINGS.refresh),
		size:    clampInt(s.size, r.min, r.max, r.min),
		unit:    unit
	};
}

function settingsBytes(s) {
	const bytes = s.size * UNIT_BYTES[normalizeUnit(s.unit)];

	if (bytes < MIN_BYTES)
		return MIN_BYTES;

	if (bytes > MAX_BYTES)
		return MAX_BYTES;

	return bytes;
}

/* Human form of the byte budget, used by the settings page. */
function formatBytes(bytes) {
	if (bytes >= UNIT_BYTES.GB)
		return _('%s GB').format(Math.round(bytes / UNIT_BYTES.GB * 100) / 100);

	if (bytes >= UNIT_BYTES.MB)
		return _('%s MB').format(Math.round(bytes / UNIT_BYTES.MB * 100) / 100);

	if (bytes >= UNIT_BYTES.KB)
		return _('%s KB').format(Math.round(bytes / UNIT_BYTES.KB));

	return _('%s bytes').format(bytes);
}

/* Leading "YYYY-MM-DD HH:MM:SS" of a log line. An optional "+0800"-style
   zone prefix is tolerated because some sing-box builds emit it. Accepts
   both sing-box (YYYY-MM-DD HH:MM:SS / YYYY/MM/DD HH:MM:SS) and Go log default
   forms so we can split the stream into timestamped records first. The level
   token is extracted separately (see LEVEL_TOKEN_RE below) so that shell-script
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

/* Only the four levels offered by the dropdown are meaningful here. A value
   hand-edited into uci (or carried over from an older config) would otherwise
   leave the <select> showing its first option while the filter cut at a
   different weight, so clamp it the same way the generators do. */
function normalizeLevel(v) {
	return (v === 'debug' || v === 'info' || v === 'warn' || v === 'error')
		? v : 'info';
}

/* Shift a "YYYY-MM-DD HH:MM:SS" stamp by N minutes. Pure UTC arithmetic, so
   the browser's own timezone and DST never enter the result. Returns the
   input untouched when it does not look like a full stamp. */
function shiftTs(ts, minutes) {
	const m = /^(\d{4})[-/](\d{2})[-/](\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/.exec(ts);
	if (!m)
		return ts;

	const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) + minutes * 60000);
	const p = (n) => (n < 10 ? '0' : '') + n;

	return d.getUTCFullYear() + '-' + p(d.getUTCMonth() + 1) + '-' + p(d.getUTCDate()) +
	       ' ' + p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + ':' + p(d.getUTCSeconds());
}

/* "+08:00" for a signed minute count (used in the notice text). */
function fmtOffset(minutes) {
	const p = (n) => (n < 10 ? '0' : '') + n;
	const a = Math.abs(minutes);
	return (minutes < 0 ? '-' : '+') + p(Math.floor(a / 60)) + ':' + p(a % 60);
}

/* Minutes the core's stamps have to move to land on the local clock; 0 when
   they already are (or when the marker is missing, i.e. an older install). */
function readCoreShift() {
	return fs.read_direct(CORE_TZ_FILE, 'text')
		.then((res) => {
			const parts = String(res || '').trim().split(/\s+/);
			if (parts[0] !== 'utc')
				return 0;
			const off = parseInt(parts[1], 10);
			return isFinite(off) ? Math.round(off / 60) : 0;
		})
		.catch(() => 0);
}

/* Split one log file into records: a timestamped line plus the untimestamped
   continuation lines that follow it (e.g. sing-box "Cause:" / stack traces).
   Keeping records intact means multi-line entries survive the merge.

   Records that look like sing-box output (a level token appears immediately
   after the timestamp) get a `level` (lowercase) tagged on the record;
   records from shell logger (homeproxy, core_download, panel_download) have
   timestamps but no such token → `level: null` and are always shown when the
   frontend applies its severity filter. */
function splitRecords(text, shift) {
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
			let body = line.replace(/^\s*[+-]\d{4}\s+/, '');
			let ts = m[1] + ' ' + m[2];

			/* Core stamped in UTC: move both the sort key AND the rendered
			   text. Shifting only the key would leave a row reading 15:17
			   sitting between 23:1x rows. */
			if (shift) {
				const moved = shiftTs(ts, shift);
				if (moved !== ts) {
					body = body.replace(m[1], moved.slice(0, m[1].length))
					           .replace(m[2], moved.slice(m[1].length + 1));
					ts = moved;
				}
			}

			cur = {
				ts:    ts,
				level: levelTok,           /* null = non-sing-box, always shown */
				lines: [ body ]
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
function readSourceLog(src, shift) {
	return fs.read_direct(String.format('%s/%s.log', RUN_DIR, src.file), 'text')
	.then((res) => {
		const text = String(res || '').replace(/\r\n/g, '\n').trim();
		/* Only the core's own log can be on a foreign clock; the shell
		   scripts always stamp with BusyBox date (local). */
		return { src: src, records: text ? splitRecords(text, src.core ? shift : 0) : [], error: null };
	})
	.catch((err) => {
		/* A file that was never written (service not started yet, panel never
		   updated, ...) is simply absent, which is the normal state of half
		   the sources — it must NOT add a row. Six sources would otherwise
		   open the box with a stack of identical "Log file does not exist."
		   notices that do not even say which file is missing, and the reader
		   reads them as log lines produced by the plugin. A real failure
		   (permission denied, I/O error) is worth a row, and it names the
		   file so it can be acted on. */
		const missing = err.toString().includes('NotFoundError');
		return {
			src: src,
			records: [],
			error: missing ? null : _('Failed to read %s: %s').format(src.file + '.log', err)
		};
	});
}

/* Merge records from every source into one chronological list. Each item is
   { si, ts, level, lines }, where si indexes the source list. Records with a
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

/* ── 显示视图：想看什么 ────────────────────────────────────────────────────
   sing-box 的四个级别只对内核日志有效：插件自己的日志（主日志、三份下载
   日志）**行里根本没有级别 token**，按级别过滤对它们完全无效，于是选
   「错误」时屏幕上照样是满屏下载进度和规则集明细 —— 这就是「日志级别显示
   非常乱」的根因。
   现在把两件事彻底分开：
     · 显示视图（全部 / 事件 / 警告 / 错误）：纯前端过滤，不写服务配置、
       不重启内核，选择记在 `config.log_view`；
     · 内核输出级别（debug / info / warn / error）：仍是 sing-box 的
       verbosity，写 `config.log_level` + `server.log_level`，需保存并应用。
   插件日志没有级别 token，所以「警告 / 错误」除了看 token 还要按中文关键字
   判定，否则这两个视图里会一条插件告警都筛不出来。
   「插件日志 / 内核日志」两个页面不带任何过滤：那两个页面存在的意义就是
   「原样看全部」，加过滤器等于把它们变回运行日志。 */
const VIEW_KEYS = { all: 0, event: 1, warn: 2, error: 3 };

function normalizeView(v) {
	return (v === 'event' || v === 'warn' || v === 'error' || v === 'all') ? v : 'all';
}

/* 事件：0.1.27 起所有事件都写成统一横幅（==== 服务启动/停止/重载 ====、
   ==== 规则集预下载开始/结束 ====、==== 订阅更新开始 ====、==== 规则集定时
   更新开始/结束 ====、==== 脚本启动 ====）。少数结果行不是横幅但同样属于
   事件（内核已启动、服务已停止、自动启动…），用一组显式动词兜住。
   `让路`/`跳过下载` 也算事件：它们是「这次没做」的结论，不是告警。 */
const EVENT_LINE_RE = /====|已启动|已停止|已退出|已更新|已下载|已清除|已注册|已完成|下载成功|更新结束|自动启动|让路|跳过下载|预下载完成/;

function isEventRecord(rec) {
	/* 界面自己的提示（内核 UTC→本地 换算）永远保留，它不是日志行。 */
	if (rec.note)
		return true;

	return rec.lines.some((l) => EVENT_LINE_RE.test(l));
}

function isWarnRecord(rec) {
	if (rec.note)
		return false;

	/* 分级语义：warn 视图包含 warn 及更严重的。level 为 null（插件日志）时
	   LEVEL_ORDER[...] 是 undefined，比较为 false，落到下面的文本判定。 */
	if (LEVEL_ORDER[rec.level] >= LEVEL_ORDER.warn)
		return true;

	return rec.lines.some((l) => /警告|\bWARN(ING)?\b/i.test(l));
}

function isErrorRecord(rec) {
	if (rec.note)
		return false;

	if (LEVEL_ORDER[rec.level] >= LEVEL_ORDER.error)
		return true;

	/* 插件日志用中文写严重性：「错误：…」「下载失败 …」。只认英文 token 的话，
	   选「错误」视图会一条插件错误都看不到。
	   ⚠️ `失败(?!\s*\d)` 这个负向前瞻是必须的：结束横幅里那句
	   「…已缓存 0，失败 0」是**统计**，不是错误；写成 `失败` 会把每一次成功
	   的预下载都标成错误，「错误」视图反而被成功记录淹没。
	   「错误」要求紧跟冒号，避免把「HTML 错误页」这类描述性文字算进来。 */
	return rec.lines.some((l) => /错误[:：]|失败(?!\s*\d)|\bERROR\b|\bFATAL\b|\bPANIC\b/i.test(l));
}

function filterByView(merged, view) {
	if (view === 'event')
		return merged.filter(isEventRecord);
	if (view === 'warn')
		return merged.filter((rec) => isWarnRecord(rec) || isErrorRecord(rec));
	if (view === 'error')
		return merged.filter(isErrorRecord);

	return merged;   /* all — and any unknown key falls back to showing everything */
}

/* Render merged records into the single scrollable box as plain log text.
   The first line of each record is flush; continuation lines are indented.

   ⚠️ 这里**不按条数截断**（0.1.28 用户明确要求）。旧实现把显示砍到 1000 行
   并补一句红字「…（只显示最后 N 行）」，结果是文件里明明有更早的记录、界面上
   却看不到，而「能看多少」这件事和「文件能长多大」被拆成了两个互不相干的
   数字。现在只有一个上限：日志文件本身的大小（日志设置里可改，clean_log.sh
   轮转时按它执行）。文件里有几行就显示几行。 */
function renderLogBox(merged, emptyText) {
	const box = E('div', { 'class': 'hp-log-scroll' });
	const flat = [];

	for (let i = 0; i < merged.length; i++) {
		const rec = merged[i];
		for (let j = 0; j < rec.lines.length; j++)
			flat.push({ si: rec.si, first: (j === 0), text: rec.lines[j], note: (rec.note === true) });
	}

	if (flat.length === 0) {
		box.appendChild(E('div', { 'class': 'hp-log-empty' }, [ emptyText || _('Log is empty.') ]));
		return box;
	}

	for (let i = 0; i < flat.length; i++) {
		const it = flat[i];
		/* No per-source badge: the box shows plain log text. The record's
		   first line is flush, its continuation lines (e.g. sing-box
		   "Caused by:") are indented so the grouping stays readable. */
		box.appendChild(E('div', {
			'class': it.note ? 'hp-log-line hp-log-note'
			                 : (it.first ? 'hp-log-line' : 'hp-log-line hp-log-cont')
		}, [ it.text === '' ? ' ' : it.text ]));
	}

	return box;
}

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
/* One merged log box with its own scrollbar: all sources share this
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
.hp-log-empty {
	padding: 16px 12px;
	color: #888;
}
/* One-off notice above the merged log (e.g. core timestamps were UTC and have
   been converted). Sits inside the box so it scrolls away with the content. */
.hp-log-note {
	color: #b06a00;
	font-weight: 600;
	padding: 2px 10px 6px;
}
`;

/* Copy the whole log as plain text. navigator.clipboard is unavailable over
   plain http (the usual way LuCI is reached on a LAN address), so fall back to
   the execCommand path, which works everywhere. */
function copyLogText(node) {
	/* innerText preserves the line breaks that block elements (one <div>
	   per log line) render between rows — textContent concatenates them
	   without newlines, which is why copy gave one long line while Ctrl+A
	   (browser-rendered selection) kept the breaks. Fall back to
	   textContent only if innerText is unavailable. */
	const text = (node.innerText || node.textContent || '').trim();

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
	}
	catch (e) {
		copied = false;
	}

	document.body.removeChild(scratch);
	return copied;
}

/**
 * Build one log panel (one tab of the log page).
 *
 * @param {object} ctx              LuCI view context (for ui.createHandlerFn)
 * @param {object} o
 * @param {string} o.key            stable poll key, one per panel
 * @param {Array}  o.sources        [{ file, core? }] — what this panel shows
 * @param {Array}  [o.head]         extra controls rendered before 自动刷新
 * @param {function} [o.filter]     (merged) => merged, re-applied on every tick
 * @param {string} [o.empty]        text for the "nothing to show" state
 * @param {string} [o.box_id]       element id of the box (default log_textarea)
 * @param {boolean} [o.lazy]        do not poll until start() is called
 * @returns {object} { nodes, refresh, start, stop, box } — the caller must
 *                   mount `nodes` and call start() when the panel is shown
 */
function renderPage(ctx, o) {
	const sources = o.sources || [];
	const filter = o.filter || null;
	const emptyText = o.empty || _('Log is empty.');
	const boxId = o.box_id || 'log_textarea';
	const hasCore = sources.some((s) => s.core === true);
	const cleanList = sources.map((s) => s.file);

	let autoRefresh = true;

	const box = E('div', {
		'id': boxId,
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
	box.addEventListener('keydown', function(ev) {
		if (!(ev.ctrlKey || ev.metaKey) || (ev.key !== 'a' && ev.key !== 'A'))
			return;

		ev.preventDefault();
		ev.stopPropagation();

		const selection = window.getSelection();
		const range = document.createRange();
		range.selectNodeContents(box);
		selection.removeAllRanges();
		selection.addRange(range);
	});

	/* Scroll state of the merged box. Rebuilding the box on every poll tick
	   empties the scroller first, so the browser clamps scrollTop back to 0
	   and the reader lands on the oldest line right after a refresh — while
	   the newest lines, the ones worth watching, sit at the bottom. Remember
	   where we were: follow the tail while the reader is at the tail,
	   otherwise leave their position untouched. */
	function scrollState() {
		const s = box.querySelector('.hp-log-scroll');

		if (!s)
			return { follow: true, top: 0 };

		return {
			follow: (s.scrollHeight - s.scrollTop - s.clientHeight) < 24,
			top: s.scrollTop
		};
	}

	function restoreScroll(state) {
		const s = box.querySelector('.hp-log-scroll');

		if (!s)
			return;

		s.scrollTop = state.follow ? s.scrollHeight : state.top;
	}

	/* `force` re-renders even when auto refresh is off: switching a filter
	   must re-apply to what is already on screen, and that is a one-shot user
	   action rather than a poll tick. */
	function refresh(force) {
		if (!autoRefresh && force !== true)
			return;

		/* Never clobber a selection: with auto-refresh on, the box is rebuilt
		   every few seconds, which wipes whatever the user selected and makes
		   copying impossible. Skip this tick while a selection lives inside
		   the box. */
		const selection = window.getSelection();
		if (selection && !selection.isCollapsed &&
			box.contains(selection.anchorNode))
			return;

		const scroll = scrollState();

		return readCoreShift()
			/* The shift has to travel to the render step below, which is a
			   separate callback: resolving with only the source reads here
			   leaves `shift` out of scope there and the whole refresh dies
			   with a ReferenceError, leaving the spinner on screen forever.
			   Carry it inside the resolved snapshot instead. */
			.then((shift) => Promise.all(sources.map((src) => readSourceLog(src, shift)))
				.then((results) => ({
					shift: shift,
					results: results || []
				})))
			.then((snap) => {
				const shift = snap.shift;
				const results = snap.results;
				let merged = mergeRecords(results);

				if (filter)
					merged = filter(merged);

				/* One notice only: the UTC→local explanation, which is there
				   because the core lines would otherwise disagree with
				   logread / SSH. Say it out loud only when the stamps were
				   actually moved and a core line is on screen — a device
				   marker alone is not something to explain.

				   A second notice used to sit in front of the lines, spelling
				   out "oldest / newest / device time" plus the rotation rule.
				   It was removed on request (0.1.26): readers want the log box
				   to contain log lines, not a paragraph about the log box, and
				   the span it printed could not be trusted as a clock check
				   anyway — the device clock it was compared against came out
				   one UTC offset ahead on the reporter's firmware. Do not
				   reintroduce it; the file/rotation facts belong in the docs. */
				const coreLines = results.some((r) => r.src.core === true && r.records.length > 0);

				if (shift && coreLines)
					merged.unshift({
						si: 0, ts: '', level: null, note: true,
						lines: [ _('Kernel log timestamps were in UTC (this device has no time zone data); they are shown converted to local time (%s).').format(fmtOffset(shift)) ]
					});

				dom.content(box, renderLogBox(merged, emptyText));
				restoreScroll(scroll);
			})
			/* A rejected refresh used to leave the "Collecting data..."
			   spinner on screen forever: the box is only replaced on success,
			   so any runtime error inside the chain above looks exactly like
			   "the page never finished loading" — no message, nothing to act
			   on. Say what broke instead, in the same box. */
			.catch((err) => {
				dom.content(box, E('div', { 'class': 'hp-log-empty' }, [
					_('Failed to load the log: %s').format(err && err.message ? err.message : err)
				]));
			});
	}

	/* Auto-refresh checkbox: when checked the box reloads on every poll tick;
	   when unchecked the view freezes on the last snapshot. */
	const auto_cb = E('input', {
		'type': 'checkbox',
		'checked': autoRefresh ? '' : null,
		'style': 'margin-left: 4px;',
		'change': ui.createHandlerFn(ctx, (ev) => {
			autoRefresh = ev.target.checked;
			if (autoRefresh)
				refresh();
		})
	});

	/* Two buttons in one group right after 自动刷新. The bar is
	   justify-content: flex-start, so no control may be pushed right. */
	const buttons = E('div', { 'style': 'display:flex; align-items:center; gap:8px;' }, [
		E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(ctx, () => {
					return Promise.all(cleanList.map((file) =>
						L.resolveDefault(callLogClean(file), {})
					)).then(() => {
						/* Re-read right away: without this the box keeps showing
						   the rows that were just deleted until the next poll
						   tick, which reads as "clean does nothing". */
						return refresh(true);
					});
				})
			}, [ _('Clean log') ]),
		/* Selecting with Ctrl+A only works while the box has focus, which is
		   easy to miss; this always copies everything. */
		E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(ctx, () => {
					const ok = copyLogText(box);
					ui.addNotification(null,
						E('p', ok ? _('Log copied to clipboard.') : _('Nothing to copy.')),
						ok ? 'info' : 'warning');
				})
			}, [ _('Copy log') ])
	]);

	/* 刷新间隔来自「日志设置」。它是异步读出来的，而 render() 必须同步返回，
	   所以先用 LuCI 的默认间隔注册轮询，读到设置后再按真实值注册一次 ——
	   hp.pollAdd 会先摘掉同名回调，不会叠成一堆。o.interval 指定时就完全
	   按传进来的值走（测试与将来的调用方要能固定节奏）。

	   轮询本身由 start()/stop() 控制：0.1.29 起四个日志页是同页选项卡，
	   只有当前显示的那一个可以轮询。否则每访问过一个选项卡就多一个定时器，
	   六个日志文件要读四遍 —— 而 /var/run 是内存盘，这些读全是白花的。 */
	let every = null;
	let polling = false;
	let interval = 0;

	function paintEvery() {
		if (every) {
			dom.content(every, [
				_('Refresh every %s seconds.').format(interval),
				' · ',
				_('Click the log first, then Ctrl+A selects it all.')
			]);
		}
	}

	function registerPoll(seconds) {
		interval = seconds;

		if (polling)
			hp.pollAdd(o.key || 'log-refresh', refresh, seconds);

		paintEvery();
	}

	function start() {
		if (polling)
			return null;

		polling = true;
		hp.pollAdd(o.key || 'log-refresh', refresh, interval);
		paintEvery();

		/* 首次显示立刻读一次：LuCI 的第一次 tick 可能还在等一个间隔，
		   那样切过去只能看到「正在收集数据…」的转圈。 */
		return refresh(true);
	}

	function stop() {
		if (!polling)
			return false;

		polling = false;

		return hp.pollRemove(o.key || 'log-refresh');
	}

	/* 日志设置里改了刷新间隔：已经建好的面板就地换节奏，不必等下次打开。 */
	function retune(seconds) {
		registerPoll(clampInt(seconds, 1, 3600, interval));
	}

	const wanted = (typeof o.interval === 'number')
		? clampInt(o.interval, 1, 3600, DEFAULT_SETTINGS.refresh) : null;
	const initial = wanted || clampInt(L.env.pollinterval, 1, 3600, DEFAULT_SETTINGS.refresh);

	interval = initial;

	every = E('small', {}, [
		_('Refresh every %s seconds.').format(initial),
		' · ',
		_('Click the log first, then Ctrl+A selects it all.')
	]);

	/* o.lazy：调用方自己决定什么时候开始轮询（选项卡切过来时）。 */
	if (o.lazy !== true)
		start();

	if (wanted === null) {
		L.resolveDefault(callLogSettings(), null).then((raw) => {
			const s = normalizeSettings(raw);

			if (s.refresh !== initial)
				registerPoll(s.refresh);
		});
	}

	return {
		nodes: [
			E('style', [ css ]),
			E('div', { 'class': 'cbi-map' }, [
				E('div', { 'class': 'cbi-section hp-log-topbar' }, [
					E('div', { 'style': 'display:flex; align-items:center; flex-wrap:wrap; gap:18px;' }, [
						(o.head || []),
						E('label', { 'style': 'display:flex; align-items:center;' }, [
							auto_cb,
							_('Auto refresh')
						]),
						buttons
					])
				]),
				E('div', { 'class': 'cbi-section' }, [
					box,
					E('div', { 'style': 'text-align:right' }, every)
				])
			])
		],
		/* 下拉过滤器的 change 处理器要用它立刻重画：换成下一次轮询要等 5 秒。 */
		refresh: refresh,
		/* 选项卡切换时由调用方开关轮询（o.lazy 为 true 时必须自己调 start）。 */
		start: start,
		stop: stop,
		retune: retune,
		box: box
	};
}

return {
	VIEW_KEYS: VIEW_KEYS,
	DEFAULT_SETTINGS: DEFAULT_SETTINGS,
	REFRESH_MIN: REFRESH_MIN,
	REFRESH_MAX: REFRESH_MAX,
	UNIT_KEYS: UNIT_KEYS,
	UNIT_BYTES: UNIT_BYTES,
	MIN_BYTES: MIN_BYTES,
	MAX_BYTES: MAX_BYTES,
	sizeRange: sizeRange,

	normalizeView: normalizeView,
	normalizeLevel: normalizeLevel,
	normalizeSettings: normalizeSettings,
	normalizeUnit: normalizeUnit,
	settingsBytes: settingsBytes,
	formatBytes: formatBytes,
	clampInt: clampInt,
	zh: zh,

	splitRecords: splitRecords,
	mergeRecords: mergeRecords,
	filterByView: filterByView,
	isEventRecord: isEventRecord,
	isWarnRecord: isWarnRecord,
	isErrorRecord: isErrorRecord,
	shiftTs: shiftTs,

	callSettings: callLogSettings,
	saveSettings: callLogSettingsSave,

	renderPage: renderPage
};
