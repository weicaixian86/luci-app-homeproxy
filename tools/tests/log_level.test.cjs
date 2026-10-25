/*
 * Filtering of the log view — exercised for real.
 *
 * logview.js is a plain module (`return { ... }`), so it cannot simply be
 * require'd here (LuCI's require is not available in bare node), but its pure
 * part is sliced out and evaluated: the regexes, LEVEL_ORDER, normalizeLevel,
 * normalizeView, shiftTs, splitRecords, mergeRecords and the view filters.
 * Nothing below touches the DOM, rpc or fs, so the slice runs in a bare node
 * process.
 *
 * The point is to pin what each of the four display views actually shows:
 *   all    — everything
 *   event  — our own banner lines (==== … ====) plus result lines
 *   warn   — warnings and anything more severe (Chinese 警告 included)
 *   error  — errors and above (Chinese 错误 / 失败 included)
 * and that a record's continuation lines travel with it.
 *
 * The old "log level" dropdown only knew sing-box's four severities, which left
 * every plugin-written line (no level token at all) immune to filtering — the
 * reason the page looked chaotic. These assertions are what keep the two
 * concepts apart from now on.
 *
 * The code lives in homeproxy/logview.js rather than in the view itself
 * (0.1.28 split the log UI into four pages: 运行日志 / 日志设置 / 插件日志 /
 * 内核日志), and that is the only reason this test reads that file.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const LOGVIEW_JS = path.join(__dirname, '..', '..',
	'luci-app-homeproxy', 'htdocs', 'luci-static', 'resources', 'homeproxy', 'logview.js');

const src = fs.readFileSync(LOGVIEW_JS, 'utf8');

const from = src.indexOf('const TS_RE');
const to = src.indexOf('/* Render merged records');

if (from < 0 || to < 0 || to <= from) {
	console.error('could not locate the pure section of logview.js (TS_RE .. filterByView)');
	process.exit(1);
}

const block = src.slice(from, to);

let api;

try {
	/* fs / _ / run_dir are only referenced by readCoreShift and readSourceLog,
	   which this test never calls; stubs keep the slice evaluable. */
	api = new Function('fs', '_', 'run_dir', block + `
		return { splitRecords, mergeRecords, filterByView, isEventRecord,
		         isWarnRecord, isErrorRecord, normalizeLevel, normalizeView,
		         LEVEL_ORDER, shiftTs };`)({ read_direct: () => Promise.resolve('') }, (s) => s,
		'/var/run/homeproxy');
}
catch (e) {
	console.error('failed to evaluate the extracted block: ' + e.message);
	process.exit(1);
}

const { splitRecords, mergeRecords, filterByView, isEventRecord, isWarnRecord,
	isErrorRecord, normalizeLevel, normalizeView, LEVEL_ORDER, shiftTs } = api;

let failed = 0;
let passed = 0;

function check(desc, got, want) {
	const g = JSON.stringify(got);
	const w = JSON.stringify(want);

	if (g === w) {
		passed++;
		console.log('  ok   ' + desc);
	}
	else {
		failed++;
		console.log('  FAIL ' + desc);
		console.log('         got  ' + g);
		console.log('         want ' + w);
	}
}

/* A realistic slice: sing-box stamps are prefixed with the zone offset, the
   shell logger writes plain lines, and the last ERROR carries an untimestamped
   "Caused by:" continuation.

   The plugin-written half is the one that used to be unfilterable: banner
   lines (==== … ====), a progress line, a warning and two errors — none of
   them carries a level token. */
const SAMPLE = [
	'+0000 2026-10-23 15:35:11 TRACE [111 0.00s] inbound/tun[tun-in]: packet routed',
	'+0000 2026-10-23 15:35:11 DEBUG [111 0.00s] router: match[3] => dns',
	'+0000 2026-10-23 15:35:11 INFO [111 0.01s] outbound/direct[direct]: outbound connection to example.com:443',
	'+0000 2026-10-23 15:35:11 WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'+0000 2026-10-23 15:35:11 ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'  Caused by: read tcp 10.0.0.2:443: connection reset by peer',
	'+0000 2026-10-23 15:35:12 ERROR [114 5.00s] connection: listen packet connection: EOF',
	'+0000 2026-10-23 15:35:12 FATAL [115 0.00s] service: unrecoverable',
	'2026-10-23 23:18:20 ==== 服务启动：命令=reload，触发=LuCI 保存并应用（luci-reload）====',
	'2026-10-23 23:18:21 ==== 规则集预下载开始：来源=「LuCI 保存并应用」，共 21 条，预算 600s ====',
	'2026-10-23 23:18:25 规则集下载进度 45%（第 10/21 条）：geosite-cn',
	'2026-10-23 23:18:30 ==== 规则集预下载结束：来源=「LuCI 保存并应用」，共 21 条，新下载 21，已缓存 0，失败 0 ====',
	'2026-10-23 23:18:31 自动启动：服务已启动（rc=0）。',
	'2026-10-23 23:18:32 警告：本机没有可用的时区数据',
	'2026-10-23 23:18:33 错误：生成客户端配置失败（原因 error: bad json）',
	'2026-10-23 23:18:34 下载失败 geosite-xxx：404。'
].join('\n');

function merged() {
	return mergeRecords([{ src: { file: 'x' }, records: splitRecords(SAMPLE, 0), error: null }]);
}

/* Short label per record: "<level>|" for sing-box lines (level token present),
   "shell|" for plugin lines, followed by the message body. */
