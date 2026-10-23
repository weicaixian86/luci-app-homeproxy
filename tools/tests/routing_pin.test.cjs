/*
 * Routing-node table DOM test for luci-app-homeproxy.
 *
 * Exercises the source of `pinFinalRoutingNode()` / `addPinBadge()` /
 * `lockFinalRow()` / `watchRoutingNodeOrder()` from client.js against three
 * table shapes LuCI actually renders:
 *
 *   - master / 25.12 : the name is a real <td class="...table-titles">
 *   - 24.10          : same, after hp.moveEnableColumn() materialises it
 *   - fallback       : no name cell at all (badge must still be rendered)
 *
 * Asserted behaviour:
 *   1. the route.final row is moved to the first position;
 *   2. the "No." column is renumbered 1..n in display order;
 *   3. the "Pinned" badge sits inside the name cell, right after the label;
 *   4. the pinned row's drag handle is neutralised and a dragstart on it is
 *      both defaultPrevented and never reaches its listener;
 *   5. other rows stay draggable;
 *   6. after LuCI moves a row by DOM surgery (no re-render), the
 *      MutationObserver pulls the pinned row back to the top.
 *
 * Run: node tools/tests/routing_pin.test.cjs
 * Requires `jsdom` (npm install jsdom); exits 0 with SKIP when unavailable.
 */

'use strict';

const fs = require('fs');
const path = require('path');

let JSDOM;
try {
	({ JSDOM } = require('jsdom'));
}
catch (err) {
	console.log('SKIP routing_pin: jsdom is not installed (npm install jsdom)');
	process.exit(0);
}

/* <repo>/tools/tests/ -> <repo>/luci-app-homeproxy/htdocs/... */
const CLIENT = path.resolve(__dirname, '..', '..', 'luci-app-homeproxy',
	'htdocs', 'luci-static', 'resources', 'view', 'homeproxy', 'client.js');

const src = fs.readFileSync(CLIENT, 'utf8');

const start = src.indexOf('const addPinBadge = function');
const endObserver = src.indexOf('ss.renderContents = function() {');

if (start < 0 || endObserver < 0 || endObserver <= start) {
	console.error('FAIL routing_pin: cannot locate the pin helpers in client.js '
		+ '(markers "const addPinBadge = function" / "ss.renderContents = function() {" changed)');
	process.exit(1);
}

/* Block used by the synchronous table test: helpers + pinFinalRoutingNode. */
const pinBlock = src.slice(start, src.indexOf('/* 排序落盘后（DOM 已被 luci 直接搬动、不会重绘）重新置顶并重编号。 */'));
/* Wider block also containing watchRoutingNodeOrder() for the observer test. */
const watchBlock = src.slice(start, endObserver);

if (!pinBlock.includes('pinFinalRoutingNode') || !watchBlock.includes('watchRoutingNodeOrder')) {
	console.error('FAIL routing_pin: extracted block is missing pinFinalRoutingNode/watchRoutingNodeOrder');
	process.exit(1);
}

const FINAL = 'cfg8fd1';
const dom = new JSDOM('<!doctype html><html><body></body></html>');
const { document } = dom.window;

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

/* Minimal E() implementation: enough for the row markup below. */
function E(tag, props, children) {
	const el = document.createElement(tag);

	if (props && typeof props === 'object' && !Array.isArray(props)) {
		for (const key in props) {
			if (key === 'class')
				el.className = props[key];
			else if (key === 'style')
				el.setAttribute('style', props[key]);
			else if (props[key] != null)
				el.setAttribute(key, props[key]);
		}
	}

	if (children != null) {
		(Array.isArray(children) ? children : [children]).forEach((child) => {
			if (child == null)
				return;
			el.appendChild(typeof child === 'object' ? child : document.createTextNode(String(child)));
		});
	}

	return el;
}

let finalHandleListenerCalls = 0;
let otherHandleListenerCalls = 0;

