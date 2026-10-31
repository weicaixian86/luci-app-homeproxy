/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

/* 日志页的共用部分：读文件 → 切记录 → 合并成一条时间线 → 过滤 → 渲染成
 * 一个可滚动的框，外加顶栏（自动刷新 / 清空 / 复制）与轮询注册。
 *
 * 0.1.28 之前这一整套都写在 view/homeproxy/log.js 里，只有一屏把六个文件
 * 合并起来的「运行日志」。现在页面里有三个二级选项卡（日志设置 / 插件日志 /
 * 内核日志），两个日志屏各传一份来源清单，于是解析与渲染必须只有一份：两份
 * 拷贝意味着以后改一次解析规则要记得改两处，而忘掉的那一处不会有任何报错
 * —— 它只会安静地显示错的东西。
 */

'use strict';
'require baseclass';
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
/* 单位只有 KB / MB 两档（0.1.28 按用户要求去掉 GB：一个放在 /var/run 内存盘
   上的日志不需要 GiB 级阈值，那个档位只会引出「GB 只能填 1」这种解释）。
   这张表是前端的唯一口径，rpcd 与 clean_log.sh 里各有一份等价的换算，改档位
   要三处一起改。 */
const UNIT_BYTES = { KB: 1024, MB: 1024 * 1024 };
const UNIT_KEYS = [ 'KB', 'MB' ];
/* 数字一律 1–999，所以能设 1 KB – 999 MB。这是**每个日志文件各自**的阈值：
   clean_log.sh 的 rotate_log 对每个文件单独比大小、单独轮转，六个都涨满才会
   占到 6 倍，不是六份合计。 */
const SIZE_MIN = 1;
const SIZE_MAX = 999;

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

/* 数字框能填的范围：KB 与 MB 都是 1–999（单位不再影响范围）。 */
function sizeRange() {
	return { min: SIZE_MIN, max: SIZE_MAX };
}

/* Accepts whatever the backend (or a hand-edited log.conf) hands over and
   returns values the UI can render without further checks. */
function normalizeSettings(raw) {
	const s = raw || {};

	return {
		refresh: clampInt(s.refresh, REFRESH_MIN, REFRESH_MAX, DEFAULT_SETTINGS.refresh),
		size:    clampInt(s.size, SIZE_MIN, SIZE_MAX, DEFAULT_SETTINGS.size),
		unit:    normalizeUnit(s.unit)
	};
}

function settingsBytes(s) {
	const size = clampInt(s.size, SIZE_MIN, SIZE_MAX, DEFAULT_SETTINGS.size);

	return size * UNIT_BYTES[normalizeUnit(s.unit)];
}

/* Human form of the byte budget, used by the settings page. 最大只到 999 MB，
   所以没有 GB 分支（单位档位里也没有 GB 了）。 */