function label(rec) {
	const body = rec.lines[0].replace(/^\s*(?:[+-]\d{4}\s+)?\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}\s*/, '');

	return ((rec.level == null) ? 'shell' : rec.level) + '|' + body;
}

function visible(view) {
	return filterByView(merged(), view).map(label);
}

/* "All" hides nothing — including the plugin lines that carry no level token. */
check('all shows every record', visible('all').length, 15);

/* Events: our banners plus the result lines. The progress line and the plain
   severities are NOT events — they are detail, and that detail is exactly
   what used to drown the page. */
check('events view keeps banners and result lines only', visible('event'), [
	'shell|==== 服务启动：命令=reload，触发=LuCI 保存并应用（luci-reload）====',
	'shell|==== 规则集预下载开始：来源=「LuCI 保存并应用」，共 21 条，预算 600s ====',
	'shell|==== 规则集预下载结束：来源=「LuCI 保存并应用」，共 21 条，新下载 21，已缓存 0，失败 0 ====',
	'shell|自动启动：服务已启动（rc=0）。'
]);

check('the progress line is not an event',
	visible('event').some((l) => l.indexOf('下载进度') >= 0), false);

/* Warnings: WARN and above for sing-box, plus 警告 for the plugin. Errors are
   included (a severity ladder), but plain INFO/DEBUG/TRACE are not. */
check('warnings view keeps warn and above (both dialects)', visible('warn'), [
	'warn|WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell|警告：本机没有可用的时区数据',
	'shell|错误：生成客户端配置失败（原因 error: bad json）',
	'shell|下载失败 geosite-xxx：404。'
]);

check('errors view keeps errors and above only', visible('error'), [
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell|错误：生成客户端配置失败（原因 error: bad json）',
	'shell|下载失败 geosite-xxx：404。'
]);

/* The plugin writes 错误/失败 rather than an English token; without the text
   fallback the error view would be empty of plugin errors — the whole reason
   the old level dropdown looked broken. */
check('a plugin error with no level token is still an error',
	isErrorRecord({ level: null, lines: [ '2026-10-23 23:18:33 错误：生成客户端配置失败。' ] }), true);
check('a plugin warning with no level token is still a warning',
	isWarnRecord({ level: null, lines: [ '警告：磁盘可用空间不足' ] }), true);
check('an ordinary info line is neither',
	isErrorRecord({ level: null, lines: [ '规则集下载进度 45%' ] }) ||
	isWarnRecord({ level: null, lines: [ '规则集下载进度 45%' ] }), false);

/* Continuation lines belong to their record: the kept ERROR keeps its
   "Caused by:", and nothing from a dropped record is left behind. */
const all = merged();
const errRec = filterByView(all, 'error')
	.find((rec) => rec.level === 'error' && rec.lines[0].indexOf('dial tcp') >= 0);

check('kept record keeps its Caused by:', errRec ? errRec.lines.length : 0, 2);
check('continuation text preserved', errRec ? errRec.lines[1].trim() : '', 'Caused by: read tcp 10.0.0.2:443: connection reset by peer');

const leftover = filterByView(all, 'error')
	.some((rec) => rec.lines.some((l) => l.indexOf('router: match[3]') >= 0));

check('dropped records leave no continuation behind', leftover, false);

/* Interface notes (the UTC->local explanation) are not log lines: they stay
   in the events view so the explanation is never filtered away, but they must
   not show up as warnings or errors. */
check('a note survives the events view',
	isEventRecord({ note: true, level: null, lines: [ 'x' ] }), true);
check('a note is not a warning nor an error',
	isWarnRecord({ note: true, level: null, lines: [ 'x' ] }) ||
	isErrorRecord({ note: true, level: null, lines: [ 'x' ] }), false);

/* The four view values are exactly what normalizeView lets through, and
   anything else (a hand-edited uci value) falls back to "all" — never to a
   filter the user cannot see in the dropdown. */
check('normalizeView keeps the four offered values',
	['all', 'event', 'warn', 'error'].map(normalizeView),
	['all', 'event', 'warn', 'error']);

check('normalizeView falls back to all for anything else',
	[normalizeView('info'), normalizeView(''), normalizeView(undefined), normalizeView('EVENT')],
	['all', 'all', 'all', 'all']);

/* The core verbosity dropdown is a separate control with its own clamp. */
check('normalizeLevel keeps the four offered values',
	['debug', 'info', 'warn', 'error'].map(normalizeLevel),
	['debug', 'info', 'warn', 'error']);

check('normalizeLevel clamps anything else to info',
	[normalizeLevel('warning'), normalizeLevel('trace'), normalizeLevel(''), normalizeLevel(undefined)],
	['info', 'info', 'info', 'info']);

/* A UTC-stamped core line has to move on both the sort key and the text. */
check('shiftTs moves stamps without touching the browser clock', shiftTs('2026-10-23 15:35:11', 480), '2026-10-23 23:35:11');
check('shiftTs crosses midnight', shiftTs('2026-10-23 20:30:00', 480), '2026-10-24 04:30:00');
check('shiftTs leaves odd shapes alone', shiftTs('2026-10-23T15:35:11Z', 480), '2026-10-23T15:35:11Z');

console.log('');
console.log(failed === 0
	? 'log_level: all ' + passed + ' assertions passed'
	: 'log_level: ' + failed + ' of ' + (passed + failed) + ' assertions FAILED');

process.exit(failed === 0 ? 0 : 1);
