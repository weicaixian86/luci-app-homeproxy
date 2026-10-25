/*
 * The log page, rendered for real.
 *
 * homeproxy/logview.js is a plain LuCI module, so its body is evaluated inside
 * a Function with the LuCI modules it needs passed in as stubs, renderPage()
 * is called with a source list, and one poll tick is fired. Nothing here
 * asserts *how* the code is written; it only checks that a poll tick ends with
 * a log box on screen, and that the box holds exactly the records the page is
 * supposed to show.
 *
 * This exists because a `shift` that was left in the closure of a previous
 * `.then` only surfaced at request time: the promise chain rejected with
 * "ReferenceError: shift is not defined", the box kept its initial
 * "Collecting data..." spinner and the page looked like it never loaded. No
 * amount of `node --check` or string matching can catch that — only running it.
 * (0.1.28 removed the cross-callback snapshot that bug lived in: the core
 * offset is consumed while parsing, so the render step never sees `shift`.
 * The rejection path itself still has to be tested — see the unreadable-file
 * case below.)
 *
 * Prints SKIP and exits 0 when jsdom is unavailable (the run.sh wrapper turns
 * that into a `skip` line instead of a failure).
 */

'use strict';

const fs = require('fs');
const path = require('path');

let JSDOM;

try {
	JSDOM = require('jsdom').JSDOM;
}
catch (e) {
	console.log('SKIP jsdom is not installed');
	process.exit(0);
}

const LOGVIEW_JS = path.join(__dirname, '..', '..',
	'luci-app-homeproxy', 'htdocs', 'luci-static', 'resources', 'homeproxy', 'logview.js');

const SAMPLE = [
	'2026-10-24 09:46:40 ==== 规则集预下载开始（共 1 条，预算 600s）====',
	'+0800 2026-10-24 09:54:05 INFO [3784988318 83ms] outbound/vless[hk]: outbound connection to 1.2.3.4:443',
	'2026-10-24 09:54:06 已更新 geosite-cn（431 KB）'
].join('\n');

/* Both pages that are actually mounted pass their own list; the default here
   mirrors 插件日志 so a case can say "this page shows four files". */
const PLUGIN_SOURCES = [
	{ file: 'homeproxy' },
	{ file: 'ruleset_download' },
	{ file: 'core_download' },
	{ file: 'panel_download' }
];

const CORE_SOURCES = [
	{ file: 'sing-box-c', core: true },
	{ file: 'sing-box-s', core: true }
];

let failures = 0;
let checks = 0;

function check(desc, cond, detail) {
	checks++;

	if (cond) {
		console.log('  ok   ' + desc);
	}
	else {
		failures++;
		console.log('  FAIL ' + desc + (detail ? ' — ' + detail : ''));
	}
}

/* LuCI patches both of these in luci.js; without them the view cannot format
   anything (readSourceLog calls String.format with the directory + file). */
if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function () {
		const args = Array.prototype.slice.call(arguments);
		let i = 0;

		return String(this).replace(/%s/g, () => {
			const v = args[i++];
			return (v === undefined || v === null) ? '' : String(v);
		});
	};
}

if (typeof String.format !== 'function') {
	String.format = function (fmt) {
		return String.prototype.format.apply(fmt, Array.prototype.slice.call(arguments, 1));
	};
}

/**
 * Boot one isolated copy of the module.
 *
 * @param {object} opts
 * @param {function} opts.read  (path) => Promise<string>, the fs stub
 * @returns {{ tick: function(): Promise<void>, box: function(): Element }}
 */