function makeRow(sid, label, opts) {
	opts = opts || {};

	const tr = document.createElement('tr');
	tr.className = 'tr cbi-section-table-row';
	tr.setAttribute('data-sid', sid);

	tr.appendChild(E('td', { class: 'td hp-index-cell' }, '0'));
	tr.appendChild(E('td', { class: 'td', 'data-name': 'enabled' }, E('input', { 'type': 'checkbox' })));

	if (!opts.noNameCell)
		tr.appendChild(E('td', { class: 'td cbi-value-field cbi-section-table-titles' }, label));

	tr.appendChild(E('td', { class: 'td' }, 'selector'));

	const actions = E('td', { class: 'td cbi-section-table-cell nowrap cbi-section-actions' }, E('div'));
	const handle = E('button', { class: 'cbi-button drag-handle center', draggable: 'true' }, '\u2630');

	handle.addEventListener('dragstart', () => {
		if (sid === FINAL)
			finalHandleListenerCalls++;
		else
			otherHandleListenerCalls++;
	});

	actions.firstChild.appendChild(handle);
	tr.appendChild(actions);

	return tr;
}

function buildTable(rows) {
	const wrapper = document.createElement('div');
	const table = E('table', { class: 'table cbi-section-table' });
	const thead = E('thead');
	const headerRow = E('tr', { class: 'tr cbi-section-table-titles named' });

	['No.', '', 'Label', 'Type', ''].forEach((text) => headerRow.appendChild(E('th', { class: 'th' }, text)));

	thead.appendChild(headerRow);
	table.appendChild(thead);

	const tbody = document.createElement('tbody');
	tbody.className = 'tbody cbi-section-tbody';
	rows.forEach((row) => tbody.appendChild(row));
	table.appendChild(tbody);
	wrapper.appendChild(table);

	return wrapper;
}

function compile(block, names) {
	/* Fake gettext: only "Pinned" is translated, which is enough to prove the
	   badge really comes from the catalog and not from a hard-coded literal. */
	const translate = (text) => (text === 'Pinned') ? '置顶' : text;

	return new Function('E', '_', 'uci', 'data', 'document', 'MutationObserver',
		block + '\nreturn { ' + names.join(', ') + ' };')(
		E, translate, { get: () => FINAL }, ['homeproxy'], document, dom.window.MutationObserver);
}

/* ------------------------------------------------------------------ */
/* 1) synchronous pin behaviour, three table shapes                    */
/* ------------------------------------------------------------------ */

