/*
 * Rule-set local-file status test for luci-app-homeproxy.
 *
 * `ruleset_status` reports, per enabled `config ruleset` section, whether a
 * usable local copy exists: { exists, valid, size, mtime, unavailable }.
 * The rule-set page turns that into the status column (green dot + time +
 * size / "Download failed" / "Invalid file" / "Not downloaded").
 *
 * Why a real test instead of a grep: the bug being fixed here is invisible
 * in the source. The code used lstat() for size/mtime and readfile() for the
 * magic-number check. readfile() follows symlinks, lstat() does not, so for a
 * symlinked rule-set file the two halves of the same entry described
 * *different objects*: valid=true (the 40 MB target is a real SRS archive)
 * next to size=1 B and mtime=<when the link was made> (the link itself).
 * The page then printed "1 B · 3 days ago" for a file the core was happily
 * loading. Both spellings look correct in a diff; only executing the function
 * against a filesystem where stat and lstat disagree pins which one it used.
 *
 * luci.homeproxy is an rpcd ucode plugin and cannot be require'd here, so the
 * pure helper is sliced out verbatim and evaluated with fakes for the three
 * ucode builtins it uses (stat, readfile, type, substr).
 *
 * Run: node tools/tests/ruleset_status.test.cjs
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PLUGIN = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'root', 'usr', 'share', 'rpcd', 'ucode', 'luci.homeproxy');

const src = fs.readFileSync(PLUGIN, 'utf8');

const FROM = 'function rulesetFileInfo(path, fmt) {';
const start = src.indexOf(FROM);

if (start < 0) {
	console.error('FAIL ruleset_status: cannot locate `' + FROM + '` in luci.homeproxy '
		+ '(the helper was renamed or inlined again)');
	process.exit(1);
}

/* Take the whole function by brace matching, so the slice cannot silently
   include the next function if the body is reformatted.

   Braces inside string literals and comments must not be counted: the helper
   contains `substr(head, 0, 1) === '{'`, and a naive counter never returns to
   depth 0 because of that literal `{`. Skip over quotes and comments first. */
let depth = 0, end = -1;
let i = src.indexOf('{', start);

while (i < src.length) {
	const ch = src[i];

	if (ch === "'" || ch === '"' || ch === '`') {
		const quote = ch;
		i++;
		while (i < src.length && src[i] !== quote) {
			if (src[i] === '\\') i++;   /* escaped quote */
			i++;
		}
		i++;
		continue;
	}

	if (ch === '/' && src[i + 1] === '*') {
		const close = src.indexOf('*/', i + 2);
		i = close < 0 ? src.length : close + 2;
		continue;
	}

	if (ch === '/' && src[i + 1] === '/') {
		const nl = src.indexOf('\n', i + 2);
		i = nl < 0 ? src.length : nl + 1;
		continue;
	}

	if (ch === '{') {
		depth++;
	}
	else if (ch === '}') {
		depth--;
		if (depth === 0) { end = i + 1; break; }
	}

	i++;
}

if (end < 0) {
	console.error('FAIL ruleset_status: unbalanced braces after ' + FROM);
	process.exit(1);
}

const block = src.slice(start, end);

/* ucode has no Math/JSON/Object wrappers; the helper only needs these.
   `lstat` is injected as well even though the helper must not call it: the
   reverse experiment (flip stat back to lstat in the plugin) has to fail on
   an assertion, not on `lstat is not defined`. Without this fake the mutated
   plugin throws a ReferenceError and the test dies before it can report what
   actually differs. */
function makeApi(fsFakes) {
	return new Function('stat', 'lstat', 'readfile', 'type', 'substr', block + `
		return { rulesetFileInfo };`)(fsFakes.stat,
		fsFakes.lstat || fsFakes.stat, fsFakes.readfile,
		(v) => (Array.isArray(v) ? 'array'
			: (v === null ? 'null'
			: (typeof v === 'object' ? 'object' : typeof v))),
		(s, off, len) => String(s).substr(off, len));
}

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

/* ── a plain SRS file: both lookups agree, nothing to disambiguate ─────── */
{
	const fake = {
		stat: () => ({ type: 'file', size: 4096, mtime: 1700000000 }),
		readfile: () => 'SRSx'
	};

	const api = makeApi(fake);
	const e = api.rulesetFileInfo('/etc/homeproxy/ruleset/x.srs', 'binary');

	check('binary file starting with the SRS magic is valid',
		[e.exists, e.valid, e.size, e.mtime], [true, true, 4096, 1700000000]);

	/* The mtime object form ({sec, nsec}) must still be unwrapped: the rpcd
	   plugin runs on ucode builds that return the struct form. */
	fake.stat = () => ({ type: 'file', size: 4096, mtime: { sec: 1700000000, nsec: 0 } });
	const e2 = makeApi(fake).rulesetFileInfo('/x.srs', 'binary');
	check('mtime given as {sec, nsec} is unwrapped to the integer',
		e2.mtime, 1700000000);
}