function boot(opts) {
	const src = fs.readFileSync(LOGVIEW_JS, 'utf8')
		.replace(/^'use strict';\n/, '')
		.replace(/^'require [^']*';\n/gm, '');

	const dom = new JSDOM('<!doctype html><html><body></body></html>');

	/* The view reads window/document directly (selection, clipboard). */
	global.window = dom.window;
	global.document = dom.window.document;

	let pollFn = null;
	let pollInterval = null;

	/* LuCI's E() has an optional attributes argument: the second argument is
	   treated as children whenever it is not a plain attribute map, so
	   `E('style', [css])` and `E('small', 'text')` are both legal. Getting this
	   wrong is not cosmetic — the naive version iterated the array's indices as
	   attribute names and called setAttribute('0', ...), which newer jsdom
	   rejects with `InvalidCharacterError: "0" did not match the Name
	   production` and older jsdom happens to tolerate. */
	function isAttrsMap(v) {
		return v !== null && typeof v === 'object' &&
			!Array.isArray(v) && !v.nodeType;
	}

	function E(tag, attrs, children) {
		if (Array.isArray(tag)) {
			const frag = document.createDocumentFragment();
			tag.forEach((c) => append(frag, c));
			return frag;
		}

		const el = document.createElement(tag);

		if (attrs !== undefined && attrs !== null && !isAttrsMap(attrs)) {
			/* Second argument was really the first child. */
			children = (children === undefined) ? attrs : [ attrs, children ];
			attrs = null;
		}

		if (attrs)
			for (const k in attrs) {
				if (attrs[k] === null || attrs[k] === undefined)
					continue;
				if (k === 'class')
					el.className = attrs[k];
				else
					el.setAttribute(k, String(attrs[k]));
			}

		if (children !== null && children !== undefined) {
			if (Array.isArray(children))
				children.forEach((c) => append(el, c));
			else
				append(el, children);
		}

		return el;
	}

	function append(parent, c) {
		if (c === null || c === undefined)
			return;

		if (typeof c === 'string' || typeof c === 'number')
			parent.appendChild(document.createTextNode(String(c)));
		else if (Array.isArray(c))
			c.forEach((x) => append(parent, x));
		else
			parent.appendChild(c);
	}

	const settings = opts.settings || { refresh: 5, size: 1, unit: 'MB' };

	const stubs = {
		dom: {
			content: function (node, content) {
				node.textContent = '';
				append(node, content);
			}
		},
		fs: { read_direct: (p) => opts.read(p) },
		rpc: {
			declare: () => () => Promise.resolve(settings)
		},
		ui: {
			createHandlerFn: (ctx, fn) => fn,
			addNotification: () => {}
		},
		hp: {
			installCloseButtonText: () => {},
			pollAdd: (key, fn, interval) => { pollFn = fn; pollInterval = interval; return true; }
		},
		E: E,
		_: (s) => s,
		L: {
			resource: () => 'loading.svg',
			env: { pollinterval: 5 },
			bind: (f, c) => f.bind(c),
			resolveDefault: (p, d) => Promise.resolve(p).catch(() => d)
		}
	};

	/* The module body ends with `return { … }`, so it has to be evaluated
	   inside its own function scope before its exports can be reached. */
	const mod = new Function(...Object.keys(stubs),
		'return (function(){\n' + src + '\n})();').apply(null, Object.values(stubs));
	const renderPage = mod.renderPage;

	const host = document.createElement('div');
	host.id = 'host';

	/* interval is passed explicitly so the settings rpcd call stays out of the
	   picture: this test is about rendering, not about the settings page. */
	const page = renderPage({}, {
		key: 'log-refresh',
		sources: opts.sources || PLUGIN_SOURCES,
		filter: opts.filter,
		empty: opts.empty,
		interval: 5
	});

	append(host, page.nodes);
	document.body.appendChild(host);

	return {
		initial: () => document.querySelector('#log_textarea').textContent.trim(),
		tick: () => {
			if (!pollFn)
				return Promise.reject(new Error('hp.pollAdd() was never called'));

			return Promise.resolve().then(() => pollFn());
		},
		box: () => document.querySelector('#log_textarea'),
		interval: () => pollInterval,
		module: mod
	};
}

