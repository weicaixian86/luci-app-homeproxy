/*
 * 日志页的三个二级选项卡，真跑一遍。
 *
 * 0.1.28 之前四个日志页是四个独立视图（各自 view.extend），在 jsdom 里没法
 * 一起跑；现在它们是一个页面里的三个面板（日志设置 / 插件日志 / 内核日志），
 * 由 log.js 的 renderTabs() 按需构建、切换、开关轮询。这段逻辑只有真跑才能
 * 验证：
 *   - 打开页面默认显示**插件日志**并且它要高亮（0.1.28 末版需求）；
 *   - 只有当前显示的面板在轮询（切走的必须 stop，否则每点一次多一个定时器，
 *     六个日志文件每轮被读两遍）；
 *   - 面板节点是**移出 DOM 再挂回来**的，切回去不能变成空白；
 *   - 日志设置的单位下拉必须是 KB / MB，数字框上下限恒为 1–999；
 *   - 两个日志屏都**没有任何过滤器**（0.1.28 末版连「显示：」也删了）：
 *     切过去必须一行不少。
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
	'2026-10-25 09:58:08 错误：这条也不该被隐藏',
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

/* Stand-in for LuCI's baseclass: L.require() only accepts a Class (it checks
   Class.isSubclass() and then runs `new _class()`), so modules must be built
   with baseclass.extend(). Mirroring both steps here means a module that goes
   back to `return { … }` fails in this test instead of on a real device with
   `TypeError: "<name>" factory yields invalid constructor`. */
/* LuCI 的 baseclass 是 **Class 对象本身**（不是实例），带 extend / isSubclass；
   require() 用 isSubclass 校验工厂返回值后 new 出实例。桩复刻这两步。 */
function ClassStub() {}

ClassStub.prototype = {};
ClassStub.extend = function (props) {
	function Ctor() { Object.assign(this, props); }
	Ctor.prototype = Object.create(ClassStub.prototype);
	return Ctor;
};
ClassStub.isSubclass = function (v) {
	return (typeof v == 'function' && v.prototype instanceof ClassStub);
};

const baseclass = ClassStub;

/* L.require() resolves to the instance, never to the class itself. */
function instantiate(v) {
	if (!ClassStub.isSubclass(v))
		throw new Error('factory yields invalid constructor (LuCI would refuse this)');

	return new v();
}

/* A LuCI module ends with a bare `return`, so it has to be evaluated
   inside its own function scope before its exports can be reached. */