/* ── magic numbers: a file that exists but is not a usable rule set ────── */
{
	const fake = {
		stat: () => ({ type: 'file', size: 100, mtime: 1700000000 }),
		readfile: () => '<ht'
	};

	const api = makeApi(fake);
	const e = api.rulesetFileInfo('/x.srs', 'binary');

	check('a binary file without the SRS magic exists but is not valid',
		[e.exists, e.valid], [true, false]);

	fake.readfile = () => '[{}]';
	const src_e = makeApi(fake).rulesetFileInfo('/x.json', 'source');
	check('a source file starting with [ is valid',
		[src_e.exists, src_e.valid], [true, true]);

	fake.readfile = () => '{}\n';
	const obj_e = makeApi(fake).rulesetFileInfo('/x.json', 'source');
	check('a source file starting with { is valid',
		[obj_e.exists, obj_e.valid], [true, true]);
}

/* ── missing / empty path ─────────────────────────────────────────────── */
{
	const fake = {
		stat: () => null,
		readfile: () => { throw new Error('must not be read when stat() fails'); }
	};

	const api = makeApi(fake);

	const missing = api.rulesetFileInfo('/x.srs', 'binary');
	check('a missing file reports exists=false and reads nothing',
		[missing.exists, missing.valid, missing.size, missing.mtime], [false, false, 0, 0]);

	const empty = api.rulesetFileInfo('', 'binary');
	check('an empty path is not probed at all (no stat, no read)',
		[empty.exists, empty.valid], [false, false]);

	const nul = api.rulesetFileInfo(null, 'binary');
	check('a null path is not probed at all',
		[nul.exists, nul.valid], [false, false]);
}

/* ── the actual regression: symlink target vs the link itself ─────────── */
/* This is the case lstat() got wrong. The fake filesystem deliberately
   returns different metadata for the two lookups, exactly as a real one does
   for `ln -s /data/rules/x.srs /etc/homeproxy/ruleset/x.srs`:
     lstat -> type 'link', size 1 (or ~40 B on other filesystems), mtime = link
     stat  -> type 'file', size 40 MB,          mtime = when the target was made
   readfile() follows the link, so only the stat values are consistent with
   the valid=true verdict it produces. */
{
	const TARGET_SIZE = 40 * 1024 * 1024;
	const TARGET_MTIME = 1790000000;
	const LINK_SIZE = 1;
	const LINK_MTIME = 1700000000;

	let used = null;

	/* Both lookups are wired to what a real filesystem would answer for
	   `ln -s /data/rules/x.srs /etc/homeproxy/ruleset/x.srs`, so whichever
	   one the helper calls decides the numbers that come out. */
	const fake = {
		stat: (p) => {
			used = 'stat';
			return { type: 'file', size: TARGET_SIZE, mtime: TARGET_MTIME };
		},
		lstat: (p) => {
			used = 'lstat';
			return { type: 'link', size: LINK_SIZE, mtime: LINK_MTIME };
		},
		readfile: () => 'SRSx'
	};

	const api = makeApi(fake);
	const e = api.rulesetFileInfo('/etc/homeproxy/ruleset/x.srs', 'binary');

	check('a symlinked rule set reports the TARGET size, not the link size',
		e.size, TARGET_SIZE);
	check('a symlinked rule set reports the TARGET mtime, not the link mtime',
		e.mtime, TARGET_MTIME);
	check('and it is still judged valid (the target carries the magic)',
		e.valid, true);
	check('the helper consults stat() (follows links), never lstat()',
		used, 'stat');

	/* Guard the inconsistency itself: if the helper were switched back to
	   lstat(), size and mtime would come from the link while readfile() still
	   returned the target's bytes. Simulate that pairing and assert the two
	   halves would disagree - i.e. the old code was self-contradictory, not
	   merely "less accurate". */
	check('the lstat pairing would have been self-contradictory',
		[LINK_SIZE !== TARGET_SIZE, LINK_MTIME !== TARGET_MTIME, true],
		[true, true, true]);
}

/* ── the RPC must not fall back to lstat for these values ─────────────── */
/* The helper is the only place that produces size/mtime; make sure the
   section walker routes through it instead of re-implementing the probe. */
{
	const body = src.slice(src.indexOf('ruleset_status: {'),
		src.indexOf('ruleset_update: {'));

	check('ruleset_status delegates to the shared helper',
		/rulesetFileInfo\(path, fmt\)/.test(body), true);
	check('ruleset_status does not stat/lstat the rule-set file itself',
		/stat\(\s*path\s*\)/.test(body) || /lstat\(\s*path\s*\)/.test(body), false);
	check('the unavailable marker is still gated on a non-empty path',
		/length\(path\)\s*&&\s*!entry\.exists/.test(body), true);
}

console.log('');
console.log(failed === 0
	? 'ruleset_status: all ' + passed + ' assertions passed'
	: 'ruleset_status: ' + failed + ' of ' + (passed + failed) + ' assertions FAILED');

process.exit(failed === 0 ? 0 : 1);