function run(name, opts, assertions) {
	console.log(name);

	const view = boot(opts);

	check('the box starts as a loading placeholder',
		view.initial().indexOf('Collecting data') >= 0, JSON.stringify(view.initial()));

	check('the poll interval came from the settings, not a hardcoded 5s',
		view.interval() === 5, String(view.interval()));

	return view.tick()
		.then(() => {
			const box = view.box();

			check('one poll tick replaces the loading placeholder',
				box.querySelectorAll('img').length === 0 &&
				box.textContent.indexOf('Collecting data') < 0,
				JSON.stringify(box.textContent.slice(0, 80)));

			if (assertions)
				assertions(box);
		})
		.catch((e) => {
			failures++;
			console.log('  FAIL the poll tick rejected — ' + e.message);
		});
}

/* --- 1. normal device: every source has content ---------------------------- */
/* The box must contain log lines and nothing else: the "oldest / newest /
   device time" paragraph that used to be prepended was removed on request
   (0.1.26), and a reader who opened this page complained it read like a
   manual rather than a log. 0.1.28 removed the last one (the UTC→local
   explanation), so nothing may be prepended at all — see case 5. */
const CASES = [
{
	name: 'log page: every source readable',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core_tz') >= 0 ? 'local\n' : SAMPLE)
	},
	assertions: (box) => {
		check('the merged box shows the log lines',
			box.querySelectorAll('.hp-log-line').length > 0,
			box.querySelectorAll('.hp-log-line').length + ' rows');
		/* 日志框里只许有日志行：要么「时间戳 [级别] 正文」，要么是上一条
		   的缩进续行。说明段落（哪怕只有一行）都会在这里露馅。 */
		const prose = Array.from(box.querySelectorAll('.hp-log-line')).filter((n) =>
			!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[[A-Z]+\]/.test(n.textContent) &&
			!n.classList.contains('hp-log-cont'));

		check('every row is a log line, not a paragraph',
			prose.length === 0,
			JSON.stringify(prose.slice(0, 2).map((n) => n.textContent.slice(0, 50))));
		check('the removed span/device-time sentence is gone',
			!/oldest .*newest |device time/i.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 60)));
	}
},

/* --- 2. half the files were never written --------------------------------- */
/* NotFoundError is the normal state (sing-box-s only exists in server mode),
   and must not print a row of its own. */
{
	name: 'log page: files that were never written',
	opts: {
		read: (p) => Promise.reject(new Error('NotFoundError: ENOENT'))
	},
	assertions: (box) => {
		check('an all-missing set renders the empty state',
			/Log is empty/i.test(box.textContent), JSON.stringify(box.textContent.slice(0, 40)));
		check('no "does not exist" noise is printed',
			box.textContent.indexOf('does not exist') < 0);
	}
},

/* --- 3. a real read failure is reported and names the file ---------------- */
{
	name: 'log page: unreadable file',
	opts: {
		read: (p) => (String(p).indexOf('sing-box-s.log') >= 0
			? Promise.reject(new Error('Permission denied'))
			: Promise.resolve(SAMPLE)),
		sources: CORE_SOURCES
	},
	assertions: (box) => {
		check('a read failure is shown instead of being swallowed',
			/Failed to read sing-box-s\.log/.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 80)));
		/* 这条提示行没有时间戳（它不是日志），但有级别标记，而且必须是
		   [ERROR]：它的英文原文不含「失败」，只靠中文关键字判会退化成
		   [INFO]，所以 isErrorRecord 额外认了句首大写的 `Failed\b`。 */
		check('a read failure is tagged [ERROR] (no timestamp — it is not a log line)',
			/^\[ERROR\] Failed to read sing-box-s\.log/m.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 80)));
	}
},

