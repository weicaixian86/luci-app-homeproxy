/*
 * Level filtering of the unified log view — exercised for real.
 *
 * log.js cannot be `require`d (it ends with `return view.extend(...)`, which is
 * only valid inside LuCI's loader wrapper), so the pure part of the module is
 * sliced out and evaluated here: the regexes, LEVEL_ORDER, normalizeLevel,
 * shiftTs, splitRecords, mergeRecords and filterByLevel. Nothing below touches
 * the DOM, rpc or fs, so the slice runs in a bare node process.
 *
 * The point is to pin what each of the four dropdown levels actually shows:
 * which severities survive, that non-sing-box lines are never filtered, and
 * that a record's continuation lines travel with it.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const LOG_JS = path.join(__dirname, '..', '..',
	'luci-app-homeproxy', 'htdocs', 'luci-static', 'resources', 'view', 'homeproxy', 'log.js');

const src = fs.readFileSync(LOG_JS, 'utf8');

const from = src.indexOf('const TS_RE');
const to = src.indexOf('/* Render merged records');

if (from < 0 || to < 0 || to <= from) {
	console.error('could not locate the pure section of log.js (TS_RE .. filterByLevel)');
	process.exit(1);
}

const block = src.slice(from, to);

let api;

try {
	/* fs / _ / hp_dir are only referenced by readCoreShift and readSourceLog,
	   which this test never calls; stubs keep the slice evaluable. */
	api = new Function('fs', '_', 'hp_dir', block + `
		return { splitRecords, mergeRecords, filterByLevel, normalizeLevel,
		         LEVEL_ORDER, shiftTs };`)({ read_direct: () => Promise.resolve('') }, (s) => s,
		'/var/run/homeproxy');
}
catch (e) {
	console.error('failed to evaluate the extracted block: ' + e.message);
	process.exit(1);
}

const { splitRecords, mergeRecords, filterByLevel, normalizeLevel, LEVEL_ORDER, shiftTs } = api;

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
   "Caused by:" continuation. */
const SAMPLE = [
	'+0000 2026-10-23 15:35:11 TRACE [111 0.00s] inbound/tun[tun-in]: packet routed',
	'+0000 2026-10-23 15:35:11 DEBUG [111 0.00s] router: match[3] => dns',
	'+0000 2026-10-23 15:35:11 INFO [111 0.01s] outbound/direct[direct]: outbound connection to example.com:443',
	'+0000 2026-10-23 15:35:11 WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'+0000 2026-10-23 15:35:11 ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'  Caused by: read tcp 10.0.0.2:443: connection reset by peer',
	'+0000 2026-10-23 15:35:12 ERROR [114 5.00s] connection: listen packet connection: EOF',
	'+0000 2026-10-23 15:35:12 FATAL [115 0.00s] service: unrecoverable',
	'2026-10-23 23:18:23 提示：本机没有可用的时区数据',
	'2026-10-23 23:18:24 错误：生成客户端配置失败（原因 error: bad json）'
].join('\n');

function visible(cutoff) {
	const merged = mergeRecords([{ src: { file: 'x' }, records: splitRecords(SAMPLE, 0), error: null }]);
	return filterByLevel(merged, LEVEL_ORDER[cutoff]).map((rec) => {
		if (rec.level == null)
			return 'shell';
		return rec.level + '|' + rec.lines[0].replace(/^\S+ \S+ /, '');
	});
}

/* Severity per level: trace is below the lowest option and must never show,
   fatal/panic are above error and must always show. */
check('debug keeps debug and above, drops trace', visible('debug'), [
	'debug|DEBUG [111 0.00s] router: match[3] => dns',
	'info|INFO [111 0.01s] outbound/direct[direct]: outbound connection to example.com:443',
	'warn|WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell',
	'shell'
]);

check('info keeps info and above', visible('info'), [
	'info|INFO [111 0.01s] outbound/direct[direct]: outbound connection to example.com:443',
	'warn|WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell',
	'shell'
]);

check('warn keeps warn and above', visible('warn'), [
	'warn|WARN [112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell',
	'shell'
]);

/* The shell lines survive even though one of them contains the literal word
   "error": it sits in the message body, not in the level slot, so the record
   is level=null and the dropdown must not hide it. */
check('error keeps error and above, shell lines untouched', visible('error'), [
	'error|ERROR [113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|ERROR [114 5.00s] connection: listen packet connection: EOF',
	'fatal|FATAL [115 0.00s] service: unrecoverable',
	'shell',
	'shell'
]);

/* Continuation lines belong to their record: the kept ERROR keeps its
   "Caused by:", and nothing from a dropped record is left behind. */
const merged = mergeRecords([{ src: { file: 'x' }, records: splitRecords(SAMPLE, 0), error: null }]);
const errRec = filterByLevel(merged, LEVEL_ORDER.error)
	.find((rec) => rec.level === 'error' && rec.lines[0].indexOf('dial tcp') >= 0);

check('kept record keeps its Caused by:', errRec ? errRec.lines.length : 0, 2);
check('continuation text preserved', errRec ? errRec.lines[1].trim() : '', 'Caused by: read tcp 10.0.0.2:443: connection reset by peer');

const leftover = filterByLevel(merged, LEVEL_ORDER.error)
	.some((rec) => rec.lines.some((l) => l.indexOf('router: match[3]') >= 0 || l.indexOf('Caused by:') >= 0 && rec.level !== 'error'));

check('dropped records leave no continuation behind', leftover, false);

/* The four dropdown values are exactly what normalizeLevel lets through. */
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
