/*
 * Regression test for hp.pollAdd() / hp.pollRemove() in homeproxy.js.
 *
 * LuCI's poll.add() de-duplicates by function identity only, so a callback
 * created inside section.render() (a new closure on every "Save & Apply")
 * stacks one more poll entry per render. These helpers are keyed by a stable
 * name and must keep the queue at exactly one entry.
 *
 * Run: node tools/tests/poll_registry.test.cjs
 */

'use strict';

const fs = require('fs');
const path = require('path');

const SRC = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'htdocs', 'luci-static', 'resources', 'homeproxy.js');

const source = fs.readFileSync(SRC, 'utf8');
const start = source.indexOf('poll_handles: {},');
const end = source.indexOf('dns_strategy: {');

if (start < 0 || end < 0 || end <= start) {
	console.error('FAIL poll_registry: cannot locate the poll helpers in homeproxy.js');
	process.exit(1);
}

const block = source.slice(start, end);
const factory = new Function('poll', 'return ({ ' + block + ' });');

let failures = 0;

function check(name, condition, detail) {
	if (condition) {
		console.log('  ok   ' + name);
	}
	else {
		failures++;
		console.log('  FAIL ' + name + (detail != null ? '  (' + detail + ')' : ''));
	}
}

function fakePoll(withRemove) {
	const queue = [];

	const mod = {
		queue,
		add(fn) {
			if (queue.indexOf(fn) !== -1)
				return false;
			queue.push(fn);
			return true;
		}
	};

	if (withRemove !== false) {
		mod.remove = function (fn) {
			const idx = queue.indexOf(fn);
			if (idx === -1)
				return false;
			queue.splice(idx, 1);
			return true;
		};
	}

	return mod;
}

/* ---------------------------------------------------------------- modern LuCI */
{
	console.log('\n[poll.remove available]');
	const poll = fakePoll(true);
	const hp = factory(poll);

	const first = () => {};
	const second = () => {};
	let other = () => {};

	hp.pollAdd('status', first);
	check('first registration lands in the queue', poll.queue.length === 1, String(poll.queue.length));

	hp.pollAdd('status', second);
	check('re-registering replaces instead of stacking',
		poll.queue.length === 1 && poll.queue[0] === second, String(poll.queue.length));

	hp.pollAdd('status', second);
	check('registering the same callback twice is a no-op',
		poll.queue.length === 1 && poll.queue[0] === second, String(poll.queue.length));

	hp.pollAdd('other', other);
	check('a different key keeps its own entry', poll.queue.length === 2, String(poll.queue.length));

	check('pollRemove drops the key', hp.pollRemove('status') === true && poll.queue.length === 1,
		String(poll.queue.length));
	check('pollRemove on an unknown key is harmless', hp.pollRemove('nope') === false);
	check('the unrelated key survived', poll.queue[0] === other);
	check('non-function callbacks are rejected', hp.pollAdd('bad', null) === false);
}

/* ------------------------------------------------------- old LuCI (no remove) */
{
	console.log('\n[poll.remove unavailable]');
	const poll = fakePoll(false);
	const hp = factory(poll);

	hp.pollAdd('status', () => {});
	check('first registration lands in the queue', poll.queue.length === 1, String(poll.queue.length));

	const stacked = hp.pollAdd('status', () => {});
	check('no duplicate is stacked without poll.remove',
		stacked === false && poll.queue.length === 1, String(poll.queue.length));
}

/* ------------------------------------------------------- interval passthrough */
{
	console.log('\n[interval passthrough]');
	const poll = fakePoll(true);
	let seen = null;
	const originalAdd = poll.add;
	poll.add = function (fn, interval) {
		seen = interval;
		return originalAdd.call(this, fn);
	};

	factory(poll).pollAdd('status', () => {}, 10);
	check('custom interval reaches poll.add', seen === 10, String(seen));
}

console.log('');
if (failures) {
	console.log('poll_registry: FAILED (' + failures + ' assertion(s))');
	process.exit(1);
}

console.log('poll_registry: all assertions passed');
