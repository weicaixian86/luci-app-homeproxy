/*
 * The unified log view, rendered for real.
 *
 * log.js cannot be `require`d (it ends with `return view.extend(...)`), so the
 * whole module body is evaluated inside a Function with the LuCI modules it
 * needs passed in as stubs, renderUnifiedLog() is called, and one poll tick is
 * fired. Nothing here asserts *how* the code is written; it only checks that a
 * poll tick ends with a log box on screen.
 *
 * This exists because a `shift` that was left in the closure of a previous
 * `.then` only surfaced at request time: the promise chain rejected with
 * "ReferenceError: shift is not defined", the box kept its initial
 * "Collecting data..." spinner and the page looked like it never loaded. No
 * amount of `node --check` or string matching can catch that — only running it.
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

const LOG_JS = path.join(__dirname, '..', '..',
	'luci-app-homeproxy', 'htdocs', 'luci-static', 'resources', 'view', 'homeproxy', 'log.js');

const SAMPLE = [
	'2026-10-24 09:46:40 ==== 规则集预下载开始（共 1 条，预算 600s）====',
	'+0800 2026-10-24 09:54:05 INFO [3784988318 83ms] outbound/vless[hk]: outbound connection to 1.2.3.4:443',
	'2026-10-24 09:54:06 已更新 geosite-cn（431 KB）'
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
 * Boot one isolated copy of the view.
 *
 * @param {object} opts
 * @param {function} opts.read  (path) => Promise<string>, the fs stub
 * @returns {{ tick: function(): Promise<void>, box: function(): Element }}
 */
function boot(opts) {
	const src = fs.readFileSync(LOG_JS, 'utf8')
		/* Make the module hand back the renderer instead of the view object. */
		.replace('return view.extend({',
			'__out.renderUnifiedLog = renderUnifiedLog;\n__out.view = view.extend({')
		.replace(/^'use strict';\n/, '')
		.replace(/^'require [^']*';\n/gm, '');

	const dom = new JSDOM('<!doctype html><html><body></body></html>');

	/* The view reads window/document directly (selection, clipboard). */
	global.window = dom.window;
	global.document = dom.window.document;

	let pollFn = null;

	function E(tag, attrs, children) {
		if (Array.isArray(tag)) {
			const frag = document.createDocumentFragment();
			tag.forEach((c) => append(frag, c));
			return frag;
		}

		const el = document.createElement(tag);

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

	const stubs = {
		dom: {
			content: function (node, content) {
				node.textContent = '';
				append(node, content);
			}
		},
		form: {},
		fs: { read_direct: (p) => opts.read(p) },
		rpc: {
			declare: () => () => {
				if (opts.boom)
					throw new Error('boom');
				return Promise.resolve(opts.systemInfo || {});
			}
		},
		uci: { get: () => (opts.logLevel || 'info'), set: () => {} },
		ui: {
			createHandlerFn: (ctx, fn) => fn,
			addNotification: () => {},
			changes: { apply: () => {} }
		},
		view: { extend: (o) => o },
		hp: {
			installCloseButtonText: () => {},
			pollAdd: (key, fn) => { pollFn = fn; return true; }
		},
		E: E,
		_: (s) => s,
		L: {
			resource: () => 'loading.svg',
			env: { pollinterval: 5 },
			bind: (f, c) => f.bind(c),
			resolveDefault: (p) => p
		},
		poll: { add: () => true, remove: () => {} }
	};

	const fn = new Function(...Object.keys(stubs),
		'const __out = {};\n' + src + '\nreturn __out;');
	const out = fn.apply(null, Object.values(stubs));

	const host = document.createElement('div');
	host.id = 'host';
	append(host, out.renderUnifiedLog.call({ map: { save: () => Promise.resolve() } }));
	document.body.appendChild(host);

	return {
		initial: () => document.querySelector('#log_textarea').textContent.trim(),
		tick: () => {
			if (!pollFn)
				return Promise.reject(new Error('hp.pollAdd() was never called'));

			return Promise.resolve().then(() => pollFn());
		},
		box: () => document.querySelector('#log_textarea')
	};
}

function run(name, opts, assertions) {
	console.log(name);

	const view = boot(opts);

	check('the box starts as a loading placeholder',
		view.initial().indexOf('Collecting data') >= 0, JSON.stringify(view.initial()));

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
const CASES = [
{
	name: 'log view: every source readable',
	opts: {
		read: (p) => Promise.resolve(String(p).indexOf('core.zone') >= 0 ? 'local\n' : SAMPLE),
		systemInfo: { localtime: 1792000000 }
	},
	assertions: (box) => {
		check('the merged box shows the log lines',
			box.querySelectorAll('.hp-log-line').length > 0,
			box.querySelectorAll('.hp-log-line').length + ' rows');
		check('a leading notice is rendered',
			box.querySelectorAll('.hp-log-note').length === 1,
			box.querySelectorAll('.hp-log-note').length + ' notes');

		const note = box.querySelector('.hp-log-note');

		check('the notice reports the oldest/newest span',
			note && /oldest .*newest /i.test(note.textContent),
			note ? JSON.stringify(note.textContent.slice(0, 60)) : 'no note');
		check('the notice carries the device clock from rpcd',
			note && /device time \d{4}-\d{2}-\d{2}/.test(note.textContent),
			note ? JSON.stringify(note.textContent.slice(-40)) : 'no note');
	}
},

/* --- 2. half the files were never written --------------------------------- */
/* NotFoundError is the normal state (sing-box-s only exists in server mode),
   and must not print a row of its own. */
{
	name: 'log view: files that were never written',
	opts: {
		read: (p) => (String(p).indexOf('core.zone') >= 0)
			? Promise.reject(new Error('NotFoundError: core.zone'))
			: Promise.reject(new Error('NotFoundError: ENOENT')),
		systemInfo: {}
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
	name: 'log view: unreadable file',
	opts: {
		read: (p) => (String(p).indexOf('core.zone') >= 0)
			? Promise.reject(new Error('NotFoundError: core.zone'))
			: (String(p).indexOf('sing-box-s.log') >= 0
				? Promise.reject(new Error('Permission denied'))
				: Promise.resolve(SAMPLE)),
		systemInfo: {}
	},
	assertions: (box) => {
		check('a read failure is shown instead of being swallowed',
			/Failed to read sing-box-s\.log/.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 80)));
	}
},

/* --- 4. a broken promise chain must say so, not spin forever -------------- */
/* The box is only redrawn on success, so anything that throws inside the chain
   leaves the loading spinner up indefinitely. The catch at the end of
   refresh() has to replace it with a message. */
{
	name: 'log view: broken refresh',
	opts: {
		read: () => Promise.resolve(SAMPLE),
		systemInfo: {},
		boom: true
	},
	assertions: (box) => {
		check('a failing refresh reports the error in the box',
			/Failed to load the log/.test(box.textContent),
			JSON.stringify(box.textContent.slice(0, 80)));
		check('the loading spinner is gone',
			box.querySelectorAll('img').length === 0 &&
			box.textContent.indexOf('Collecting data') < 0);
	}
}
];

/* One case at a time: each boot() rebinds window/document for the view. */
let chain = Promise.resolve();

CASES.forEach((c) => {
	chain = chain.then(() => run(c.name, c.opts, c.assertions));
});

chain.then(() => {
	console.log(failures ? ('\nFAILED: ' + failures + ' of ' + checks + ' checks') :
		('\nALL ' + checks + ' CHECKS PASSED'));
	process.exit(failures ? 1 : 0);
});

