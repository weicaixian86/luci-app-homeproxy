/*
 * Status-card behaviour test for luci-app-homeproxy.
 *
 * The status row has five read-only inputs (plugin version / core version /
 * core status / panel status / rule-set status). Only the last three are
 * dynamic, and only the last two have an "not applicable" state:
 *
 *   - panel status    : the Clash API is generated only in `custom` and
 *                       `bypass_mainland_china` (generate_client.uc:1709), so in
 *                       gfwlist / proxy_mainland_china / global there is no
 *                       panel to download and the card must show "-";
 *   - rule-set status : the card tracks the *user* rule sets (`config ruleset`
 *                       sections), which exist only in `custom` mode — the rule
 *                       set page itself is gated on `routing_mode === 'custom'`
 *                       (client.js:3040). Other modes use the built-in
 *                       geoip-cn / geosite-cn / geosite-noncn that the core
 *                       downloads itself, so the card must show "-".
 *
 * Why a real test instead of a grep: the previous behaviour (grey "Not
 * downloaded" in non-panel modes) was *also* greppable and *also* looked
 * plausible. Only executing the functions pins what the user actually sees.
 *
 * client.js is a LuCI module and cannot be require'd here, so the four status
 * helpers are sliced out verbatim and evaluated against a fake document.
 *
 * Run: node tools/tests/status_card.test.cjs
 */

'use strict';

const fs = require('fs');
const path = require('path');

const CLIENT = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'htdocs', 'luci-static', 'resources', 'view', 'homeproxy', 'client.js');

const src = fs.readFileSync(CLIENT, 'utf8');

const FROM = 'function getServiceStatus() {';
const TO = 'function parseControllerPort(';

const start = src.indexOf(FROM);
const end = src.indexOf(TO);

if (start < 0 || end < 0 || end <= start) {
	console.error('FAIL status_card: cannot locate the status helpers in client.js '
		+ '(markers "function updateCoreStatus(isRunning) {" / "function parseControllerPort(" changed)');
	process.exit(1);
}

const block = src.slice(start, end);

for (const fn of ['getServiceStatus', 'updateCoreStatus', 'updatePanelStatus', 'updateRulesetStatus', 'updateDownloadStatus']) {
	if (!block.includes('function ' + fn + '(')) {
		console.error('FAIL status_card: ' + fn + '() is no longer inside the sliced block');
		process.exit(1);
	}
}

/* Minimal DOM: getElementById() over a flat registry of { value, style } cells.
   `_` is gettext; identity is enough, the assertions compare the English
   msgids (the .po files supply the Chinese at runtime).
   `callServiceList` is the only RPC getServiceStatus() reaches; it is
   injected so the three states (running / not running / unknown) can be
   driven without a live rpcd.
   `L` carries LuCI's resolveDefault (Promise.resolve(v).catch(() => def)).
   The fixed helper must not call it, but the reverse experiment (putting the
   old helper back) has to fail on an assertion rather than on
   `L is not defined`, so it is wired up here. */
function makeApi(cells, callServiceList) {
	const document = {
		getElementById: (id) => cells[id] || null
	};

	const L = {
		resolveDefault: (p, def) => Promise.resolve(p).catch(() => def)
	};

	return new Function('document', '_', 'callServiceList', 'L', block + `
		return { getServiceStatus, updateCoreStatus, updatePanelStatus, updateRulesetStatus };`)(document, (s) => s,
		callServiceList || (() => Promise.resolve({})), L);
}