/* --- 4. a broken promise chain must say so, not spin forever -------------- */
/* The box is only redrawn on success, so anything that throws inside the chain
   leaves the loading spinner up indefinitely. The catch at the end of
   refresh() has to replace it with a message. The failure is injected in the
   source reads, not in rpc: the refresh chain makes no rpc call at all (the
   settings read happens once at render time), so an rpc-side throw would never
   run and this case would pass for the wrong reason. */
{
	name: 'log page: broken refresh',
	opts: {
		read: (p) => {
			if (String(p).indexOf('core_tz') >= 0)
				return Promise.resolve('local\n');

			throw new Error('boom');
		}
	},
	assertions: (box) => {
		check('a failing refresh reports the error in the box',
			/Failed to load the log/.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 80)));
		check('the loading spinner is gone',
			box.querySelectorAll('img').length === 0 &&
			box.textContent.indexOf('Collecting data') < 0);
	}
},

/* --- 5. core logged in UTC: converted silently, with no notice ---------- */
/* 0.1.28：用户要求删掉「内核日志时间戳原为 UTC（本机没有时区数据），已按本地
   时区（+08:00）换算显示。」这条说明行。**换算本身照做**（否则内核那几行会
   比其它来源早八小时，合并排序也跟着错），只是不再往框里塞一段文字。 */
{
	name: 'log page: core logged in UTC (converted, no note)',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core_tz') >= 0 ? 'utc 28800\n' : SAMPLE),
		sources: CORE_SOURCES
	},
	assertions: (box) => {
		const noStamp = Array.from(box.querySelectorAll('.hp-log-line')).filter((n) =>
			!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[[A-Z]+\]/.test(n.textContent) &&
			!n.classList.contains('hp-log-cont'));

		check('no explanatory line is prepended any more',
			noStamp.length === 0,
			JSON.stringify(noStamp.map((n) => n.textContent.slice(0, 50))));
		check('the notice text is gone from the box',
			box.textContent.indexOf('time zone data') < 0 &&
			box.textContent.indexOf('converted to local time') < 0,
			JSON.stringify(box.textContent.slice(0, 90)));
		check('the converted core line is still on a local clock',
			box.textContent.indexOf('2026-10-24 17:54:05') >= 0,
			JSON.stringify(box.textContent.slice(-60)));
	}
},

/* --- 6. the display is bounded by the file size, not by a line count ------ */
/* 0.1.28: the "only the last N lines are shown" cap was removed on request.
   Truncation is now the log file's job (日志设置 → 日志大小上限), so a file
   that holds 1500 lines must render 1500 rows — no red "only the last … lines"
   footer, and no silently missing history. */
{
	name: 'log page: no line cap (size limit replaces it)',
	opts: {
		read: (p) => {
			if (String(p).indexOf('core_tz') >= 0)
				return Promise.resolve('local\n');

			const lines = [];

			for (let i = 0; i < 1500; i++) {
				const d = new Date(Date.UTC(2026, 9, 24, 0, 0, 0) + i * 1000);
				const pad = (n) => ((n < 10 ? '0' : '') + n);

				lines.push('2026-10-24 ' + pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) +
					':' + pad(d.getUTCSeconds()) + ' 第 ' + i + ' 行');
			}

			return Promise.resolve(lines.join('\n'));
		},
		sources: [ { file: 'homeproxy' } ]
	},
	assertions: (box) => {
		check('every line of a long file is rendered',
			box.querySelectorAll('.hp-log-line').length === 1500,
			box.querySelectorAll('.hp-log-line').length + ' rows');
		check('no "only the last N lines" footer is rendered',
			!/only the last|只显示最后/i.test(box.textContent));
		check('the oldest rendered row is the first line of the file',
			box.textContent.indexOf('第 0 行') >= 0);
	}
},

/* --- 7. 插件日志 / 内核日志 show everything ------------------------------- */
/* These two pages exist precisely so that "the line is in the file but not on
   screen" cannot happen: no display filter, no verbosity filter. A DEBUG line
   must be on screen even though the default verbosity is info. */
{
	name: 'plugin page: no filter at all',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core_tz') >= 0 ? 'local\n'
			: [ '2026-10-24 09:54:05 DEBUG 这条不该被级别过滤掉',
			    '2026-10-24 09:54:06 错误：这条也不该被隐藏' ].join('\n')),
		sources: [ { file: 'homeproxy' } ]
	},
	assertions: (box) => {
		check('a DEBUG row survives (no level filter)',
			box.textContent.indexOf('这条不该被级别过滤掉') >= 0,
			JSON.stringify(box.textContent.slice(0, 80)));
		check('an error row survives too',
			box.textContent.indexOf('这条也不该被隐藏') >= 0);
	}
},

