/*
 * Severity judgement of the log view — exercised for real.
 *
 * logview.js is a LuCI module (`return baseclass.extend({ ... })`), so it cannot
 * simply be require'd here (LuCI's require is not available in bare node), but its pure
 * part is sliced out and evaluated: the regexes, LEVEL_ORDER, normalizeLevel,
 * shiftTs, splitRecords, mergeRecords and the severity predicates.
 * Nothing below touches the DOM, rpc or fs, so the slice runs in a bare node
 * process.
 *
 * The point is to pin which records count as warnings/errors: colouring
 * (hp-log-warn / hp-log-error) and the [LEVEL] tag both derive from these
 * predicates, so a red row must also carry [ERROR] — and the 「失败 0」 summary
 * line must be neither. 0.1.28 末版删掉了「显示：」下拉（两个日志屏都不过滤、
 * 原样全出），filterByView / isEventRecord / normalizeView 随之删除；这里固定
 * 的是留下来的上色口径。
 *
 * The code lives in homeproxy/logview.js rather than in the view itself
 * (the log UI is one page with three sub-tabs: 日志设置 / 插件日志 / 内核日志),
 * and that is the only reason this test reads that file.
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
		return { splitRecords, mergeRecords,
		         isWarnRecord, isErrorRecord, normalizeLevel,
		         LEVEL_ORDER, shiftTs };`)({ read_direct: () => Promise.resolve('') }, (s) => s,
		'/var/run/homeproxy');
}
catch (e) {
	console.error('failed to evaluate the extracted block: ' + e.message);
	process.exit(1);
}

const { splitRecords, mergeRecords, isWarnRecord, isErrorRecord,
	normalizeLevel, LEVEL_ORDER, shiftTs } = api;

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

   The plugin-written half carries no level token at all: banner lines
   (==== … ====), a progress line, a warning and two errors — severity for
   those is judged by content (警告/错误/失败 keywords). */
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
   "shell|" for plugin lines, followed by the message body.
   0.1.28 起正文里**没有**时间戳，也没有那个裸的级别 token —— 两样都在渲染
   时由 logview 统一补成 `<时间戳> [INFO] 正文`。所以这里的 label 只用
   rec.level 判级别，body 就是纯内容（上面那句 replace 现在是无害的兜底）。 */
function label(rec) {
	const body = rec.lines[0].replace(/^\s*(?:[+-]\d{4}\s+)?\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}\s*/, '');

	return ((rec.level == null) ? 'shell' : rec.level) + '|' + body;
}

/* 严重性判定只服务上色与 [级别] 标记（0.1.28 末版已无过滤器），断言改成：
   谁是 warn、谁是 error、统计行两者都不是；续行跟着首行一条记录。 */
const all = merged();
const warnSet = all.filter(isWarnRecord).map(label);
const errSet = all.filter(isErrorRecord).map(label);

/* WARN and above, both dialects: sing-box token + 中文关键字。INFO/DEBUG/TRACE
   与普通进度行都不算。 */
/* ⚠️ warn 集合**不含**中文「错误/失败」行：isWarnRecord 只认 warn 及以上
   的 token 与「警告」关键字（error 级的 token 自然在，但插件错误行没有
   token、也不含「警告」二字）——这正是 recordSeverity() 先判 error 的原因：
   中文错误行由 isErrorRecord 接住，不会被漏成「无色」，也不会被错染成
   琥珀。warn 集合因此是「token 达到 warn」∪「文本含警告」。 */
check('warn set is warn-and-above tokens plus 中文警告', warnSet, [
	'warn|[112 0.20s] outbound/proxy[hk]: dns: lookup failed',
	'error|[113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|[114 5.00s] connection: listen packet connection: EOF',
	'fatal|[115 0.00s] service: unrecoverable',
	'shell|警告：本机没有可用的时区数据'
]);
check('the Chinese 错误/失败 rows land in the error set, not warn',
	warnSet.indexOf('shell|错误：生成客户端配置失败（原因 error: bad json）') < 0
	&& errSet.indexOf('shell|错误：生成客户端配置失败（原因 error: bad json）') >= 0, true);