function evalModule(file, stubs) {
	const src = stripModule(fs.readFileSync(file, 'utf8'));
	const names = Object.keys(stubs);
	const fn = new Function(...names, 'return (function(){\n' + src + '\n})();');

	return instantiate(fn.apply(null, names.map((n) => stubs[n])));
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
/* 改「内核日志级别：」时会走 `map.save(null, true)` + `ui.changes.apply(true)`
   —— 那是唯一会重启内核的控件，必须真的跑到。`save` 被调用的次数记在这里。 */
let mapSaved = 0;

function makeForm() {
	function MapStub() {
		this.sections = [];
	}

	MapStub.prototype.save = function () {
		mapSaved++;
		return Promise.resolve();
	};

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
	env: { pollinterval: 5 },
	/* 真机上 L.Class 是同一基类的 legacy 别名；模块在 baseclass 没被注入时
	   （包里的 JS 被压缩过）就靠它兜底。 */
	Class: baseclass
};

	const hpStub = {
		installCloseButtonText: () => {},
		pollAdd: (key, fn, interval) => { polls.push({ key: key, interval: interval }); return true; },
		pollRemove: (key) => { stopped.push(key); return true; }
	};

	const logview = evalModule(LOGVIEW_PATH, {
		baseclass: baseclass,
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
		/* 真机的 view.extend() 返回的也是类（require 会校验），不是属性对象
		   本身；以前这里返回 o，等于把 log.js 的这份契约放过了。 */
		view: { extend: (o) => ClassStub.extend(o) },
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

	/* 结构（用户 0.1.28 末版确认）：页面本身是「运行日志」，三个二级选项卡
	   排在它下面。运行日志不能再出现在这一排里——它就是上面那个页签。 */
	check('the sub-tab strip holds three tabs', tabs.length === 3, String(tabs.length));
	check('strip labels are 日志设置 / 插件日志 / 内核日志',
		tabs.map((t) => t.textContent).join('|') === '日志设置|插件日志|内核日志',
		tabs.map((t) => t.textContent).join('|'));
	check('运行日志 is the page itself, not a sub-tab',
		tabs.filter((t) => t.textContent === '运行日志').length === 0);
	/* 打开这一页默认看插件日志，且它必须高亮 —— 页面本身没有面板，
	   一个都不高亮的话根本看不出当前是哪一屏。 */
	check('插件日志 is highlighted on open',
		tabs[1].className === 'hp-log-tab-active', String(tabs[1].className));
	check('the plugin panel is mounted on open', !!document.querySelector('#hp_log_plugin'));
	/* 0.1.28 末版：插件日志也不过滤——「显示：」下拉删掉，顶栏只剩
	   自动刷新 / 清空 / 复制。 */
	check('the plugin panel has no 显示 dropdown any more',
		!document.querySelector('#hp_log_view'));
	check('only the visible panel registered a poll',
		w.polls.length === 1 && w.polls[0].key === 'log-plugin-refresh',
		JSON.stringify(w.polls));

	await delay();

	const plugin_box = document.querySelector('#hp_log_plugin');

	check('the plugin panel shows log lines',
		plugin_box && plugin_box.textContent.indexOf('服务启动') >= 0,
		JSON.stringify((plugin_box ? plugin_box.textContent : '').slice(0, 60)));
	/* 用户 0.1.28：这一屏底下那行「每 N 秒刷新。· 先点击日志区域…」要去掉。
	   去掉的是显示，轮询照旧。 */
	check('the plugin panel has no refresh hint under the box',
		plugin_box && plugin_box.closest('.hp-log-panel').textContent.indexOf('Refresh every') < 0,
		plugin_box ? JSON.stringify(plugin_box.closest('.hp-log-panel').textContent.slice(-60)) : 'no panel');

	/* 用户 0.1.28 现场（红框）：选项卡下面那片空白，是「顶栏单独一个
	   cbi-section、没有 head 时整条空着」留下的。现在顶栏与日志框在**同一个**
	   容器里，容器自己不是 cbi-section（section 自带外边距会再留一条空白），
	   而且顶栏是容器的第一个孩子 —— 中间不许再插任何东西。 */
	const plugin_panel = plugin_box ? plugin_box.closest('.hp-log-panel') : null;

	check('the top bar and the log box share one container',
		plugin_panel && plugin_panel.firstElementChild ===
			plugin_panel.querySelector('.hp-log-topbar'),
		plugin_panel ? plugin_panel.className : 'no container');
	check('no empty cbi-section strip above the log box',
		plugin_panel && !plugin_panel.classList.contains('cbi-section') &&
		plugin_panel.querySelectorAll('.cbi-section').length === 0,
		plugin_panel ? plugin_panel.className : 'no container');
	check('the plugin top bar holds only auto-refresh and the buttons',
		!!(plugin_panel && !plugin_panel.querySelector('.hp-log-topbar select')
			&& plugin_panel.querySelectorAll('.hp-log-topbar button').length === 2),
		plugin_panel ? String(plugin_panel.querySelectorAll('.hp-log-topbar button').length) : 'no container');

	/* ── 插件日志没有任何过滤器（0.1.28 末版） ──────────────────────────
	   「文件里有、界面上没有」最常见的原因就是某个过滤器停在上次选的值。
	   「显示：」删除后这一屏没有 select、没有 filter，DEBUG 与错误行都得在。 */
	const plugin_text = document.querySelector('#hp_log_plugin').textContent;

	check('a DEBUG line survives on the plugin panel (no filter)',
		plugin_text.indexOf('这条不该被级别过滤掉') >= 0,
		JSON.stringify(plugin_text.slice(0, 80)));
	check('an error line survives on the plugin panel too',
		plugin_text.indexOf('错误：这条也不该被隐藏') >= 0);
	check('no dropdown is left in the plugin top bar',
		!document.querySelector('#hp_log_view'));

	/* ── 日志设置 ─────────────────────────────────────────────────────── */
	clickTab('日志设置');

	check('clicking a sub-tab highlights it',
		tabs[0].className === 'hp-log-tab-active', String(tabs[0].className));
	check('leaving the plugin panel stops its poll',
		w.stopped.indexOf('log-plugin-refresh') >= 0, JSON.stringify(w.stopped));
	check('the plugin panel is unmounted (one panel at a time)',
		!document.querySelector('#hp_log_plugin'));
	check('the settings panel has two rows (size + unit share one)',
		document.querySelectorAll('.hp-logset-row').length === 2,
		String(document.querySelectorAll('.hp-logset-row').length));
	check('row labels are 日志刷新时间 / 日志大小上限',
		Array.from(document.querySelectorAll('.hp-logset-label'))
			.map((n) => n.textContent).join('|') === '日志刷新时间|日志大小上限',
		Array.from(document.querySelectorAll('.hp-logset-label')).map((n) => n.textContent).join('|'));

	const unit = document.querySelector('.hp-logset-row select');

	check('the unit dropdown offers KB / MB only (GB was removed)',
		unit && Array.from(unit.options).map((o) => o.value).join('|') === 'KB|MB',
		unit ? Array.from(unit.options).map((o) => o.value).join('|') : 'no select');

	await delay();

	const size_in = document.querySelectorAll('.hp-logset-row input[type="number"]')[1];

	/* 用户 0.1.28：「日志大小上限」原来拆成了两行（数字一行、单位一行），
	   中间还夹着别的行时看不出是一件事。现在同一个 .hp-logset-row 里
	   既有数字框也有单位下拉。 */
	check('the size field and the unit dropdown sit in the same row',
		!!size_in && !!unit && size_in.parentNode === unit.parentNode,
		size_in && unit ? (size_in.parentNode === unit.parentNode ? 'same row' : 'different rows') : 'missing control');

	check('the size field takes 1-999 (min 1, max 999)',
		size_in && size_in.getAttribute('min') === '1' && size_in.getAttribute('max') === '999',
		size_in ? (size_in.getAttribute('min') + '-' + size_in.getAttribute('max')) : 'no input');

	/* 1 MB = 1024 KB，超过 999 的上界 → 夹到 999；同时上下限不随单位变。 */
	unit.value = 'KB';
	unit.dispatchEvent(new window.Event('change', { bubbles: true }));

	check('switching to KB converts 1 MB and clamps to 999',
		size_in.value === '999', size_in.value);
	check('the field max stays 999 after a unit switch',
		size_in.getAttribute('max') === '999', String(size_in.getAttribute('max')));

	/* ── 内核日志 ─────────────────────────────────────────────────────── */
	clickTab('内核日志');
	await delay();

	const core = document.querySelector('#hp_log_core');

	check('the core panel is mounted', !!core);
	/* 「内核日志级别：」下拉搬到这一屏了（它管的就是 sing-box 写多少）。 */
	check('the core panel carries the 内核日志级别 dropdown',
		!!document.querySelector('#hp_unified_log_level'));
	check('the core panel has no refresh hint either',
		core && core.closest('.hp-log-panel').textContent.indexOf('Refresh every') < 0,
		core ? JSON.stringify(core.closest('.hp-log-panel').textContent.slice(-60)) : 'no panel');
	check('the core top bar keeps its dropdown right above the box',
		!!(core && core.closest('.hp-log-panel') &&
			core.closest('.hp-log-panel').querySelector('.hp-log-topbar #hp_unified_log_level')));
	/* 这一屏不做任何过滤：顶栏那个下拉是「内核写多少」，不是「这里显示多少」。 */
	check('a DEBUG line survives in the core panel (no display filter here)',
		core && core.textContent.indexOf('这条不该被级别过滤掉') >= 0,
		core ? JSON.stringify(core.textContent.slice(0, 80)) : 'no panel');
	check('the core panel keeps its own empty/normal output',
		core && core.textContent.indexOf('服务启动') >= 0,
		core ? JSON.stringify(core.textContent.slice(0, 60)) : 'no panel');

	/* 「内核日志级别：」是唯一会保存并应用（重启内核）的控件：它必须真的拿到
	   map 并 save —— 只认 `ctx.map` 一条路时，LuCI 没把 map 带在参数里就会抛
	   `Cannot read property 'save' of undefined`，而且只在真改级别时才抛。 */
	const level_sel = document.querySelector('#hp_unified_log_level');

	level_sel.value = 'debug';
	level_sel.dispatchEvent(new window.Event('change', { bubbles: true }));
	await delay();

	check('changing the core level really saves and applies', mapSaved === 1, String(mapSaved));

	/* ── 切回插件日志：面板是「摘下来再挂回去」，不是重建 ────────────────
	   上面在插件页拿到的节点必须还是同一个；否则滚动位置、已读到的内容
	   全丢（`E([...])` 返回的 DocumentFragment 挂一次就被搬空，正是这个
	   坑的表现）。 */
	clickTab('插件日志');
	await delay();

	check('the plugin panel is re-attached, not rebuilt',
		document.querySelector('#hp_log_plugin') === plugin_box);
	check('it polls again after being shown',
		w.polls.filter((p) => p.key === 'log-plugin-refresh').length === 2,
		JSON.stringify(w.polls));

	/* 从内核日志切走后，插件面板应当是唯一挂着的那个。 */
	check('only one panel is mounted at a time',
		!document.querySelector('#hp_log_core'));
}
)().then(() => {
	console.log(failures ? ('\nFAILED: ' + failures + ' of ' + checks + ' checks') :
		('\nALL ' + checks + ' CHECKS PASSED'));
	process.exit(failures ? 1 : 0);
}).catch((e) => {
	console.log('\nFAILED: ' + (e && e.stack || e));
	process.exit(1);
});