/* --- 8. 警告 / 错误行要有颜色 -------------------------------------------- */
/* 用户 0.1.28：WARN / ERROR 行原来跟普通行一样是黑的，扫一眼看不出哪行要紧。
   配色按**记录**算（续行一起上色），判定复用过滤用的 isWarnRecord /
   isErrorRecord —— 插件日志行里没有级别 token，只能靠中文关键字，所以
   「失败 1」这种统计行绝对不能被染红（靠 isErrorRecord 里的
   `失败(?!\s*\d)`）。这两件事一起验，才能证明「红的就是错的」。 */
{
	name: 'log page: warnings and errors are coloured',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core_tz') >= 0 ? 'local\n'
			: [ '2026-10-24 09:54:05 INFO router: started',
			    '2026-10-24 09:54:06 WARN outbound/proxy: dial timeout after 5s',
			    '2026-10-24 09:54:07 ERROR router: configure tun interface: operation not permitted',
			    '    Caused by: ioctl SIOCSIFFLAGS',
			    '2026-10-24 09:54:08 ==== 规则集更新结束：成功 1，跳过 0，失败 1，耗时 3 秒 ====' ].join('\n')),
		sources: [ { file: 'homeproxy' } ]
	},
	assertions: (box) => {
		const warn = box.querySelectorAll('.hp-log-warn'),
		      err = box.querySelectorAll('.hp-log-error');

		check('a WARN row is drawn in amber',
			warn.length === 1 && warn[0].textContent.indexOf('dial timeout') >= 0,
			warn.length + ' warn rows');
		check('an ERROR row is drawn in red',
			err.length === 2 && err[0].textContent.indexOf('operation not permitted') >= 0,
			err.length + ' error rows');
		check('the continuation line of an ERROR is coloured too',
			err.length === 2 && err[1].textContent.indexOf('Caused by') >= 0,
			err.length > 1 ? JSON.stringify(err[1].textContent) : 'no continuation');
		check('an INFO row stays plain',
			box.querySelectorAll('.hp-log-warn, .hp-log-error').length === 3,
			box.querySelectorAll('.hp-log-warn, .hp-log-error').length + ' coloured rows');
		check('the "失败 1" summary line is not coloured as an error',
			Array.prototype.every.call(err, (n) => n.textContent.indexOf('规则集更新结束') < 0));
	}
},