function formatBytes(bytes) {
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
   different weight, so clamp it the same way the generators do — including the
   default: warn, because info logs every single connection onto a tmpfs. */
function normalizeLevel(v) {
	return (v === 'debug' || v === 'info' || v === 'warn' || v === 'error')
		? v : 'warn';
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

			/* 正文 = 时间戳之后的部分，并掐掉 sing-box 那个**裸的**级别
			   token（`INFO router: …` → `router: …`）。级别不靠正文里的英文
			   单词表示，统一由渲染时补上的 `时间戳 [INFO] 正文` 前缀承担：
			   插件自己的四份日志（主日志 / 三份下载日志）行里根本没有级别
			   token，只有把级别做成前缀，内核日志与插件日志的格式才对得齐。
			   "+0000 " 这个 Go 的时区前缀在 m[0] 里，跟着一起丢掉了。
			   时间戳也不再拼进正文：UTC 换算只改 rec.ts 一处（以前还要回头
			   在正文里 replace 一遍，漏一处就出现「排序本地时间、显示 UTC」）。 */
			const rest = tail.slice(lm ? lm[0].length : 0).replace(/^[ \t]+/, '');
			let ts = m[1] + ' ' + m[2];

			if (shift) {
				const moved = shiftTs(ts, shift);
				if (moved !== ts)
					ts = moved;
			}

			cur = {
				ts:    ts,
				level: levelTok,           /* null = non-sing-box, always shown */
				lines: [ rest ]
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

/* ── 严重性判定：一条记录算警告还是错误 ─────────────────────────────────────
   0.1.28 末版起**只用于上色和 [级别] 标记，不再用于过滤**：两个日志屏都是
   「原样看全部」（用户明确要求插件日志也不过滤，原「显示：」下拉已删除），
   但警告行琥珀、错误行红仍靠这两位判定。
   插件日志行里没有级别 token，所以除了 token 还要按中文关键字判，否则插件
   的告警永远不会被染色。 */
function isWarnRecord(rec) {
	/* warn 及更严重都算。level 为 null（插件日志）时 LEVEL_ORDER[...] 是
	   undefined，比较为 false，落到下面的文本判定。 */
	if (LEVEL_ORDER[rec.level] >= LEVEL_ORDER.warn)
		return true;

	return rec.lines.some((l) => /警告|\bWARN(ING)?\b/i.test(l));
}

function isErrorRecord(rec) {
	if (LEVEL_ORDER[rec.level] >= LEVEL_ORDER.error)
		return true;

	/* 插件日志用中文写严重性：「错误：…」「下载失败 …」。只认英文 token 的话，
	   插件错误永远染不上红色。
	   ⚠️ `失败(?!\s*\d)` 这个负向前瞻是必须的：结束横幅里那句
	   「…已缓存 0，失败 0」是**统计**，不是错误；写成 `失败` 会把每一次成功
	   的预下载都标成错误，「错误」视图反而被成功记录淹没。
	   「错误」要求紧跟冒号，避免把「HTML 错误页」这类描述性文字算进来。 */
	/* `Failed\b`（大写开头）只为读失败的提示行：`Failed to read x.log: …`
	   在 .lmo 没加载时是英文原文，用中文关键字判不到，会被标成 [INFO]。
	   不能加 /i —— 小写的 "failed" 常出现在正文描述里（sing-box 那行
	   "dns: lookup failed" 本身就带 WARN token，不需要靠文本兜）。 */
	return rec.lines.some((l) => /错误[:：]|失败(?!\s*\d)|\bERROR\b|\bFATAL\b|\bPANIC\b/i.test(l))
		|| rec.lines.some((l) => /Failed\b/.test(l));
}

/* 一条记录该画成什么颜色。**只用于上色与 [级别] 标记，不参与过滤**（0.1.28
   末版起没有任何显示过滤器了）。顺序不能反：isWarnRecord 对 error 级也返回
   true（warn 是「warn 及以上」），先判 error 才不会把报错画成琥珀色。 */
function recordSeverity(rec) {
	if (isErrorRecord(rec))
		return 'error';

	if (isWarnRecord(rec))
		return 'warn';

	return null;
}

/* 一条记录前面那个方括号级别标记。
   内核行带真 token（INFO / WARN / ERROR …）就直接用它；插件自己的日志行里
   没有 token，按**与上色同一套**判定推出来（先 error 再 warn，其余 info）
   —— 于是不会出现「这行是红的，标记却写着 [INFO]」。
   方括号补到 7 个字符再空一格，是为了让 [INFO] 和 [ERROR] 后面的正文从同
   一列开始：等宽字体下差一个字符看着就像排版坏了。 */
function recordTag(rec) {
	if (rec.level && LEVEL_ORDER[rec.level] !== undefined)
		return rec.level === 'warning' ? 'WARN' : rec.level.toUpperCase();

	const sev = recordSeverity(rec);

	return (sev === 'error') ? 'ERROR' : (sev === 'warn' ? 'WARN' : 'INFO');
}

/* `[INFO]  ` / `[ERROR] ` —— 带补齐的级别标记（含尾随空格）。 */
function tagPrefix(rec) {
	const t = '[' + recordTag(rec) + ']';

	return ((t.length < 7) ? t + ' ' : t) + ' ';
}

/* 记录的首行：`YYYY-mm-dd HH:MM:SS [INFO] 正文`。时间戳与级别标记都在渲染
   时拼，正文里只留内容 —— 这样六份来源（含手写的、老版本留下的、没有级别
   token 的）在界面上是同一个格式。*/
function firstLineOf(rec) {
	const body = (rec.lines[0] === '') ? ' ' : rec.lines[0];

	return (rec.ts ? rec.ts + ' ' : '') + tagPrefix(rec) + body;
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
		/* 配色按**记录**算一次，续行（sing-box 的 "Caused by:"）跟着上色，
		   否则一条 ERROR 只有第一行是红的、堆栈仍是黑的，读起来像两件事。 */
		const sev = recordSeverity(rec);

		for (let j = 0; j < rec.lines.length; j++)
			flat.push({
				si:    rec.si,
				first: (j === 0),
				/* 首行拼上时间戳与级别标记；续行属于上一条记录，只缩进、
				   不重复前缀。 */
				text:  (j === 0) ? firstLineOf(rec) : rec.lines[j],
				sev:   sev
			});
	}

	if (flat.length === 0) {
		box.appendChild(E('div', { 'class': 'hp-log-empty' }, [ emptyText || _('Log is empty.') ]));
		return box;
	}

	for (let i = 0; i < flat.length; i++) {
		const it = flat[i];
		let cls = 'hp-log-line';

		if (!it.first)
			cls += ' hp-log-cont';

		if (it.sev === 'error')
			cls += ' hp-log-error';
		else if (it.sev === 'warn')
			cls += ' hp-log-warn';

		/* No per-source badge: the box shows plain log text. The record's
		   first line is flush, its continuation lines (e.g. sing-box
		   "Caused by:") are indented so the grouping stays readable. */
		box.appendChild(E('div', { 'class': cls }, [ it.text === '' ? ' ' : it.text ]));
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
	gap: 14px;
	/* 只在下方留 8px：顶栏与日志框是一件事，中间不该再有一条空白带。 */
	padding: 0 0 8px;
}
/* 顶栏 + 日志框**同一个容器**。以前顶栏单独是一个 cbi-section、框是另一个，
   两者之间除了 section 的间距，调用方没传 head 时还会留下一条空的带边框
   横条（0.1.28 现场截图里被红框圈出来的那片空白就是它）。这个 class 顺手
   把 section 默认的上下外边距也清掉，让选项卡下面直接就是顶栏。 */
.hp-log-panel {
	margin: 0;
	padding: 0;
	border: none;
	background: none;
}
/* 框底下那行「每 N 秒刷新…」——调用方要的时候才建（o.hint === false 就不建）。 */
.hp-log-hint {
	padding: 6px 0 0;
	text-align: right;
	color: #888;
	font-size: 12px;
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
/* 告警 / 错误的配色。只有前景色、不加背景：整片日志一旦有了底色，时间戳
   的等宽列就对不齐了，而且满屏色块反而看不出哪行更要紧。
   日志框底是固定的白底（.hp-log-scroll），所以用深一档的琥珀与红，
   深色主题下也读得清。判定见 recordSeverity()：插件日志行里没有级别
   token，靠 isWarnRecord / isErrorRecord 的中文关键字兜住。 */
.hp-log-warn {
	color: #b26a00;
}
.hp-log-error {
	color: #c62828;
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
 * @param {boolean} [o.hint]        show the "refreshed every Ns / Ctrl+A" line
 *                                  under the box (default true)
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
			/* 换算在**解析层**完成（readSourceLog 按 shift 挪内核行的时间戳），
			   渲染层不需要它——日志框里不放说明行，也就没有「shift 还得跨
			   回调带过去」这回事。（这个坑踩过：曾经把 shift 漏在另一个回调
			   的作用域外，整个 refresh 抛 ReferenceError，加载圈永远转。） */
			.then((shift) => Promise.all(sources.map((src) => readSourceLog(src, shift))))
			.then((results) => {
				let merged = mergeRecords(results || []);

				if (filter)
					merged = filter(merged);

				/* 日志框里只放日志行，不塞说明段落。
				   曾经有过两条：① 0.1.26 删掉的「最早 / 最新 / 设备时间 +
				   轮转规则」那段（它打印的时间跨度本身就不可信——比对用的
				   设备时间在反馈者的固件上偏了一个时区）；② 0.1.28 删掉的
				   「内核时间戳原为 UTC…已按本地时区换算显示」。两条都别再
				   加回来：换算仍然照做（`readCoreShift()` + `shiftTs`），只是
				   不再声明。
				   文件大小 / 轮转 / 时区这些事实归文档，不归日志框。 */

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

	   轮询本身由 start()/stop() 控制：0.1.28 起四个日志页是同页选项卡，
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

	/* 日志设置里改了刷新间隔：已经建好的面板就地换节奏，不必等下次打开。
	   夹的范围就是设置页允许填的 2–120 秒，别再放一个更宽的口子。 */
	function retune(seconds) {
		registerPoll(clampInt(seconds, REFRESH_MIN, REFRESH_MAX, interval));
	}

	const wanted = (typeof o.interval === 'number')
		? clampInt(o.interval, REFRESH_MIN, REFRESH_MAX, DEFAULT_SETTINGS.refresh) : null;
	const initial = wanted || clampInt(L.env.pollinterval, REFRESH_MIN, REFRESH_MAX, DEFAULT_SETTINGS.refresh);

	interval = initial;

	/* o.hint === false：框底下那行「每 N 秒刷新。· 先点击日志区域…」不显示。
	   两个日志屏都只需要「原样看全部」，这行提示在那里只是噪音（用户 0.1.28
	   明确指出要去掉）。轮询本身不受影响，照旧按设置里的间隔跑。0.1.28 末版
	   合并屏删掉后没有任何一屏传 hint: true，开关留着、默认仍为开。 */
	every = (o.hint === false) ? null : E('small', {}, [
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

	/* 顶栏的孩子必须是**一维**数组。LuCI 的 E() 不会摊平嵌在 children 里的
	   数组——不是节点就一律 `createTextNode(child)`，于是 Array.toString()
	   把每个元素都变成 `[object HTMLDivElement]`，界面上就多出
	   `[object HTMLDivElement],[object HTMLDivElement]` 这一串（0.1.28 现场
	   抓到：o.head 恰好是两个 div）。所以先 concat 成一维再交给 E()。 */
	const topbar = [].concat(o.head || []);

	topbar.push(E('label', { 'style': 'display:flex; align-items:center;' }, [
		auto_cb,
		_('Auto refresh')
	]));
	topbar.push(buttons);

	/* 顶栏与日志框装进**同一个**容器，而且顶栏只在真有控件时才建：
	   - 拆成两个 cbi-section 时，两者之间会多出一层 section 间距；
	   - 一个空的顶栏 div 就是一条带边框的空白横条（0.1.28 现场红框）。
	   现在没有控件就连这个 div 都不建，绝不会留空。 */
	const panel = [];

	if (topbar.length)
		panel.push(E('div', { 'class': 'hp-log-topbar' }, topbar));

	panel.push(box);

	if (every)
		panel.push(E('div', { 'class': 'hp-log-hint' }, every));

	return {
		nodes: [
			E('style', [ css ]),
			E('div', { 'class': 'hp-log-panel' }, panel)
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

/* LuCI 的 require() 只接受**类**：它用 Class.isSubclass() 校验工厂的返回值，
   即必须是 baseclass.extend() 出来的构造器（prototype 继承 baseclass），然后
   new 出一个实例交给调用方。以前这里 `return { … }` 返回普通对象，在旧版
   LuCI 上能跑，在新版上直接报
   `TypeError: "homeproxy.logview" factory yields invalid constructor`
   —— 日志页整页打不开。
   本模块只是函数集合、内部不用 this，所以做成类不影响任何调用方式：
   require('homeproxy.logview') 拿到的仍是「有这些方法的对象」。

   两条路取同一个基类：优先用注入进来的 baseclass，取不到就用 L.Class。
   原因是包里的 JS 是**压缩过的单行**（构建时 uglify，不是我们压的），
   `'require baseclass';` 这种字符串指令在压缩后不一定还在、也就不一定会被
   注入；而 `L` 是工厂的固定第三个参数、永远存在，L.Class 是同一个基类
   （LuCI 里 classes.baseclass === Class）。 */
/* typeof 守卫，不能直接写 `baseclass &&` —— 压缩后万一没被注入，未声明的
   标识符直接引用会抛 ReferenceError（typeof 则安全）。 */
const HP_CLASS = (typeof baseclass !== 'undefined' && baseclass
	&& typeof baseclass.extend === 'function') ? baseclass : L.Class;

return HP_CLASS.extend({
	DEFAULT_SETTINGS: DEFAULT_SETTINGS,
	REFRESH_MIN: REFRESH_MIN,
	REFRESH_MAX: REFRESH_MAX,
	UNIT_KEYS: UNIT_KEYS,
	UNIT_BYTES: UNIT_BYTES,
	SIZE_MIN: SIZE_MIN,
	SIZE_MAX: SIZE_MAX,
	sizeRange: sizeRange,

	normalizeLevel: normalizeLevel,
	normalizeSettings: normalizeSettings,
	normalizeUnit: normalizeUnit,
	settingsBytes: settingsBytes,
	formatBytes: formatBytes,
	clampInt: clampInt,
	zh: zh,

	splitRecords: splitRecords,
	mergeRecords: mergeRecords,
	isWarnRecord: isWarnRecord,
	isErrorRecord: isErrorRecord,
	recordSeverity: recordSeverity,
	shiftTs: shiftTs,

	callSettings: callLogSettings,
	saveSettings: callLogSettingsSave,

	renderPage: renderPage
});
