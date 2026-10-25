/*
 * 日志页的四个选项卡，真跑一遍。
 *
 * 0.1.28 之前四个日志页是四个独立视图（各自 view.extend），在 jsdom 里没法
 * 一起跑；现在它们是一个页面里的四个面板，由 log.js 的 renderTabs() 按需
 * 构建、切换、开关轮询。这段逻辑只有真跑才能验证：
 *   - 只有当前显示的面板在轮询（切走的必须 stop，否则每点一次多一个定时器，
 *     六个日志文件每轮被读四遍）；
 *   - 面板节点是**移出 DOM 再挂回来**的，切回去不能变成空白；
 *   - 日志设置的单位下拉必须是 KB / MB / GB，数字框的上下限跟着单位走。
 *
 * 打印 SKIP 并退出 0 当 jsdom 不可用（run.sh 会把 SKIP 转成 skip 行）。
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

const RES = path.join(__dirname, '..', '..', 'luci-app-homeproxy',
	'htdocs', 'luci-static', 'resources');
const LOG_PATH = path.join(RES, 'view', 'homeproxy', 'log.js');
const LOGVIEW_PATH = path.join(RES, 'homeproxy', 'logview.js');

const SAMPLE = [
	'2026-10-25 09:58:02 [DAEMON] ==== 服务启动：命令=start，触发=系统启动 ====',
	'2026-10-25 09:58:07 DEBUG 这条不该被级别过滤掉',
	'2026-10-25 09:58:09 已更新 geosite-cn（431 KB）'
].join('\n');

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

/* LuCI patches String.prototype.format in luci.js; the view formats the
   "Refresh every %s seconds." line and the byte budget with it. */
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

/* The merged-line parser calls String.format(fmt, …) as a static. */
if (typeof String.format !== 'function') {
	String.format = function (fmt) {
		return String.prototype.format.apply(fmt, Array.prototype.slice.call(arguments, 1));
	};
}

function stripModule(src) {
	return src
		.replace(/^'use strict';\n/, '')
		.replace(/^'require [^']*';\n/gm, '');
}

/* A LuCI module ends with a bare `return { … }`, so it has to be evaluated
   inside its own function scope before its exports can be reached. */
function evalModule(file, stubs) {
	const src = stripModule(fs.readFileSync(file, 'utf8'));
	const names = Object.keys(stubs);
	const fn = new Function(...names, 'return (function(){\n' + src + '\n})();');

	return fn.apply(null, names.map((n) => stubs[n]));
}

/* LuCI's E(): the second argument is children whenever it is not a plain
   attribute map, and an attribute whose value is a function becomes an event
   listener (not setAttribute — that threw InvalidCharacterError on jsdom). */
function isAttrsMap(v) {
	return v !== null && typeof v === 'object' && !Array.isArray(v) && !v.nodeType;
}