function testPinnedTable() {
	const helpers = compile(pinBlock, ['pinFinalRoutingNode']);
	const variants = [
		{ name: 'master/25.12 (real name cell)', noNameCell: false },
		{ name: '24.10 (name cell added by moveEnableColumn)', noNameCell: false },
		{ name: 'fallback (no name cell)', noNameCell: true }
	];

	for (const variant of variants) {
		console.log('\n[' + variant.name + ']');
		finalHandleListenerCalls = 0;
		otherHandleListenerCalls = 0;

		const wrapper = buildTable([
			makeRow('cfgA', 'Telegram', variant),
			makeRow('cfgB', 'Twitter', variant),
			makeRow(FINAL, 'Default proxy', variant),
			makeRow('cfgC', 'GitHub', variant)
		]);
		document.body.appendChild(wrapper);

		helpers.pinFinalRoutingNode(wrapper);

		const rows = Array.from(wrapper.querySelectorAll('tbody tr'));
		const order = rows.map((row) => row.getAttribute('data-sid'));
		const first = rows[0];
		const indices = Array.from(wrapper.querySelectorAll('td.hp-index-cell')).map((td) => td.textContent);
		const expectedIndices = rows.map((row, idx) => String(idx + 1));

		check('pinned row became the first row', order[0] === FINAL, order.join(','));
		check('all rows kept (no row lost)', rows.length === 4, String(rows.length));
		check('index column renumbered 1..n', indices.join(',') === expectedIndices.join(','), indices.join(','));

		const badge = first.querySelector('.hp-pin-badge');
		const nameCell = first.querySelector('td.cbi-section-table-titles');

		check('pinned badge is rendered', !!badge);
		check('badge text is the localized "Pinned"', badge != null && badge.textContent.trim() === '置顶',
			badge != null ? badge.textContent : 'none');

		if (!variant.noNameCell) {
			check('badge lives inside the name cell', badge != null && nameCell != null && nameCell.contains(badge));
			check('badge follows the label text', nameCell != null && badge != null && nameCell.lastElementChild === badge);
		}

		const handle = first.querySelector('.drag-handle');
		/* The pinned row's handle is hidden outright (display:none) rather than
		   greyed out; the clone keeps draggable="false" as a second line of
		   defence. */
		check('pinned row handle is hidden',
			handle != null && handle.getAttribute('draggable') === 'false'
				&& handle.style.display === 'none' && handle.dataset.hpDead === '1',
			handle != null ? handle.getAttribute('draggable') + '/' + handle.style.display + '/' + handle.dataset.hpDead : 'none');

		const pinnedEvt = new dom.window.Event('dragstart', { bubbles: true, cancelable: true });
		if (handle != null)
			handle.dispatchEvent(pinnedEvt);

		check('dragstart on the pinned handle is prevented', pinnedEvt.defaultPrevented === true);
		check('dragstart on the pinned handle never reaches its listener', finalHandleListenerCalls === 0,
			'calls=' + finalHandleListenerCalls);

		const otherHandle = wrapper.querySelector('tbody tr[data-sid="cfgB"] .drag-handle');
		const otherEvt = new dom.window.Event('dragstart', { bubbles: true, cancelable: true });
		if (otherHandle != null)
			otherHandle.dispatchEvent(otherEvt);

		check('other rows remain draggable', otherEvt.defaultPrevented === false);
		check('other rows keep their drag listener', otherHandleListenerCalls === 1, 'calls=' + otherHandleListenerCalls);

		document.body.removeChild(wrapper);
	}
}

/* ------------------------------------------------------------------ */
/* 2) MutationObserver pull-back after LuCI moves a row                */
/* ------------------------------------------------------------------ */

function testObserverPullBack() {
	return new Promise((resolve) => {
		console.log('\n[observer pull-back after drag]');

		const helpers = compile(watchBlock, ['pinFinalRoutingNode', 'watchRoutingNodeOrder']);
		const wrapper = buildTable([
			makeRow('cfgA', 'Telegram'),
			makeRow('cfgB', 'Twitter'),
			makeRow(FINAL, 'Default proxy'),
			makeRow('cfgC', 'GitHub')
		]);
		document.body.appendChild(wrapper);

		const tbody = wrapper.querySelector('tbody');
		const order = () => Array.from(tbody.querySelectorAll('tr')).map((row) => row.getAttribute('data-sid')).join(',');

		helpers.pinFinalRoutingNode(wrapper);
		helpers.watchRoutingNodeOrder(wrapper);
		check('initially pinned first', order().split(',')[0] === FINAL, order());

		/* Simulate luci's handleDrop(): plain insertBefore, no re-render. */
		const moved = tbody.querySelector('tr[data-sid="cfgB"]');
		tbody.insertBefore(moved, tbody.firstElementChild);

		setTimeout(() => {
			const rows = tbody.querySelectorAll('tr');
			const indices = Array.from(tbody.querySelectorAll('td.hp-index-cell')).map((td) => td.textContent);

			check('pinned row pulled back to the top', order().split(',')[0] === FINAL, order());
			check('observer renumbered the index column',
				indices.join(',') === Array.from(rows).map((row, idx) => String(idx + 1)).join(','), indices.join(','));
			check('exactly one pinned badge after pull-back',
				wrapper.querySelectorAll('.hp-pin-badge').length === 1,
				String(wrapper.querySelectorAll('.hp-pin-badge').length));

			document.body.removeChild(wrapper);
			resolve();
		}, 50);
	});
}

(async () => {
	testPinnedTable();
	await testObserverPullBack();

	console.log('');
	if (failures) {
		console.log('routing_pin: FAILED (' + failures + ' assertion(s))');
		process.exit(1);
	}

	console.log('routing_pin: all assertions passed');
	process.exit(0);
})();