function cells() {
	const c = {};

	for (const id of ['homeproxy_core_status', 'homeproxy_panel_status', 'homeproxy_ruleset_status'])
		c[id] = { value: 'Collecting data...', style: {} };

	return c;
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

/* ── core status: always applicable, two states only ───────────────────── */
{
	const c = cells();
	const api = makeApi(c);

	api.updateCoreStatus(false);
	check('core not running is red "Not Running"',
		[c.homeproxy_core_status.style.color, c.homeproxy_core_status.value], ['red', 'Not Running']);

	api.updateCoreStatus(true);
	check('core running is green "Running" (no node name appended)',
		[c.homeproxy_core_status.style.color, c.homeproxy_core_status.value], ['green', 'Running']);
}

/* ── panel status ─────────────────────────────────────────────────────── */
{
	const c = cells();
	const api = makeApi(c);

	api.updatePanelStatus({ enabled: true, installed: true }, true);
	check('custom/bypass + panel present → green "Downloaded"',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['green', 'Downloaded']);

	api.updatePanelStatus({ enabled: true, installed: false }, true);
	check('custom/bypass + panel absent → red "Not downloaded"',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['red', 'Not downloaded']);

	/* The case the user reported: a mode that has no panel at all. The file
	   may even be present from an earlier custom-mode run — still "-", because
	   nothing in this mode reads it. */
	api.updatePanelStatus({ enabled: false, installed: true }, false);
	check('gfwlist/global + panel file present → grey "-" (not applicable)',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['gray', '-']);

	api.updatePanelStatus({ enabled: false, installed: false }, false);
	check('gfwlist/global + no panel file → grey "-" (never "Not downloaded")',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['gray', '-']);

	/* rpcd already reports enabled:false for these modes; the frontend must
	   not depend on it alone (a stale RPC from before the mode change, or an
	   rpcd that was not restarted after the upgrade, would flip it back). */
	api.updatePanelStatus({ enabled: false, installed: false }, true);
	check('applicable by mode but rpcd says disabled → grey "-" as well',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['gray', '-']);
}

/* ── rule-set status ──────────────────────────────────────────────────── */
{
	const c = cells();
	const api = makeApi(c);

	const ok_status = { rs_a: { valid: true }, rs_b: { valid: true } };

	api.updateRulesetStatus(ok_status, true);
	check('custom + all enabled rule sets valid → green "Downloaded"',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['green', 'Downloaded']);

	api.updateRulesetStatus({ rs_a: { valid: true }, rs_b: { valid: false } }, true);
	check('custom + one invalid rule set → red "Not downloaded"',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['red', 'Not downloaded']);

	/* No enabled rule sets at all: vacuously "Downloaded" — this is what a
	   fresh custom-mode install looks like, and it must not read as a failure. */
	api.updateRulesetStatus({}, true);
	check('custom + no enabled rule sets → green "Downloaded" (nothing to fetch)',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['green', 'Downloaded']);

	/* Non-custom modes: the built-in geo rule sets belong to the generator,
	   not to this card. */
	api.updateRulesetStatus({ rs_a: { valid: false } }, false);
	check('gfwlist/global + stale invalid user rule set → grey "-" (not applicable)',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['gray', '-']);

	api.updateRulesetStatus({}, false);
	check('gfwlist/global + nothing configured → grey "-"',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['gray', '-']);
}

/* ── the placeholder text must not survive into the "-" state ─────────── */
{
	const c = cells();
	const api = makeApi(c);

	api.updatePanelStatus({}, false);
	api.updateRulesetStatus({}, false);
	check('an inapplicable cell never keeps the "Collecting data..." placeholder',
		[c.homeproxy_panel_status.value, c.homeproxy_ruleset_status.value], ['-', '-']);
}

/* ── "RPC failed" must never be rendered as a definite state ──────────── */
/* The poll used to wrap every call in L.resolveDefault(call(), {}). That
   turns a failure into an *empty result*, and an empty result reads as a
   verdict: `{}` rule sets => zero iterations => ready stays true => green
   "Downloaded", while the plugin cannot tell whether the files are there.
   A stale rpcd after an upgrade (the new method does not exist yet) is
   exactly that case. Passing null instead makes the cells fall back to the
   same grey "-" as "not applicable", which claims nothing.

   Panel side: `{}` used to survive only because of a separate `!panel`
   guard; null covers it explicitly now.
   Core side: null used to be coerced to false by resolveDefault's default
   argument, painting a red "Not Running" for a core that may well be up. */
{
	const c = cells();
	const api = makeApi(c);

	api.updateRulesetStatus(null, true);
	check('rule-set RPC failed (null) → grey "-", never green "Downloaded"',
		[c.homeproxy_ruleset_status.style.color, c.homeproxy_ruleset_status.value], ['gray', '-']);

	api.updatePanelStatus(null, true);
	check('panel RPC failed (null) → grey "-"',
		[c.homeproxy_panel_status.style.color, c.homeproxy_panel_status.value], ['gray', '-']);

	api.updateCoreStatus(null);
	check('core RPC failed (null) → grey "-", not a red "Not Running"',
		[c.homeproxy_core_status.style.color, c.homeproxy_core_status.value], ['gray', '-']);
}

/* ── the poll must pass the mode-derived flags, not hardcoded true ────── */
{
	const poll = src.slice(src.indexOf("hp.pollAdd('client-status', statusPoll)") - 1400,
		src.indexOf("hp.pollAdd('client-status', statusPoll)"));

	check('statusPoll derives panelApplies from routing_mode',
		/panelApplies\s*=\s*\(routingMode === 'custom' \|\| routingMode === 'bypass_mainland_china'\)/.test(poll), true);
	check('statusPoll derives rulesetApplies from routing_mode (custom only)',
		/rulesetApplies\s*=\s*\(routingMode === 'custom'\)/.test(poll), true);
	check('statusPoll passes both flags to the updaters',
		/updatePanelStatus\(panel, panelApplies\)/.test(poll)
		&& /updateRulesetStatus\(rulesets, rulesetApplies\)/.test(poll), true);

	/* The failure path must reach the updaters as null. L.resolveDefault(fn, {})
	   would hand them an empty result instead, which they cannot distinguish
	   from a real "nothing configured" — see the null cases above. */
	check('statusPoll does not fold failures into {} via L.resolveDefault',
		!/L\.resolveDefault\s*\(\s*call(?:Panel|Ruleset)Status\(\)/.test(poll), true);
	check('statusPoll degrades each call to null on its own (Promise.all stays whole)',
		/callRulesetStatus\(\)\.then\(\s*\(v\)\s*=>\s*v,\s*\(\)\s*=>\s*null\s*\)/.test(poll), true);
}

/* ── ubus status codes must reject, or "permission denied" reads as data ─ */
/* rpc.js's `expect` only type-checks the reply and substitutes a default;
   a non-zero ubus status (6 = permission denied) is silently replaced by
   `expect['']` unless the declaration sets reject:true. Without it a denied
   call resolves to {} and lands in the green-"Downloaded" path above. */
{
	const decl = (name) => {
		const at = src.indexOf('const ' + name + ' = rpc.declare({');
		if (at < 0) return '';
		return src.slice(at, src.indexOf('});', at));
	};

	for (const name of ['callPanelStatus', 'callRulesetStatus']) {
		check(name + ' declares reject:true so ubus error codes surface as failures',
			/\breject:\s*true/.test(decl(name)), true);
	}
}

/* The declaration must reject on non-zero ubus codes, otherwise a denied
   service.list resolves to {} and lands in the false branch below. */
{
	const decl = (name) => {
		const at = src.indexOf('const ' + name + ' = rpc.declare({');
		if (at < 0) return '';
		return src.slice(at, src.indexOf('});', at));
	};

	check('callServiceList declares reject:true so ubus error codes surface as failures',
		/\breject:\s*true/.test(decl('callServiceList')), true);
}

/* ── getServiceStatus must yield three states, not two ─────────────────── */
/* updateCoreStatus(null) rendering grey "-" (asserted above) is only half
   the fix: the value reaching it comes from getServiceStatus(), which used
   L.resolveDefault(callServiceList('homeproxy'), {}). On failure that yields
   `{}`, the `res['homeproxy']['instances']` lookup throws a TypeError, the
   empty catch swallows it, and the function returns false — a *definite*
   "not running". So the poll painted a red "Not Running" for a core that
   may well be up, and the null branch was unreachable in practice.
   Here the RPC is injected and driven through all three outcomes. */
const asyncDone = (async () => {
	const run = (callServiceList) => makeApi(cells(), callServiceList).getServiceStatus();

	check('service.list reports the instance running → true',
		await run(() => Promise.resolve({ homeproxy: { instances: { 'sing-box-c': { running: true } } } })), true);

	check('service.list reports the instance stopped → false',
		await run(() => Promise.resolve({ homeproxy: { instances: { 'sing-box-c': { running: false } } } })), false);

	/* Registered service without the client instance: genuinely not running. */
	check('a registered service without the client instance → false',
		await run(() => Promise.resolve({ homeproxy: { instances: {} } })), false);

	/* The RPC itself failed (reject:true + ubus error / stale rpcd after an
	   upgrade). Must be "unknown" (null), never false. */
	check('a failed service.list → null, not a definite "not running"',
		await run(() => Promise.reject(new Error('Access denied'))), null);

	/* Source-level: the inner L.resolveDefault is what made this unreachable. */
	const fn = src.slice(src.indexOf('function getServiceStatus() {'),
		src.indexOf('function updateCoreStatus('));

	check('getServiceStatus does not fold a failed call into {} via L.resolveDefault',
		!/L\.resolveDefault/.test(fn), true);
	check('getServiceStatus returns null on rejection',
		/\}, \(\) => null\)/.test(fn), true);
})();

(async () => {
	if (asyncDone)
		await asyncDone;

	console.log('');
	console.log(failed === 0
		? 'status_card: all ' + passed + ' assertions passed'
		: 'status_card: ' + failed + ' of ' + (passed + failed) + ' assertions FAILED');

	process.exit(failed === 0 ? 0 : 1);
})();
