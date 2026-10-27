/* 订阅地址改了之后，节点段的 grouphash 与各出站的 subscription_groups 必须
 * 跟着换（否则节点能导入、面板上那个机场恒为 0/0）。
 *
 * 这段逻辑跑在浏览器里，node --check 只能证明语法合法 —— 0.2.9 就是吃了这个
 * 亏：`'subinfo_' + substr(from, 0, 16)` 里 substr 是 ucode 的内置函数，浏览器
 * 里根本没有，write() 一抛 ReferenceError，点「保存当前设置」就永远转圈，
 * 而且一个字都不报。所以这里把函数真跑一遍：给它一份 uci 的桩，断言改写结果，
 * 并单独验证「迁移内部抛异常也不能影响保存」（write() 必须照常往下走）。
 *
 * 用法：node js_migrate_hash.js <node.js 路径>
 * 退出码：0 通过 / 1 断言失败 / 2 找不到待测函数
 */
'use strict';

const fs = require('fs');

const file = process.argv[2];
if (!file) {
	console.error('usage: node js_migrate_hash.js <node.js>');
	process.exit(2);
}

const src = fs.readFileSync(file, 'utf8');
const start = src.indexOf('function migrateSubscriptionHash(');
const end = src.indexOf('const SubscriptionList', start);
if (start < 0 || end < 0) {
	console.error('cannot locate migrateSubscriptionHash() in ' + file);
	process.exit(2);
}

/* 只取这两个函数（wrapper + 实现），其余依赖用桩顶替。 */
const lib = src.slice(start, end);

let failures = 0;
function check(label, cond) {
	if (cond) {
		console.log('  ok   ' + label);
	} else {
		console.log('  FAIL ' + label);
		failures++;
	}
}

const md5 = (s) => {
	/* 假 md5：只要长度是 32 个十六进制字符、且不同输入结果完全不同即可 ——
	   真 md5 在这里没有意义，但「前 16 位会不会相同」必须被真实区分开。 */
	let h = 0x811c9dc5;
	for (const ch of s)
		h = ((h ^ ch.codePointAt(0)) * 16777619) >>> 0;
	let out = '';
	for (let i = 0; i < 4; i++)
		out += (((h ^ (i * 0x9e3779b9)) >>> 0).toString(16).padStart(8, '0'));
	return out;
};
const OLD = md5('https://old.example/sub');
const NEW = md5('https://old.example/sub?flag=singbox');

function makeUci(opts) {
	const sets = [];
	const unsets = [];
	const store = Object.assign({}, opts.store);
	const sections = opts.sections;

	return {
		calls: { sets, unsets },
		get(conf, sid, opt) {
			if (opts.throwOn && opts.throwOn(sid, opt))
				throw new Error('boom');
			if (opt === 'subscription_url')
				return [ 'https://old.example/sub' ];
			if (opt === 'subscription_name')
				return [ 'NB' ];
			return store[sid + '.' + opt] ?? null;
		},
		set(conf, sid, opt, value) {
			sets.push([ sid, opt, value ]);
			store[sid + '.' + opt] = value;
		},
		unset(conf, sid, opt) {
			unsets.push([ sid, opt ]);
			delete store[sid + '.' + opt];
		},
		sections(conf, type, cb) {
			for (const s of (sections[type] || []))
				cb(Object.assign({}, s));
		}
	};
}

function build(uci) {
	/* eslint-disable no-new-func */
	return new Function('uci', 'hp', 'normalizeList', lib + '; return migrateSubscriptionHash;')(
		uci,
		{ calcStringMD5: md5 },
		(v) => Array.isArray(v) ? v : (v ? [ v ] : [])
	);
}

/* ── 用例 1：正常改地址，三处都要跟着换 ─────────────────────────────── */
const uci1 = makeUci({
	store: { ['subscription.subinfo_' + OLD.slice(0, 16)]: '{"total":123}' },
	sections: {
		node: [
			{ '.name': 'n_old', grouphash: OLD },
			{ '.name': 'n_other', grouphash: 'someone-else' }
		],
		routing_node: [
			{ '.name': 'g_all', subscription_groups: [ 'someone-else', OLD ] },
			{ '.name': 'g_none', subscription_groups: [ 'someone-else' ] }
		]
	}
});

let threw = null;
try {
	build(uci1)('subscription', { urls: [ 'https://old.example/sub?flag=singbox' ], names: [ 'NB' ] });
} catch (e) {
	threw = e;
}

check('migration does not throw on a normal URL change', threw === null);

const setOf = (calls, sid, opt) => calls.filter((c) => c[0] === sid && c[1] === opt).pop()?.[2];

check('the node section moves to the new hash',
	setOf(uci1.calls.sets, 'n_old', 'grouphash') === NEW);
check('unrelated node groups are left alone',
	setOf(uci1.calls.sets, 'n_other', 'grouphash') === undefined);
check('a group that had the old hash is rewritten',
	JSON.stringify(setOf(uci1.calls.sets, 'g_all', 'subscription_groups')) === JSON.stringify([ 'someone-else', NEW ]));
check('a group without the old hash is not touched',
	setOf(uci1.calls.sets, 'g_none', 'subscription_groups') === undefined);
check('the userinfo key follows the hash',
	uci1.calls.sets.some((c) => c[0] === 'subscription' && c[1] === 'subinfo_' + NEW.slice(0, 16) && c[2] === '{"total":123}'));
check('the stale userinfo key is removed',
	uci1.calls.unsets.some((c) => c[0] === 'subscription' && c[1] === 'subinfo_' + OLD.slice(0, 16)));

/* ── 用例 2：名字没变、地址也没变 → 什么都不该写 ────────────────────── */
const uci2 = makeUci({ sections: { node: [], routing_node: [] } });
build(uci2)('subscription', { urls: [ 'https://old.example/sub' ], names: [ 'NB' ] });
check('re-saving the same URL writes nothing', uci2.calls.sets.length === 0 && uci2.calls.unsets.length === 0);

/* ── 用例 3：迁移内部抛异常，也不能把保存带崩 ───────────────────────── */
const uci3 = makeUci({
	sections: { node: [ { '.name': 'n_old', grouphash: OLD } ], routing_node: [] },
	throwOn: (sid, opt) => opt !== 'subscription_url' && opt !== 'subscription_name'
});
let threw3 = null;
const warn = console.warn;
console.warn = () => {};
try {
	build(uci3)('subscription', { urls: [ 'https://old.example/sub?flag=singbox' ], names: [ 'NB' ] });
} catch (e) {
	threw3 = e;
}
finally {
	console.warn = warn;
}
check('an exception inside the migration is swallowed (saving must not hang)', threw3 === null);

process.exit(failures ? 1 : 0);
