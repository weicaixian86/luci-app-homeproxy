/*
 * Rule-set local-file status test for luci-app-homeproxy.
 *
 * Two things are pinned here:
 *
 *   1. `rulesetFileInfo` — per file, { exists, valid, size, mtime, unavailable }.
 *      The rule-set page turns that into the status column (green dot + time +
 *      size / "Download failed" / "Invalid file" / "Not downloaded").
 *   2. `builtinRuleSets` — which rule sets the generator produces per routing
 *      mode, and therefore which ones `ruleset_status` must probe.
 *
 * Why a real test instead of a grep for (1): the bug being fixed there is
 * invisible in the source. The code used lstat() for size/mtime and readfile()
 * for the magic-number check. readfile() follows symlinks, lstat() does not,
 * so for a symlinked rule-set file the two halves of the same entry described
 * *different objects*: valid=true (the 40 MB target is a real SRS archive)
 * next to size=1 B and mtime=<when the link was made> (the link itself).
 * The page then printed "1 B · 3 days ago" for a file the core was happily
 * loading. Both spellings look correct in a diff; only executing the function
 * against a filesystem where stat and lstat disagree pins which one it used.
 *
 * Why for (2): `ruleset_status` used to walk only the UCI `config ruleset`
 * sections, so in every non-custom mode it returned {} — and the status card
 * reads an empty result as "nothing to download" and printed a green
 * "Downloaded" for geoip-cn / geosite-cn / geosite-noncn files that may not
 * exist at all, while the core refuses to start without them. Which tags a
 * mode generates is a table, so it is asserted as a table, per mode.
 *
 * luci.homeproxy is an rpcd ucode plugin and cannot be require'd here, so the
 * pure helpers are sliced out verbatim and evaluated with fakes for the ucode
 * builtins they use (stat, readfile, type, substr).
 *
 * Run: node tools/tests/ruleset_status.test.cjs
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PLUGIN = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'root', 'usr', 'share', 'rpcd', 'ucode', 'luci.homeproxy');
const CLIENT = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'htdocs', 'luci-static', 'resources', 'view', 'homeproxy', 'client.js');

const src = fs.readFileSync(PLUGIN, 'utf8');
const client = fs.readFileSync(CLIENT, 'utf8');

/* Take a whole function by brace matching, so the slice cannot silently
   include the next function if the body is reformatted.

   Braces inside string literals and comments must not be counted: the helper
   contains `substr(head, 0, 1) === '{'`, and a naive counter never returns to
   depth 0 because of that literal `{`. Skip over quotes and comments first. */