/* --- 9. 每行都要有时间戳 + 方括号级别标记 -------------------------------- */
/* 用户 0.1.28：插件日志与内核日志里的内容「都必须要有日志时间戳，还有
   [INFO] / [ERROR] 这样的标记」。内核原本写裸的 `INFO router: …`，插件
   自己的四份日志（主日志、三份下载日志）连 token 都没有 —— 于是同一个日志
   框里三种排版。现在两样都由渲染统一补：`时间戳 [级别] 正文`。
   要害是「标记与颜色/过滤同源」：红的行必须写着 [ERROR]，`失败 1` 这种
   统计行必须写着 [INFO]；内核那个裸 token 被掐掉了，绝不能出现两遍。 */
{
	name: 'log page: every row carries a stamp and a level tag',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core_tz') >= 0 ? 'local\n'
			: [ '2026-10-24 09:54:05 INFO router: started',
			    '+0800 2026-10-24 09:54:06 WARN outbound/proxy: dial timeout after 5s',
			    '2026-10-24 09:54:07 错误：读取配置失败',
			    '    Caused by: ioctl SIOCSIFFLAGS',
			    '2026-10-24 09:54:08 ==== 规则集更新结束：成功 1，跳过 0，失败 1 ====',
			    '2026-10-24 09:54:09 [DAEMON] 服务已停止：命令=stop' ].join('\n')),
		sources: [ { file: 'homeproxy' } ]
	},
	assertions: (box) => {
		const rows = Array.prototype.slice.call(box.querySelectorAll('.hp-log-line'));
		const heads = rows.filter((n) => n.className.indexOf('hp-log-cont') < 0);
		const STAMP = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[[A-Z]+\] +\S/;

		check('every record starts with "<ts> [LEVEL] "',
			heads.length === 5 && heads.every((n) => STAMP.test(n.textContent)),
			JSON.stringify(heads.map((n) => n.textContent.slice(0, 26))));

		check('a kernel INFO line shows the token exactly once',
			heads[0].textContent === '2026-10-24 09:54:05 [INFO]  router: started',
			JSON.stringify(heads[0].textContent));

		check('a kernel WARN line keeps the +0800 prefix out of the text',
			heads[1].textContent === '2026-10-24 09:54:06 [WARN]  outbound/proxy: dial timeout after 5s',
			JSON.stringify(heads[1].textContent));

		check('a plugin line with no token is tagged from its content',
			heads[2].textContent === '2026-10-24 09:54:07 [ERROR] 错误：读取配置失败',
			JSON.stringify(heads[2].textContent));

		check('the "失败 1" summary is tagged [INFO], not [ERROR]',
			heads[3].textContent.indexOf('[INFO]  ==== 规则集更新结束') > 0 &&
			heads[3].textContent.indexOf('[ERROR]') < 0,
			JSON.stringify(heads[3].textContent));

		check('the [DAEMON] marker the main log writes is preserved',
			heads[4].textContent.indexOf('[INFO]  [DAEMON] 服务已停止') > 0,
			JSON.stringify(heads[4].textContent));

		check('a continuation line gets the indent only (no fake stamp)',
			rows.length === 6 &&
			rows[3].className.indexOf('hp-log-cont') >= 0 &&
			rows[3].textContent.trim() === 'Caused by: ioctl SIOCSIFFLAGS',
			JSON.stringify(rows.length + ' rows'));
	}
}
];

/* --- 10. the unit table (KB / MB / GB) ------------------------------------ */
/* 0.1.28: the size limit offers KB / MB / GB, and the number field's range is
   derived from the same table that computes the byte budget. A wrong table is
   invisible in the UI — "1 GB" would quietly rotate at 1 MiB — so check the
   arithmetic straight instead of trusting the labels. */
const units = boot({ read: () => Promise.resolve('') }).module;

check('a lowercase unit is normalised to GB', units.normalizeUnit('gb') === 'GB');
check('1 GB is 1073741824 bytes',
	units.settingsBytes({ size: 1, unit: 'GB' }) === 1073741824,
	String(units.settingsBytes({ size: 1, unit: 'GB' })));
check('the GB field stops at 1 (the 1 GiB ceiling)',
	units.sizeRange('GB').max === 1, JSON.stringify(units.sizeRange('GB')));
check('the KB field starts at 64 (the 64 KiB floor)',
	units.sizeRange('KB').min === 64, JSON.stringify(units.sizeRange('KB')));
check('2048 MB is clamped to the 1024 MB ceiling',
	units.normalizeSettings({ size: 2048, unit: 'MB' }).size === 1024);
check('a zero budget still lands on 64 KiB',
	units.settingsBytes({ size: 0, unit: 'MB' }) === 65536);

/* One case at a time: each boot() rebinds window/document for the module. */
let chain = Promise.resolve();
CASES.forEach((c) => {
	chain = chain.then(() => run(c.name, c.opts, c.assertions));
});

chain.then(() => {
	console.log(failures ? ('\nFAILED: ' + failures + ' of ' + checks + ' checks') :
		('\nALL ' + checks + ' CHECKS PASSED'));
	process.exit(failures ? 1 : 0);
});