check('error set is errors and above only', errSet, [
	'error|[113 2.40s] outbound/urltest[hk-auto]: dial tcp: connection reset',
	'error|[114 5.00s] connection: listen packet connection: EOF',
	'fatal|[115 0.00s] service: unrecoverable',
	'shell|错误：生成客户端配置失败（原因 error: bad json）',
	'shell|下载失败 geosite-xxx：404。'
]);

/* The plugin writes 错误/失败 rather than an English token; without the text
   fallback plugin errors would never be coloured. */
check('a plugin error with no level token is still an error',
	isErrorRecord({ level: null, lines: [ '2026-10-23 23:18:33 错误：生成客户端配置失败。' ] }), true);
check('a plugin warning with no level token is still a warning',
	isWarnRecord({ level: null, lines: [ '警告：磁盘可用空间不足' ] }), true);
check('an ordinary info line is neither',
	isErrorRecord({ level: null, lines: [ '规则集下载进度 45%' ] }) ||
	isWarnRecord({ level: null, lines: [ '规则集下载进度 45%' ] }), false);
check('the 失败 0 summary line is not an error (statistics, not failure)',
	isErrorRecord({ level: null, lines: [ '==== 规则集预下载结束：共 21 条，新下载 21，已缓存 0，失败 0 ====' ] }), false);
check('but 失败 with a real subject is (失败 geosite-xxx)',
	isErrorRecord({ level: null, lines: [ '下载失败 geosite-xxx：404。' ] }), true);

/* Continuation lines stay with their record: the ERROR that owns a
   "Caused by:" is judged as one record. */
const errRec = all
	.find((rec) => rec.level === 'error' && rec.lines[0].indexOf('dial tcp') >= 0);

check('a record keeps its Caused by:', errRec ? errRec.lines.length : 0, 2);
check('continuation text preserved', errRec ? errRec.lines[1].trim() : '', 'Caused by: read tcp 10.0.0.2:443: connection reset by peer');
check('the record with the continuation is judged as a whole',
	errRec ? isErrorRecord(errRec) : null, true);

/* 0.1.28 删掉了「内核日志时间戳原为 UTC…」这条说明行，于是 logview 里不再
   有任何「不是日志行」的记录：注释掉的那两条 note 断言也随之删除。日志框
   里出现过的一切都得是日志行，这条约定现在靠「无 note 分支」本身保证。 */

/* The core verbosity dropdown keeps its own clamp (it is the only dropdown
   left on the log page). */
check('normalizeLevel keeps the four offered values',
	['debug', 'info', 'warn', 'error'].map(normalizeLevel),
	['debug', 'info', 'warn', 'error']);

/* 兜底是 warn 而不是 info：info 会把每条连接写进 tmpfs 上的内核日志（实测 30 秒
   122 行），没配过级别的新装设备不该默认吃这个。 */
check('normalizeLevel clamps anything else to warn (info floods tmpfs)',
	[normalizeLevel('warning'), normalizeLevel('trace'), normalizeLevel(''), normalizeLevel(undefined)],
	['warn', 'warn', 'warn', 'warn']);

/* A UTC-stamped core line has to move on both the sort key and the text. */
check('shiftTs moves stamps without touching the browser clock', shiftTs('2026-10-23 15:35:11', 480), '2026-10-23 23:35:11');
check('shiftTs crosses midnight', shiftTs('2026-10-23 20:30:00', 480), '2026-10-24 04:30:00');
check('shiftTs leaves odd shapes alone', shiftTs('2026-10-23T15:35:11Z', 480), '2026-10-23T15:35:11Z');

console.log('');
console.log(failed === 0
	? 'log_level: all ' + passed + ' assertions passed'
	: 'log_level: ' + failed + ' of ' + (passed + failed) + ' assertions FAILED');

process.exit(failed === 0 ? 0 : 1);