function E(tag, attrs, children) {
	if (Array.isArray(tag)) {
		const frag = document.createDocumentFragment();
		tag.forEach((c) => append(frag, c));
		return frag;
	}

	const el = document.createElement(tag);

	if (attrs !== undefined && attrs !== null && !isAttrsMap(attrs)) {
		children = (children === undefined) ? attrs : [ attrs, children ];
		attrs = null;
	}

	if (attrs) {
		for (const k in attrs) {
			if (attrs[k] === null || attrs[k] === undefined)
				continue;

			if (typeof attrs[k] === 'function')
				el.addEventListener(k, attrs[k]);
			else if (k === 'class')
				el.className = attrs[k];
			else
				el.setAttribute(k, String(attrs[k]));
		}
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

/* form.Map is only used as a carrier here: the view puts one DummyValue in a
   NamedSection and renders the tabbed page from its render(). The stub mirrors
   just that contract (section → option → render). */
function makeForm() {
	function MapStub() {
		this.sections = [];
	}

	MapStub.prototype.section = function (type, name) {
		const s = { type: type, name: name, anonymous: false, opts: [], render: null };

		s.option = function (t, n) {
			const o = { type: t, name: n, render: null };
			s.opts.push(o);
			return o;
		};

		this.sections.push(s);
		return s;
	};

	MapStub.prototype.render = function () {
		const frag = document.createDocumentFragment();

		this.sections.forEach((s) => {
			if (typeof s.render === 'function') {
				append(frag, s.render());
				return;
			}

			s.opts.forEach((o) => {
				if (typeof o.render === 'function')
					append(frag, o.render());
			});
		});

		return frag;
	};

	return {
		Map: MapStub,
		NamedSection: function () {},
		DummyValue: function () {}
	};
}

function boot() {
	const dom = new JSDOM('<!doctype html><html><body></body></html>');

	global.window = dom.window;
	global.document = dom.window.document;

	const polls = [];
	const stopped = [];

	const domStub = {
		content: function (node, content) {
			node.textContent = '';
			append(node, content);
		}
	};

	const uiStub = {
		createHandlerFn: (ctx, fn) => fn,
		addNotification: () => {},
		changes: { apply: () => Promise.resolve() }
	};

	const LStub = {
		bind: (f, c) => f.bind(c),
		resolveDefault: (p, d) => Promise.resolve(p).catch(() => d),
		resource: () => 'loading.svg',
		env: { pollinterval: 5 }
	};

	const hpStub = {
		installCloseButtonText: () => {},
		pollAdd: (key, fn, interval) => { polls.push({ key: key, interval: interval }); return true; },
		pollRemove: (key) => { stopped.push(key); return true; }
	};

	const logview = evalModule(LOGVIEW_PATH, {
		dom: domStub,
		fs: {
			read_direct: (p) => Promise.resolve(
				String(p).indexOf('core_tz') >= 0 ? 'local\n' : SAMPLE)
		},
		rpc: { declare: () => () => Promise.resolve({ refresh: 5, size: 1, unit: 'MB' }) },
		ui: uiStub,
		hp: hpStub,
		E: E,
		_: (s) => s,
		L: LStub
	});

	const view = evalModule(LOG_PATH, {
		dom: domStub,
		form: makeForm(),
		uci: { get: () => null, set: () => {}, save: () => {} },
		ui: uiStub,
		view: { extend: (o) => o },
		hp: hpStub,
		logview: logview,
		E: E,
		_: (s) => s,
		L: LStub
	});

	const node = view.render.call({});

	document.body.appendChild(node);

	return { dom: dom, polls: polls, stopped: stopped };
}

function delay() {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

function clickTab(label) {
	const a = Array.from(document.querySelectorAll('.hp-log-tabs a'))
		.filter((x) => x.textContent === label)[0];

	if (!a)
		throw new Error('no tab labelled ' + label);

	a.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
}

(async function main() {
	const w = boot();

	const tabs = Array.from(document.querySelectorAll('.hp-log-tabs > li'));

	/* 结构（用户 0.1.28 给的参考图）：页面本身是「运行日志」，三个二级
	   选项卡排在它下面。运行日志不能再出现在这一排里——它就是上面那个
	   页签，重复一次会让人以为有两个运行日志。 */
	check('the sub-tab strip holds three tabs', tabs.length === 3, String(tabs.length));
	check('strip labels are 日志设置 / 插件日志 / 内核日志',
		tabs.map((t) => t.textContent).join('|') === '日志设置|插件日志|内核日志',
		tabs.map((t) => t.textContent).join('|'));
	check('运行日志 is the page itself, not a sub-tab',
		tabs.filter((t) => t.textContent === '运行日志').length === 0);
	check('no sub-tab is highlighted while the log itself is shown',
		tabs.filter((t) => t.className === 'hp-log-tab-active').length === 0);
	check('the runtime panel is mounted', !!document.querySelector('#hp_log_runtime'));
	check('only the visible panel registered a poll',
		w.polls.length === 1 && w.polls[0].key === 'log-refresh',
		JSON.stringify(w.polls));

	await delay();

	check('the runtime panel shows log lines',
		(document.querySelector('#hp_log_runtime') || {}).textContent.indexOf('服务启动') >= 0,
		JSON.stringify(((document.querySelector('#hp_log_runtime') || {}).textContent || '').slice(0, 60)));

	/* 记下运行日志的节点：切走之后它应该只是被摘下来（内容还在），
	   而不是被销毁重建 —— 重建会丢掉滚动位置与已读内容。 */
	const runtime_box = document.querySelector('#hp_log_runtime');

	/* ── 日志设置 ─────────────────────────────────────────────────────── */
	clickTab('日志设置');

	check('clicking a sub-tab highlights it',
		tabs[0].className === 'hp-log-tab-active', String(tabs[0].className));
	check('leaving the runtime panel stops its poll',
		w.stopped.indexOf('log-refresh') >= 0, JSON.stringify(w.stopped));
	check('the runtime panel is unmounted (one panel at a time)',
		!document.querySelector('#hp_log_runtime'));
	check('the settings panel has two rows (size + unit share one)',
		document.querySelectorAll('.hp-logset-row').length === 2,
		String(document.querySelectorAll('.hp-logset-row').length));
	check('row labels are 日志刷新时间 / 日志大小上限',
		Array.from(document.querySelectorAll('.hp-logset-label'))
			.map((n) => n.textContent).join('|') === '日志刷新时间|日志大小上限',
		Array.from(document.querySelectorAll('.hp-logset-label')).map((n) => n.textContent).join('|'));

	const unit = document.querySelector('.hp-logset-row select');

	check('the unit dropdown offers KB / MB / GB',
		unit && Array.from(unit.options).map((o) => o.value).join('|') === 'KB|MB|GB',
		unit ? Array.from(unit.options).map((o) => o.value).join('|') : 'no select');

	await delay();

	const size_in = document.querySelectorAll('.hp-logset-row input[type="number"]')[1];

	/* 用户 0.1.28：「日志大小上限」原来拆成了两行（数字一行、单位一行），
	   中间还夹着别的行时看不出是一件事。现在同一个 .hp-logset-row 里
	   既有数字框也有单位下拉。 */
	check('the size field and the unit dropdown sit in the same row',
		!!size_in && !!unit && size_in.parentNode === unit.parentNode,
		size_in && unit ? (size_in.parentNode === unit.parentNode ? 'same row' : 'different rows') : 'missing control');

	check('the size field max is the MB ceiling (1024)',
		size_in && size_in.getAttribute('max') === '1024',
		size_in ? String(size_in.getAttribute('max')) : 'no input');

	unit.value = 'GB';
	unit.dispatchEvent(new window.Event('change', { bubbles: true }));

	check('switching to GB clamps the number into the GB range',
		size_in.value === '1', size_in.value);
	check('switching to GB moves the field max to 1 (1 GiB ceiling)',
		size_in.getAttribute('max') === '1', String(size_in.getAttribute('max')));

	/* ── 插件日志 ─────────────────────────────────────────────────────── */
	clickTab('插件日志');
	await delay();

	const plugin = document.querySelector('#hp_log_plugin');

	check('the plugin panel is mounted', !!plugin);
	check('a DEBUG line survives (plugin panel has no level filter)',
		plugin && plugin.textContent.indexOf('这条不该被级别过滤掉') >= 0,
		plugin ? JSON.stringify(plugin.textContent.slice(0, 80)) : 'no panel');
	/* 用户 0.1.28：这两个页签底下那行「每 N 秒刷新。· 先点击日志区域…」
	   要去掉 —— 那里只需要原样看全部。去掉的是显示，轮询照旧。 */
	check('the plugin panel has no refresh hint under the box',
		plugin && plugin.closest('.cbi-map').textContent.indexOf('Refresh every') < 0,
		plugin ? JSON.stringify(plugin.closest('.cbi-map').textContent.slice(-60)) : 'no panel');

	/* ── 内核日志 ─────────────────────────────────────────────────────── */
	clickTab('内核日志');
	await delay();

	const core = document.querySelector('#hp_log_core');

	check('the core panel is mounted', !!core);
	check('the core panel has no refresh hint either',
		core && core.closest('.cbi-map').textContent.indexOf('Refresh every') < 0,
		core ? JSON.stringify(core.closest('.cbi-map').textContent.slice(-60)) : 'no panel');
	check('the core panel keeps its own empty/normal output',
		core && core.textContent.indexOf('服务启动') >= 0,
		core ? JSON.stringify(core.textContent.slice(0, 60)) : 'no panel');

	/* ── 切回插件日志：面板是「摘下来再挂回去」，不是重建 ────────────────
	   上面在插件页拿到的节点必须还是同一个；否则滚动位置、已读到的内容
	   全丢（`E([...])` 返回的 DocumentFragment 挂一次就被搬空，正是这个
	   坑的表现）。 */
	clickTab('插件日志');
	await delay();

	check('the plugin panel is re-attached, not rebuilt',
		document.querySelector('#hp_log_plugin') === plugin);
	check('it polls again after being shown',
		w.polls.filter((p) => p.key === 'log-plugin-refresh').length === 2,
		JSON.stringify(w.polls));

	/* 运行日志页保留那一行提示：它是唯一提示「刷新节奏」和「Ctrl+A 只选
	   这里」的地方。这里没有运行日志的选项卡可点（它是上面那个页签），
	   所以只验它被摘下时内容还在、没有被重建。 */
	check('the runtime panel was detached, not destroyed',
		runtime_box && !document.contains(runtime_box) &&
		runtime_box.textContent.indexOf('服务启动') >= 0);
}
)().then(() => {
	console.log(failures ? ('\nFAILED: ' + failures + ' of ' + checks + ' checks') :
		('\nALL ' + checks + ' CHECKS PASSED'));
	process.exit(failures ? 1 : 0);
}).catch((e) => {
	console.log('\nFAILED: ' + (e && e.stack || e));
	process.exit(1);
});