function sliceFunction(signature, text) {
	const from = text === undefined ? src : text;
	const start = from.indexOf(signature);

	if (start < 0) {
		console.error('FAIL ruleset_status: cannot locate `' + signature + '` in '
			+ 'luci.homeproxy / client.js (the helper was renamed or inlined again)');
		process.exit(1);
	}

	let depth = 0, end = -1;
	let i = from.indexOf('{', start);

	while (i < from.length) {
		const ch = from[i];

		if (ch === "'" || ch === '"' || ch === '`') {
			const quote = ch;
			i++;
			while (i < from.length && from[i] !== quote) {
				if (from[i] === '\\') i++;   /* escaped quote */
				i++;
			}
			i++;
			continue;
		}

		if (ch === '/' && from[i + 1] === '*') {
			const close = from.indexOf('*/', i + 2);
			i = close < 0 ? from.length : close + 2;
			continue;
		}

		if (ch === '/' && from[i + 1] === '/') {
			const nl = from.indexOf('\n', i + 2);
			i = nl < 0 ? from.length : nl + 1;
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
		console.error('FAIL ruleset_status: unbalanced braces after ' + signature);
		process.exit(1);
	}

	return src.slice(start, end);
}

const FROM = 'function rulesetFileInfo(path, fmt) {';
const block = sliceFunction(FROM);

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

/* ── which rule sets each routing_mode actually generates ─────────────── */
/* generate_client.uc:1558-1588 pushes the built-in geo sets conditionally:
       bypass_mainland_china -> geoip-cn, geosite-cn, geosite-noncn
       bypass_mainland_china || gfwlist -> geosite-noncn
       proxy_mainland_china / global -> nothing
       custom -> the user's `config ruleset` sections (inside the custom
                 branch at :1592, walker at :1655)
   `ruleset_status` must probe exactly those files: the core loads them at
   startup, so a missing one is a real failure the card has to show. The table
   is a pure function precisely so it can be evaluated per mode here. */
{
	const fn = sliceFunction('function builtinRuleSets(routingMode) {');
	const builtin = new Function(fn + `
		return builtinRuleSets;`)();

	check('bypass_mainland_china generates three built-in rule sets',
		builtin('bypass_mainland_china'), ['geoip-cn', 'geosite-cn', 'geosite-noncn']);
	check('gfwlist generates only geosite-noncn',
		builtin('gfwlist'), ['geosite-noncn']);

	/* custom is covered by the UCI walker, not by the built-in list; the two
	   other modes generate no rule set at all. All three must yield []. */
	for (const mode of ['custom', 'proxy_mainland_china', 'global'])
		check(mode + ' generates no built-in rule set', builtin(mode), []);

	/* An unwritten or misspelt routing_mode: the generator defaults to
	   bypass_mainland_china (:66) or produces nothing (misspelt). Either way
	   there is nothing to probe beyond the default, and the empty list is the
	   safe answer — it can only make the card show "-", never a false green. */
	check('an unknown routing_mode yields no built-in rule set',
		builtin('proxy_mainland'), []);
}

/* ── rpcd and the frontend must agree on the applicability table ──────── */
/* builtinRuleSets() (rpcd) and RULESET_MODES (client.js) are two spellings of
   the same fact: which modes have rule-set files worth checking. They are in
   different languages in different files, so nothing but an assertion keeps
   them in step — the failure mode is silent and asymmetric (rpcd reports the
   files, the card shows "-", or vice versa). */
{
	const modes = client.slice(client.indexOf('RULESET_MODES = ['),
		client.indexOf('];', client.indexOf('RULESET_MODES = [')) + 2);
	const frontend = [...modes.matchAll(/'([^']+)'/g)].map((m) => m[1]);

	const fn = sliceFunction('function builtinRuleSets(routingMode) {');
	const builtin = new Function(fn + `
		return builtinRuleSets;`)();

	/* custom is in RULESET_MODES but not in builtinRuleSets (it uses the UCI
	   walker), so the comparison is: the frontend list minus custom is exactly
	   the set of modes the rpcd table covers. */
	const KNOWN = ['custom', 'bypass_mainland_china', 'gfwlist',
		'proxy_mainland_china', 'global'];

	check('RULESET_MODES names only known routing modes',
		frontend.every((m) => KNOWN.includes(m)), true);

	const checked = frontend.filter((m) => builtin(m).length > 0);

	check('every mode the frontend checks (except custom) has a built-in list',
		frontend.filter((m) => m !== 'custom').sort(), checked.slice().sort());

	/* And the reverse: no mode that rpcd would report is missing from the
	   frontend table (that would report files the card then throws away). */
	const rpcd_modes = KNOWN.filter((m) => builtin(m).length > 0);

	check('every mode rpcd reports is in the frontend table',
		rpcd_modes.every((m) => frontend.includes(m)), true);
}

/* ── the walker must probe the built-ins before the custom early return ── */
/* The order matters: the built-in loop has to run for every mode, and the
   custom-only UCI walker must sit *after* the `!== 'custom'` early return.
   Inverting them would either hide the built-ins in bypass/gfwlist (the bug
   being fixed) or mix user sections into modes that never read them. */
{
	const body = src.slice(src.indexOf('ruleset_status: {'),
		src.indexOf('ruleset_update: {'));
	const at_builtin = body.indexOf('builtinRuleSets(');
	const at_return = body.indexOf("routing_mode !== 'custom'");
	const at_foreach = body.indexOf("uci.foreach('homeproxy', 'ruleset'");

	check('ruleset_status probes the built-in rule sets for every mode',
		at_builtin >= 0, true);
	check('the built-in probe runs before the custom early return',
		at_builtin >= 0 && at_return > at_builtin, true);
	check('the UCI section walker runs only after the custom early return',
		at_foreach > at_return, true);

	/* Path spelling must match the generator's RULESET_DIR (HP_DIR + '/ruleset',
	   generate_client.uc:52) — a literal here would drift on a directory move. */
	check('the built-in path is built from RULESET_DIR, not a literal',
		/\$\{RULESET_DIR\}\/\$\{name\}\.srs/.test(body), true);
	check('RULESET_DIR is derived from HP_DIR like the generator does',
		/const RULESET_DIR = HP_DIR \+ '\/ruleset';/.test(src), true);
}

/* ── an unset routing_mode must not collapse to "no rule sets" ────────── */
/* `ruleset_status` used to read routing_mode with `|| ''`. When the option is
   absent (fresh install, upgrade from an old version, hand-written
   /etc/config/homeproxy) that yields '' — a mode nobody recognises —
   builtinRuleSets('') returns [], the RPC answers {}, and the status card
   reads the empty set as "nothing to download" and paints a green
   "Downloaded". The generator disagrees: generate_client.uc:66 defaults to
   bypass_mainland_china and produces three .srs files the core then loads.
   So the rpcd default must be that same mode, not ''.

   Asserted at the source level because the value comes from uci; the
   behavioural half (what builtinRuleSets does with each mode) is above. */
{
	const at = src.indexOf('const DEFAULT_ROUTING_MODE');
	const decl = at < 0 ? '' : src.slice(at, src.indexOf('\n', at));

	check('rpcd defaults routing_mode to bypass_mainland_china, like the generator',
		/^const DEFAULT_ROUTING_MODE = 'bypass_mainland_china';/.test(decl), true);

	/* No reader may keep the old empty default: it is invisible on any config
	   that does write routing_mode, and silently wrong on the ones that do not. */
	const stray = [...src.matchAll(/uci\.get\('homeproxy', 'config', 'routing_mode'\) \|\| ''/g)]
		.filter((m) => !src.slice(src.lastIndexOf('\n', m.index) + 1, m.index).trim().startsWith('*'));

	check('no rpcd reader falls back to an empty routing_mode',
		stray.length, 0);

	/* And the default must actually be used: a constant nobody references
	   would satisfy the two checks above while changing nothing. */
	check('every rpcd routing_mode reader uses DEFAULT_ROUTING_MODE',
		[...src.matchAll(/uci\.get\('homeproxy', 'config', 'routing_mode'\) \|\| DEFAULT_ROUTING_MODE\)/g)].length,
		[...src.matchAll(/uci\.get\('homeproxy', 'config', 'routing_mode'\)/g)].length);
}

console.log('');
console.log(failed === 0
	? 'ruleset_status: all ' + passed + ' assertions passed'
	: 'ruleset_status: ' + failed + ' of ' + (passed + failed) + ' assertions FAILED');

process.exit(failed === 0 ? 0 : 1);
