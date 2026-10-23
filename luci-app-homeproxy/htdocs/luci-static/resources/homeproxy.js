/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require baseclass';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';

function pad2(value) {
	value = (value == null) ? '' : String(value).trim();
	return value.length === 1 ? '0' + value : value;
}

function normalizeTimePart(value, min, max) {
	value = parseInt(String(value || '').trim(), 10);
	if (isNaN(value))
		value = min;
	value = Math.max(min, Math.min(max, value));
	return pad2(value);
}

function parseCron(value) {
	const matched = String(value || '').trim().match(/^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+([0-7*])$/);
	if (!matched)
		return null;

	const minute = +matched[1],
	      hour = +matched[2];
	if (minute < 0 || minute > 59 || hour < 0 || hour > 23)
		return null;

	return {
		minute: normalizeTimePart(matched[1], 0, 59),
		hour: normalizeTimePart(matched[2], 0, 23),
		day: matched[3] === '*' ? '*' : (matched[3] === '7' ? '0' : matched[3])
	};
}

function buildCron(day, hour, minute) {
	return [
		normalizeTimePart(minute, 0, 59),
		normalizeTimePart(hour, 0, 23),
		'*',
		'*',
		String(day || '*')
	].join(' ');
}

function alignCronEditorRow(wrap) {
	let field = wrap?.parentNode;

	while (field && !field.classList?.contains('cbi-value-field'))
		field = field.parentNode;

	let row = field?.parentNode;
	while (row && !row.classList?.contains('cbi-value'))
		row = row.parentNode;

	if (!row || !field)
		return false;

	if (wrap._dailyRow) {
		wrap._dailyRow.style.display = row.style.display;
		return true;
	}

	let dailyRow = E('div', { 'class': 'cbi-value homeproxy-cron-daily-row' }, [
		E('div', { 'class': 'cbi-value-title' }, _('Update time (daily)')),
		E('div', { 'class': 'cbi-value-field' }, [ wrap._dailyField ])
	]);

	wrap._dailyRow = dailyRow;
	row.parentNode.insertBefore(dailyRow, row.nextSibling);

	return true;
}

function watchCronEditorRow(wrap) {
	const align = () => alignCronEditorRow(wrap);
	[ 0, 50, 200, 500, 1000, 2000 ].forEach(delay => window.setTimeout(align, delay));

	if (typeof MutationObserver !== 'undefined' && document?.body) {
		const observer = new MutationObserver(() => {
			if (align())
				observer.disconnect();
		});

		observer.observe(document.body, { childList: true, subtree: true });
		window.setTimeout(() => observer.disconnect(), 3000);
	}
}

function renderCronEditor(input) {
	if (!input)
		return null;

	const parsed = parseCron(input.value);
	input.type = 'text';
	input.readOnly = true;
	input.tabIndex = -1;
	input.style.position = 'absolute';
	input.style.opacity = '0';
	input.style.pointerEvents = 'none';
	input.style.width = '1px';
	input.style.height = '1px';
	input.style.minWidth = '1px';
	input.style.maxWidth = '1px';
	input.style.padding = '0';
	input.style.border = '0';

	/* 两小时/分钟下拉固定 5.2em。原来 4.25em 在字号偏小的主题（如 Argon
	   的 11px）下只有约 47px，而主题给 select 右侧箭头留的内边距是固定的
	   像素值（约 24px），剩下的空间放不下「04」，后半个数字会被裁掉。
	   这里同时加大宽度并把左右内边距显式写成 em：右侧 1.7em 给箭头留位，
	   左侧 .45em 不贴边，字号再变也不会再压缩文字区。 */
	const timeSelectStyle = 'width: 5.2em !important; min-width: 5.2em !important; max-width: 5.2em !important; '
		+ 'box-sizing: border-box; padding-left: .45em !important; padding-right: 1.7em !important; text-align: left;';

	let day = E('select', { 'class': 'cbi-input-select', 'style': 'width: 12em !important; min-width: 12em !important; max-width: 12em !important; box-sizing: border-box;' }),
	    hour = E('select', { 'class': 'cbi-input-select', 'style': timeSelectStyle }),
	    minute = E('select', { 'class': 'cbi-input-select', 'style': timeSelectStyle }),
	    dailyField = E('div', { 'style': 'display: flex; align-items: center; gap: .3em; width: 12em; flex: 0 0 auto;' }, [
		hour,
		E('span', ':'),
		minute
	    ]),
	    wrap = E('div', { 'class': 'homeproxy-cron-editor' }, [ day ]);

	wrap._dailyField = dailyField;

	for (let i = 0; i < 24; i++)
		hour.appendChild(E('option', { value: pad2(i) }, pad2(i)));

	for (let i = 0; i < 60; i++)
		minute.appendChild(E('option', { value: pad2(i) }, pad2(i)));

	[
		['*', _('Every day')],
		['1', _('Every Monday')],
		['2', _('Every Tuesday')],
		['3', _('Every Wednesday')],
		['4', _('Every Thursday')],
		['5', _('Every Friday')],
		['6', _('Every Saturday')],
		['0', _('Every Sunday')]
	].forEach(([value, label]) => day.appendChild(E('option', { value }, label)));

	day.value = parsed ? parsed.day : '*';
	hour.value = parsed ? parsed.hour : '00';
	minute.value = parsed ? parsed.minute : '00';
	input.value = buildCron(day.value, hour.value, minute.value);
	input.setAttribute('value', input.value);

	const sync = () => {
		input.value = buildCron(day.value, hour.value, minute.value);
		input.setAttribute('value', input.value);
		input.dispatchEvent(new Event('input', { bubbles: true }));
		input.dispatchEvent(new Event('change', { bubbles: true }));
	};

	day.addEventListener('change', sync);
	hour.addEventListener('change', sync);
	minute.addEventListener('change', sync);
	wrap.appendChild(input);
	window.setTimeout(() => watchCronEditorRow(wrap), 0);
	return wrap;
}

/* LuCI 原生多选下拉（ui.Dropdown multiple）在保存时，是按选项在列表中的固定
   顺序（choices/keylist 顺序）遍历 li[selected] 生成隐藏域的，与用户勾选的
   先后无关；折叠状态下露出的标签、展开后的预览条，同样是按 li 在 DOM 里的
   位置排列的。于是"先勾默认代理、再勾日本自动"在配置和面板里都还是原始列表
   顺序，"第一个勾选的节点为默认出口"自然也就不成立。

   这里重写 saveValues()，做两件事：
   1) 用 this.order 记录勾选先后——仍被勾选的项保持原有相对顺序，新勾选的项
      追加到末尾；按该顺序重建隐藏域，使 getValue()（LuCI 表单的 formvalue）
      返回勾选顺序，后端照抄数组顺序生成 outbounds 即可；
   2) 按同一顺序把已勾选的 li 重排到最前（未勾选的保持原有相对顺序），并重新
      分配 display 属性、同步重建展开时的 ul.preview 副本。因为 LuCI 的折叠
      标签和预览条都只看 DOM 位置，只有真正挪动节点才能让界面上的顺序跟着变。
      副作用是已勾选的项会聚拢在选项列表前部，正好也方便看出谁是第一个。 */
const OrderedMultiDropdown = ui.Dropdown.extend({
	__name__: 'LuCI.HomeProxyOrderedMultiDropdown',

	__init__(value, choices, options) {
		this.super('__init__', [ value, choices, options ]);

		/* 初始顺序沿用配置里已保存的顺序 */
		this.order = Array.isArray(this.values) ? this.values.slice() : [];
		this._assigning = false;
	},

	/* 代码赋值（重新载入、迁移）时以给定顺序为准 */
	setValue(values) {
		let list;

		if (Array.isArray(values))
			list = values.slice();
		else
			list = (values != null && values !== '') ? [ values ] : [];

		/* LuCI 的 setValue() → setValues() 会逐项 toggleItem()，每一轮都回调
		   saveValues()；那时新顺序还没落定，重排只会白做（还可能被逐项收窄的
		   中间态污染）。先挂起，等底层赋值完成后统一按 list 重排。 */
		this._assigning = true;

		const ret = this.super('setValue', [ values ]);

		this._assigning = false;
		this.order = list;

		if (this.node)
			this.saveValues(this.node, this.node.querySelector('ul'));

		return ret;
	},

	saveValues(sb, ul) {
		this.super('saveValues', [ sb, ul ]);

		const div = sb.lastElementChild,
		      inputs = div.querySelectorAll('input[type="hidden"]'),
		      selected = [];

		for (let i = 0; i < inputs.length; i++)
			selected.push(inputs[i].value);

		/* 仍被勾选的保持原相对顺序，新勾选的追加到末尾 */
		const order = [];

		for (let i = 0; i < this.order.length; i++) {
			const value = this.order[i];

			if (selected.indexOf(value) > -1 && order.indexOf(value) < 0)
				order.push(value);
		}

		for (let i = 0; i < selected.length; i++) {
			const value = selected[i];

			if (order.indexOf(value) < 0)
				order.push(value);
		}

		this.order = order;

		if (this._assigning)
			return;

		/* 按勾选顺序重建隐藏域 */
		while (div.lastElementChild)
			div.removeChild(div.lastElementChild);

		for (let i = 0; i < order.length; i++)
			div.appendChild(E('input', {
				type: 'hidden',
				name: this.options.name,
				value: order[i]
			}));

		this.applyOrder(sb, ul);
	},

	/* 把已勾选的 li 按 this.order 排到最前，并同步 display 属性与预览副本。
	   LuCI 折叠标签/预览条的顺序完全取决于 li 的 DOM 位置和 display 属性，
	   所以必须真正挪节点，改 CSS order 是不生效的（预览条是 block 布局）。 */
	applyOrder(sb, ul) {
		if (!ul || !this.options.multiple)
			return;

		const items = ul.querySelectorAll('li[data-value]'),
		      rank = {},
		      all = [],
		      picked = [];

		for (let i = 0; i < this.order.length; i++)
			rank[this.order[i]] = i;

		for (let i = 0; i < items.length; i++) {
			all.push(items[i]);

			if (items[i].hasAttribute('selected'))
				picked.push(items[i]);
		}

		/* 只有一个（或零个）已选项时无所谓顺序，不必动 DOM */
		if (picked.length < 2)
			return;

		/* 记住 DOM 中最靠前的已选项，重排后就以它为锚点 */
		const anchor = picked[0];

		picked.sort((a, b) => {
			const ra = rank[a.getAttribute('data-value')] ?? 9999,
			      rb = rank[b.getAttribute('data-value')] ?? 9999;

			return ra - rb;
		});

		/* 已选项聚拢在锚点位置，未选项相对顺序不变 */
		const at = all.indexOf(anchor),
		      rest = all.filter(li => picked.indexOf(li) < 0);

		/* 锚点之前的项都是未选项，故锚点在 rest 中的落点就是它在 DOM 中的下标 */
		rest.splice(at, 0, ...picked);

		for (let i = 0; i < rest.length; i++)
			ul.appendChild(rest[i]);

		/* 重新分配 display：只有前 display_items 个已选项在折叠状态可见 */
		let ndisplay = this.options.display_items;

		for (let i = 0; i < rest.length; i++)
			rest[i].removeAttribute('display');

		for (let i = 0; i < picked.length && ndisplay > 0; i++, ndisplay--)
			picked[i].setAttribute('display', i);

		/* 展开时露出的标签是 ul.preview 的克隆，由 toggleItem() 按旧顺序拼好，
		   这里按新顺序重建，保证展开/折叠两种状态看到的一致 */
		const preview = sb.querySelector('ul.preview');

		if (preview) {
			while (preview.firstElementChild)
				preview.removeChild(preview.firstElementChild);

			for (let i = 0; i < picked.length && i < this.options.display_items; i++)
				if (picked[i].hasAttribute('display'))
					preview.appendChild(picked[i].cloneNode(true));
		}
	}
});

return baseclass.extend({
	/* Registry backing hp.pollAdd(), keyed by caller-chosen name. */
	poll_handles: {},

	/**
	 * Register a poll callback under a stable name.
	 *
	 * LuCI's poll.add() only de-duplicates by function identity, so a callback
	 * created inside a section's render() (a fresh closure on every
	 * re-render, e.g. after "Save & Apply") accumulates one extra entry per
	 * render and fires several RPCs per tick. Registering through this helper
	 * removes the previous callback for the same key first.
	 *
	 * @param {string} key    stable name, e.g. 'client-status'
	 * @param {function} fn   callback to run on each poll tick
	 * @param {number} [interval] optional interval in seconds
	 * @returns {boolean} true when the callback is registered
	 */
	pollAdd(key, fn, interval) {
		if (typeof fn !== 'function')
			return false;

		if (!this.poll_handles)
			this.poll_handles = {};

		const previous = this.poll_handles[key];

		/* Same function object: poll.add() itself de-duplicates, but do not
		   touch the queue at all in that case. */
		if (previous === fn)
			return true;

		if (previous) {
			/* Without poll.remove() (very old LuCI) re-registering would stack
			   callbacks, so keep the first one instead. */
			if (typeof poll.remove !== 'function')
				return false;

			try {
				poll.remove(previous);
			}
			catch (e) {}
		}

		this.poll_handles[key] = fn;

		return poll.add(fn, interval);
	},

	/**
	 * Drop a previously registered poll callback (page teardown, opt-out).
	 *
	 * @param {string} key
	 * @returns {boolean} true when a callback was removed
	 */
	pollRemove(key) {
		const fn = this.poll_handles ? this.poll_handles[key] : null;

		if (!fn)
			return false;

		delete this.poll_handles[key];

		if (typeof poll.remove === 'function')
			try {
				poll.remove(fn);
			}
			catch (e) {}

		return true;
	},

	/**
	 * Build the small grey line that shows *why* a DNS latency probe failed.
	 *
	 * Previously the reason only lived in a title attribute, so a screenshot of
	 * "Failed / Failed / Failed" said nothing about whether rpcd had the new
	 * method loaded, whether curl was missing, or whether the address was simply
	 * unreachable. Truncated so a long curl error cannot blow up the table.
	 *
	 * @param {string} msg full error text
	 * @returns {Node}
	 */
	dnsFailDetail(msg) {
		const text = String(msg || '');
		const brief = (text.length > 60) ? (text.slice(0, 57) + '...') : text;

		/* Plain DOM on purpose: this module does not require 'dom', so the
		   global E() helper is not guaranteed to be in scope here. */
		const span = document.createElement('span');

		span.className = 'hp-dns-err-detail';
		span.title = text;
		span.textContent = brief;

		return span;
	},

	dns_strategy: {
		'': _('Default'),
		'prefer_ipv4': _('Prefer IPv4'),
		'prefer_ipv6': _('Prefer IPv6'),
		'ipv4_only': _('IPv4 only'),
		'ipv6_only': _('IPv6 only')
	},

	shadowsocks_encrypt_length: {
		/* AEAD */
		'aes-128-gcm': 0,
		'aes-192-gcm': 0,
		'aes-256-gcm': 0,
		'chacha20-ietf-poly1305': 0,
		'xchacha20-ietf-poly1305': 0,
		/* AEAD 2022 */
		'2022-blake3-aes-128-gcm': 16,
		'2022-blake3-aes-256-gcm': 32,
		'2022-blake3-chacha20-poly1305': 32
	},

	shadowsocks_encrypt_methods: [
		/* Stream */
		'none',
		/* AEAD */
		'aes-128-gcm',
		'aes-192-gcm',
		'aes-256-gcm',
		'chacha20-ietf-poly1305',
		'xchacha20-ietf-poly1305',
		/* AEAD 2022 */
		'2022-blake3-aes-128-gcm',
		'2022-blake3-aes-256-gcm',
		'2022-blake3-chacha20-poly1305'
	],

	tls_cipher_suites: [
		'TLS_RSA_WITH_AES_128_CBC_SHA',
		'TLS_RSA_WITH_AES_256_CBC_SHA',
		'TLS_RSA_WITH_AES_128_GCM_SHA256',
		'TLS_RSA_WITH_AES_256_GCM_SHA384',
		'TLS_AES_128_GCM_SHA256',
		'TLS_AES_256_GCM_SHA384',
		'TLS_CHACHA20_POLY1305_SHA256',
		'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA',
		'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA',
		'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA',
		'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA',
		'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
		'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
		'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
		'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
		'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256',
		'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256'
	],

	tls_versions: [
		'1.0',
		'1.1',
		'1.2',
		'1.3'
	],

	CBIStaticList: form.DynamicList.extend({
		__name__: 'CBI.StaticList',

		renderWidget: function(/* ... */) {
			let dl = form.DynamicList.prototype.renderWidget.apply(this, arguments);
			dl.querySelector('.add-item ul > li[data-value="-"]')?.remove();
			return dl;
		}
	}),

	CBIMultiValue: form.MultiValue.extend({
		__name__: 'CBI.HomeProxyMultiValue',

		renderWidget(section_id, _option_index, cfgvalue) {
			let value = (cfgvalue != null) ? cfgvalue : this.default,
			    choices = this.transformChoices() || {},
			    widget = new OrderedMultiDropdown(L.toArray(value), choices, {
				id: this.cbid(section_id),
				sort: this.keylist,
				multiple: true,
				optional: this.optional || this.rmempty,
				select_placeholder: this.placeholder,
				create: this.create,
				display_items: this.display_size ?? this.size ?? 3,
				dropdown_items: this.dropdown_size ?? this.size ?? -1,
				validate: this.getValidator(section_id),
				disabled: (this.readonly != null) ? this.readonly : this.map.readonly
			});

			return widget.render();
		}
	}),

	calcStringMD5(e) {
		/* Thanks to https://stackoverflow.com/a/41602636 */
		let h = (a, b) => {
			let c, d, e, f, g;
			c = a & 2147483648;
			d = b & 2147483648;
			e = a & 1073741824;
			f = b & 1073741824;
			g = (a & 1073741823) + (b & 1073741823);
			return e & f ? g ^ 2147483648 ^ c ^ d : e | f ? g & 1073741824 ? g ^ 3221225472 ^ c ^ d : g ^ 1073741824 ^ c ^ d : g ^ c ^ d;
		}, k = (a, b, c, d, e, f, g) => h((a = h(a, h(h(b & c | ~b & d, e), g))) << f | a >>> 32 - f, b),
		l = (a, b, c, d, e, f, g) => h((a = h(a, h(h(b & d | c & ~d, e), g))) << f | a >>> 32 - f, b),
		m = (a, b, c, d, e, f, g) => h((a = h(a, h(h(b ^ c ^ d, e), g))) << f | a >>> 32 - f, b),
		n = (a, b, c, d, e, f, g) => h((a = h(a, h(h(c ^ (b | ~d), e), g))) << f | a >>> 32 - f, b),
		p = a => { let b = '', d = ''; for (let c = 0; c <= 3; c++) d = a >>> 8 * c & 255, d = '0' + d.toString(16), b += d.substr(d.length - 2, 2); return b; };

		let f = [], q, r, s, t, a, b, c, d;
		e = (() => {
			e = e.replace(/\r\n/g, '\n');
			let b = '';
			for (let d = 0; d < e.length; d++) {
				let c = e.charCodeAt(d);
				b += c < 128 ? String.fromCharCode(c) : c < 2048 ? String.fromCharCode(c >> 6 | 192) + String.fromCharCode(c & 63 | 128) :
					String.fromCharCode(c >> 12 | 224) + String.fromCharCode(c >> 6 & 63 | 128) + String.fromCharCode(c & 63 | 128);
			}
			return b;
		})();
		f = (() => {
			let c = e.length, a = c + 8, d = 16 * ((a - a % 64) / 64 + 1), b = Array(d - 1), f = 0, g = 0;
			for (; g < c;) a = (g - g % 4) / 4, f = g % 4 * 8, b[a] |= e.charCodeAt(g) << f, g++;
			a = (g - g % 4) / 4, b[a] |= 128 << g % 4 * 8, b[d - 2] = c << 3, b[d - 1] = c >>> 29;
			return b;
		})();

		a = 1732584193, b = 4023233417, c = 2562383102, d = 271733878;
		for (e = 0; e < f.length; e += 16) {
			q = a, r = b, s = c, t = d;
			a = k(a, b, c, d, f[e +  0],  7, 3614090360), d = k(d, a, b, c, f[e +  1], 12, 3905402710),
			c = k(c, d, a, b, f[e +  2], 17,  606105819), b = k(b, c, d, a, f[e +  3], 22, 3250441966),
			a = k(a, b, c, d, f[e +  4],  7, 4118548399), d = k(d, a, b, c, f[e +  5], 12, 1200080426),
			c = k(c, d, a, b, f[e +  6], 17, 2821735955), b = k(b, c, d, a, f[e +  7], 22, 4249261313),
			a = k(a, b, c, d, f[e +  8],  7, 1770035416), d = k(d, a, b, c, f[e +  9], 12, 2336552879),
			c = k(c, d, a, b, f[e + 10], 17, 4294925233), b = k(b, c, d, a, f[e + 11], 22, 2304563134),
			a = k(a, b, c, d, f[e + 12],  7, 1804603682), d = k(d, a, b, c, f[e + 13], 12, 4254626195),
			c = k(c, d, a, b, f[e + 14], 17, 2792965006), b = k(b, c, d, a, f[e + 15], 22, 1236535329),
			a = l(a, b, c, d, f[e +  1],  5, 4129170786), d = l(d, a, b, c, f[e +  6],  9, 3225465664),
			c = l(c, d, a, b, f[e + 11], 14,  643717713), b = l(b, c, d, a, f[e +  0], 20, 3921069994),
			a = l(a, b, c, d, f[e +  5],  5, 3593408605), d = l(d, a, b, c, f[e + 10],  9,   38016083),
			c = l(c, d, a, b, f[e + 15], 14, 3634488961), b = l(b, c, d, a, f[e +  4], 20, 3889429448),
			a = l(a, b, c, d, f[e +  9],  5,  568446438), d = l(d, a, b, c, f[e + 14],  9, 3275163606),
			c = l(c, d, a, b, f[e +  3], 14, 4107603335), b = l(b, c, d, a, f[e +  8], 20, 1163531501),
			a = l(a, b, c, d, f[e + 13],  5, 2850285829), d = l(d, a, b, c, f[e +  2],  9, 4243563512),
			c = l(c, d, a, b, f[e +  7], 14, 1735328473), b = l(b, c, d, a, f[e + 12], 20, 2368359562),
			a = m(a, b, c, d, f[e +  5],  4, 4294588738), d = m(d, a, b, c, f[e +  8], 11, 2272392833),
			c = m(c, d, a, b, f[e + 11], 16, 1839030562), b = m(b, c, d, a, f[e + 14], 23, 4259657740),
			a = m(a, b, c, d, f[e +  1],  4, 2763975236), d = m(d, a, b, c, f[e +  4], 11, 1272893353),
			c = m(c, d, a, b, f[e +  7], 16, 4139469664), b = m(b, c, d, a, f[e + 10], 23, 3200236656),
			a = m(a, b, c, d, f[e + 13],  4,  681279174), d = m(d, a, b, c, f[e +  0], 11, 3936430074),
			c = m(c, d, a, b, f[e +  3], 16, 3572445317), b = m(b, c, d, a, f[e +  6], 23,   76029189),
			a = m(a, b, c, d, f[e +  9],  4, 3654602809), d = m(d, a, b, c, f[e + 12], 11, 3873151461),
			c = m(c, d, a, b, f[e + 15], 16,  530742520), b = m(b, c, d, a, f[e +  2], 23, 3299628645),
			a = n(a, b, c, d, f[e +  0],  6, 4096336452), d = n(d, a, b, c, f[e +  7], 10, 1126891415),
			c = n(c, d, a, b, f[e + 14], 15, 2878612391), b = n(b, c, d, a, f[e +  5], 21, 4237533241),
			a = n(a, b, c, d, f[e + 12],  6, 1700485571), d = n(d, a, b, c, f[e +  3], 10, 2399980690),
			c = n(c, d, a, b, f[e + 10], 15, 4293915773), b = n(b, c, d, a, f[e +  1], 21, 2240044497),
			a = n(a, b, c, d, f[e +  8],  6, 1873313359), d = n(d, a, b, c, f[e + 15], 10, 4264355552),
			c = n(c, d, a, b, f[e +  6], 15, 2734768916), b = n(b, c, d, a, f[e + 13], 21, 1309151649),
			a = n(a, b, c, d, f[e +  4],  6, 4149444226), d = n(d, a, b, c, f[e + 11], 10, 3174756917),
			c = n(c, d, a, b, f[e +  2], 15,  718787259), b = n(b, c, d, a, f[e +  9], 21, 3951481745),
			a = h(a, q), b = h(b, r), c = h(c, s), d = h(d, t);
		}
		return (p(a) + p(b) + p(c) + p(d)).toLowerCase();
	},

	decodeBase64Str(str) {
		if (!str)
			return null;

		/* Thanks to luci-app-ssr-plus */
		str = str.replace(/-/g, '+').replace(/_/g, '/');
		let padding = (4 - str.length % 4) % 4;
		if (padding)
			str = str + Array(padding + 1).join('=');

		return decodeURIComponent(Array.prototype.map.call(atob(str), (c) =>
			'%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2)
		).join(''));
	},

	getBuiltinFeatures() {
		const callGetSingBoxFeatures = rpc.declare({
			object: 'luci.homeproxy',
			method: 'singbox_get_features',
			expect: { '': {} }
		});

		return L.resolveDefault(callGetSingBoxFeatures(), {});
	},

	renderCronSelector(/* ... */) {
		if (!this._homeproxyCronOriginalFormvalue) {
			this._homeproxyCronOriginalFormvalue = this.formvalue;
			this.formvalue = function(section_id) {
				let cbid = this.cbid(section_id),
				    ids = [ cbid, 'widget.' + cbid ],
				    roots = [ document.getElementById('modal_overlay'), document ],
				    input = null;

				for (let root of roots) {
					if (!root)
						continue;

					for (let el of root.querySelectorAll('input')) {
						if (ids.includes(el.id) || ids.includes(el.name)) {
							input = el;
							break;
						}
					}

					if (input)
						break;
				}

				let value = input?.value ||
					this._homeproxyCronOriginalFormvalue?.call(this, section_id) ||
					this.default ||
					'0 0 * * *';

				return parseCron(value) ? value : (this.default || '0 0 * * *');
			};
		}

		let node = form.Value.prototype.renderWidget.apply(this, arguments),
		    editor = renderCronEditor(node.querySelector('input'));

		return editor || node;
	},

	renderCronSelectorRow(/* ... */) {
		return form.Value.prototype.render.apply(this, arguments);
	},

	generateRand(type, length) {
		let byteArr;
		if (['base64', 'hex'].includes(type))
			byteArr = crypto.getRandomValues(new Uint8Array(length));
		switch (type) {
			case 'base64':
				/* Thanks to https://stackoverflow.com/questions/9267899 */
				return btoa(String.fromCharCode.apply(null, byteArr));
			case 'hex':
				return Array.from(byteArr, (byte) =>
					(byte & 255).toString(16).padStart(2, '0')
				).join('');
			case 'uuid':
				/* Thanks to https://stackoverflow.com/a/2117523 */
				return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, (c) =>
					(c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16)
				);
			default:
				return null;
		};
	},

	loadDefaultLabel(uciconfig, ucisection) {
		if (!ucisection)
			return '';

		/* Never write the internal section id back into 'label': doing so
		   turns names like 'routing_node_section_1' into permanent labels
		   that then show up in the LuCI table and in Clash dashboards. */
		return uci.get(uciconfig, ucisection, 'label') || ucisection;
	},

	loadModalTitle(title, addtitle, uciconfig, ucisection) {
		if (!ucisection)
			return addtitle;

		let label = uci.get(uciconfig, ucisection, 'label');
		return label ? title + ' » ' + label : addtitle;
	},

	/* GridSection 的重复名称列有两种成因，需分别处理：

	   一、OpenWrt 25.12 起的 luci-base：`renderContents` 已经把 sectiontitle
	   渲染成真实的 <td class="... cbi-section-table-titles">，同时 <tr> 上仍
	   带着 data-title；不少第三方主题（Argon 等）会用
	   `tr.cbi-section-table-row[data-title]::before { content: attr(data-title) }`
	   把这个名称再画一遍。该重复列是伪元素，删除 td 无效，必须清掉 tr 的
	   data-title 并禁用该 ::before 才能去掉。

	   二、部分旧版 luci-base：sectiontitle 与 `label` 都会渲染成真实 td，
	   前两列文本完全相同。此时删除首列 td，并按「表头单元格数是否等于删除
	   前的数据列数」判断表头首格是否属于该列，属于才删除，使表头与数据行
	   对齐（不同版本表头首格分别是空串或「名称」，不能靠文字判断）。 */
	dedupeNameColumn(section) {
		const orig = section.renderContents;

		/* 取单元格可见文本：GridSection 里 Value 选项通常渲染成只读
		   文本，但个别 luci-base 版本会渲染成 <input>，此时 textContent
		   为空、真正的值在 input.value 上。 */
		const cellText = function(td) {
			const text = (td.textContent || '').trim();

			if (text !== '')
				return text;

			const input = td.querySelector('input[type="text"], input:not([type])');

			return input ? (input.value || '').trim() : '';
		};

		const isTitleCell = function(td) {
			return !!(td && td.classList && td.classList.contains('cbi-section-table-titles'));
		};

		/* 25.12 起 sectiontitle 是真实 td，重复的那列是主题用 ::before
		   画的伪元素。一次性注入作用域样式，把这类行的伪元素关掉
		   （content:none 直接不生成伪元素）。 */
		const ensureTitleRealStyle = function() {
			if (window.__hpTitleRealStyle)
				return;

			window.__hpTitleRealStyle = true;

			try {
				document.head.appendChild(E('style', [ `
					.hp-title-real tr.cbi-section-table-row::before,
					.hp-title-real tr.cbi-section-table-titles::before { content: none !important; }
				` ]));
			}
			catch (e) {}
		};

		section.renderContents = function() {
			const el = orig.apply(this, arguments);

			try {
				const rows = [];

				for (const tr of el.querySelectorAll('tr')) {
					const cells = Array.from(tr.children).filter((c) => c.tagName === 'TD');

					if (cells.length === 0)
						continue;

					rows.push({ tr: tr, cells: cells });
				}

				if (rows.length === 0)
					return el;

				/* 情形一：首列是真实 title td（25.12+），去掉重复的 ::before 名称 */
				let hasRealTitle = false;

				for (const row of rows) {
					if (!isTitleCell(row.cells[0]))
						continue;

					hasRealTitle = true;
					row.tr.removeAttribute('data-title');
				}

				if (hasRealTitle) {
					ensureTitleRealStyle();
					el.classList.add('hp-title-real');
				}

				/* 情形二：首列与次列文本完全相同的，首列即多余重复列。
				   25.12 正常结构里次列是控件（文本为空）不会命中，故此处
				   只会作用于「两个都是真实文本 td」的旧版重复场景。 */
				const dataRows = rows.filter((row) => {
					return row.cells.length >= 2 &&
					       !row.cells[0].querySelector('input, select, button, textarea');
				});

				if (dataRows.length === 0)
					return el;

				const matched = dataRows.filter((row) => {
					const first = cellText(row.cells[0]),
					      second = cellText(row.cells[1]);

					return first !== '' && first === second;
				});

				/* 全有或全无：只有所有数据行都判定为冗余时才删除，
				   避免各行删除情况不同导致行与行列数错位。 */
				if (matched.length === 0 || matched.length !== dataRows.length)
					return el;

				const tdBefore = Math.max(...dataRows.map((row) => row.cells.length));

				for (const row of matched)
					row.cells[0].remove();

				const heads = el.querySelectorAll('th');

				if (heads.length === tdBefore)
					heads[0].remove();
			}
			catch (e) {
				/* 渲染后处理失败时保持原样，不影响表单功能 */
			}

			return el;
		};

		return section;
	},

	normalizeSectionId(label, prefix) {
		let section_id = (label || '').trim().replace(/[^A-Za-z0-9_]/g, '_').replace(/^_+|_+$/g, '');
		return (prefix || 'cfg') + '_' + (section_id || 'section');
	},

	renderSectionAdd(section, extra_class, hint, topHint) {
		/* luci-base 的 renderContents() 以 this.renderSectionAdd('cbi-tblsection-create')
		   调用本函数。由于本函数已被 L.bind 预绑定了前 3 个实参 (section,
		   extra_class, hint)，这个 class 串会顶到第 4 个参数 topHint 上，被误当成
		   说明文字渲染到「添加」框上方（界面上出现灰色 "cbi-tblsection-create"）。
		   识别为 CSS 类名时直接忽略，不当作说明文字输出。 */
		if (typeof topHint === 'string' && /^cbi-[\w-]+$/.test(topHint))
			topHint = null;

		const baseHint = hint || '';

		let el = form.GridSection.prototype.renderSectionAdd.apply(section, [ extra_class ]),
			nameEl = el.querySelector('.cbi-section-create-name'),
			button = el.querySelector('.cbi-section-create > .cbi-button-add'),
			uciconfig = section.uciconfig || section.map.config,
			sectiontype = section.sectiontype,
			mapData = section.map && section.map.data,
		labelEl = E('input', {
			'type': 'text',
			'class': nameEl.className
		}),
		hintEl = E('div', { 'class': 'cbi-value-description' }, baseHint);

		nameEl.style.display = 'none';

		/* Upstream wraps the hidden name input in an anonymous <div> and puts
		   the add button as a *sibling* of that wrapper. Rebuild the controls
		   so the visible label input and the add button share one flex row and
		   the hint sits on its own line below. Otherwise the button is rendered
		   below the input, which looks misaligned. */
		el.style.display = 'block';

		const wrapper = nameEl.parentNode;
		const row = E('div', { 'class': 'cbi-section-create-row' });
		row.style.display = 'flex';
		row.style.alignItems = 'center';
		row.style.gap = '.4em';
		row.style.flexWrap = 'wrap';

		row.appendChild(labelEl);   /* visible label input */
		row.appendChild(nameEl);    /* hidden original, still used by handleAdd() */
		row.appendChild(button);    /* add button, same row as the input */
		el.appendChild(row);
		el.appendChild(hintEl);     /* hint below the row */

		/* 顶部说明（如路由规则的匹配顺序提示、DNS 解析流程汇总），显示在输入行上方。
		   topHint 可以是字符串，也可以是返回 DOM 节点/字符串的函数——后者用于需要
		   在每次渲染时读取最新 uci 数据的动态说明（如 DNS 规则汇总）。 */
		if (topHint) {
			let content = (typeof topHint === 'function') ? topHint() : topHint;

			if (content != null && content !== '') {
				const isNode = (typeof Node !== 'undefined') && (content instanceof Node);
				const hintBox = E('div', { 'class': isNode ? 'hp-top-hint' : 'cbi-value-description hp-top-hint' });

				if (isNode)
					hintBox.appendChild(content);
				else
					hintBox.appendChild(document.createTextNode(String(content)));

				el.insertBefore(hintBox, row);
			}
		}

		/* The original wrapper is now empty; drop it so it cannot affect layout. */
		if (wrapper && wrapper.parentNode === el && wrapper.childElementCount === 0)
			wrapper.remove();

		button.disabled = true;

		/* Attach the typed label to the new section synchronously, i.e.
		   before the edit modal is rendered. Otherwise the modal loads an
		   empty label and the section ends up displayed as its internal id
		   (e.g. 'routing_node_section') instead of the typed name.

		   LuCI's add button calls map.data.add() directly (handleAdd() in
		   form.js) and never section.add(), so the label is attached at the
		   data layer. The section.add hook below only covers callers that
		   go through the section object itself. */
		if (mapData && !mapData.__hpPendingLabels) {
			mapData.__hpPendingLabels = { };

			const origDataAdd = mapData.add;
			mapData.add = function(config, type, name) {
				const sid = origDataAdd.apply(this, arguments),
				      key = config + '|' + type,
				      label = this.__hpPendingLabels[key];

				if (label && sid)
					uci.set(config, sid, 'label', label);

				delete this.__hpPendingLabels[key];

				return sid;
			};
		}

		if (!section.__hpCreateLabelHooked) {
			section.__hpCreateLabelHooked = true;

			const origAdd = section.add;
			section.add = function(name) {
				const sid = origAdd.apply(this, arguments),
				      id = (typeof sid === 'string' && sid) ? sid : name,
				      pending = this.__hpCreateLabel;

				this.__hpCreateLabel = '';

				if (pending && id)
					uci.set(this.map.config, id, 'label', pending);

				return sid;
			};
		}

		const syncSectionName = () => {
			let label = (labelEl.value || '').trim();
			hintEl.textContent = baseHint;
			section.__hpCreateLabel = label;

			if (mapData && mapData.__hpPendingLabels)
				mapData.__hpPendingLabels[uciconfig + '|' + sectiontype] = label;

			if (!label) {
				nameEl.value = '';
				button.disabled = true;
				return;
			}

			let duplicate = false;
			uci.sections(uciconfig, sectiontype, (res) => {
				if ((res.label || res['.name']) === label)
					duplicate = true;
			});

			if (duplicate) {
				nameEl.value = '';
				button.disabled = true;
				hintEl.textContent = _('Expecting: %s').format(_('unique value'));
				return;
			}

			let normalized = (label || '').trim().replace(/[^A-Za-z0-9_]/g, '_').replace(/^_+|_+$/g, '') || 'section',
			    section_id = (sectiontype || 'cfg') + '_' + normalized,
			    suffix = 1;
			while (uci.get(uciconfig, section_id))
				section_id = (sectiontype || 'cfg') + '_' + normalized + '_' + suffix++;

			nameEl.value = section_id;
			nameEl.dataset.sectionId = section_id;
			nameEl.dataset.sectionLabel = label;
			button.disabled = null;
		};

		labelEl.addEventListener('input', syncSectionName);
		labelEl.addEventListener('blur', syncSectionName);

		/* The pending label has to be up to date before LuCI's own click
		   handler runs, otherwise the section is created without a label.
		   The listener sits on the container `el` with capture = true so it
		   fires during the capture phase, before LuCI's handler on the
		   button; a listener bound to the button itself would run too late. */
		el.addEventListener('click', (ev) => {
			if (ev.target === button || button.contains(ev.target))
				syncSectionName();
		}, true);

		button.addEventListener('click', () => {
			syncSectionName();

			let label = nameEl.dataset.sectionLabel,
			    section_id = nameEl.dataset.sectionId;

			window.setTimeout(() => {
				if (label && section_id && uci.get(uciconfig, section_id))
					uci.set(uciconfig, section_id, 'label', label);
			}, 0);
		});

		return el;
	},

	/* 表格增强所需的少量全局样式，一次性注入（建议4/6/7/9/10）。 */
	ensureUIStyles() {
		if (window.__hpUIStyles)
			return;

		window.__hpUIStyles = true;

		try {
			document.head.appendChild(E('style', [ `
				.hp-top-hint { margin: .2rem 0 .4rem 0; }
				.hp-index-cell { opacity: .65; }
				/* route.final 行的「置顶」标记，紧跟名称文字之后 */
				.hp-pin-badge { display: inline-block; margin-left: .45em; padding: 0 .45em;
					border-radius: 4px; background: #fde8e8; color: #c5221f;
					font-size: .78rem; line-height: 1.6; vertical-align: middle;
					white-space: nowrap; cursor: default; }
				.hp-chips { display: inline-flex; flex-wrap: wrap; gap: 4px;
					justify-content: center; max-width: 280px; }
				.hp-chip { display: inline-block; padding: 1px 8px; border-radius: 10px;
					background: rgba(96, 60, 190, .12); border: 1px solid rgba(96, 60, 190, .28);
					font-size: .85rem; line-height: 1.5; white-space: nowrap; }
				.hp-rs-status { display: inline-flex; align-items: center; gap: 5px;
					font-size: .85rem; white-space: nowrap; }
				.hp-rs-dot { display: inline-block; width: 8px; height: 8px;
					border-radius: 50%; flex: none; }
				.hp-dot-ok { background: #2eb872; }
				.hp-dot-bad { background: #e4574c; }
				.hp-dot-none { background: #9aa0a6; }
				.hp-dns-banner { margin: 0 0 .8rem 0; padding: .55rem .9rem;
					border: 1px solid rgba(96, 60, 190, .35); border-left: 4px solid rgba(96, 60, 190, .65);
					border-radius: 6px; font-size: .9rem; line-height: 1.8; }
				.hp-tag { display: inline-block; padding: 1px 8px; border-radius: 4px;
					font-size: .85rem; line-height: 1.5; white-space: nowrap; }
				.hp-tag-auto { background: rgba(176, 106, 0, .14); color: #b06a00; }
				.hp-tag-manual { background: rgba(43, 91, 215, .12); color: #2b5bd7; }
				.hp-rn-status { display: inline-block; max-width: 280px; overflow: hidden;
					text-overflow: ellipsis; white-space: nowrap; vertical-align: middle;
					font-size: .85rem; }
				.hp-rn-ms { color: #2eb872; font-weight: 600; }
				/* 「当前节点 / 延迟」拿不到最新数据（服务重启中 / 该组未启用）：
				   保留上一次的值但降透明度，避免整格突然变成空白。 */
				.hp-rn-stale { opacity: .45; }
				.hp-rn-out { display: inline-block; max-width: 220px; overflow: hidden;
					text-overflow: ellipsis; white-space: nowrap; vertical-align: middle;
					font-size: .85rem; }
				.hp-rn-out-chain { color: #2b5bd7; font-weight: 600; }
				.hp-rn-out-direct { color: var(--muted, #68718a); }
				.hp-rn-out-na { opacity: .45; }
				.hp-chip-list { display: inline-flex; flex-wrap: wrap; gap: 4px;
					max-width: 240px; vertical-align: middle; }
				/* 每行固定 5 个（策略节点 / 订阅机场列）：第 6 个起换到下一行。
				   minmax(max-content, 1fr) 让列宽至少等于最宽的那个标签，容器更宽
				   时 5 列均分，因此标签文字不会被截断。 */
				.hp-chip-list-5 { display: inline-grid; max-width: none;
					grid-template-columns: repeat(5, minmax(max-content, 1fr));
					gap: 4px; vertical-align: middle; }
				/* 单个标签留 96px 上限：5 个中文字够放，超长的机场名才省略
				   （hover 有完整名称），避免一条超长标签把整列撑爆。 */
				.hp-chip-list-5 .hp-chip { max-width: 96px; text-align: center; }
				/* 窄屏放不下 5 列时不强行撑宽表格，退成 3 列。 */
				@media (max-width: 720px) {
					.hp-chip-list-5 { grid-template-columns: repeat(3, minmax(max-content, 1fr)); }
				}
				.hp-chip { display: inline-block; max-width: 130px; padding: 1px 9px;
					border-radius: 999px; font-size: .78rem; line-height: 1.7;
					white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
					background: rgba(43, 91, 215, .10); color: #2b5bd7; }
				.hp-chip-policy { background: rgba(96, 60, 190, .10); color: #5c3cbe; }
				.hp-chip-ruleset { background: rgba(96, 60, 190, .07); color: #5c3cbe;
					border: 1px solid rgba(96, 60, 190, .28); padding: 0 8px; }
				.hp-chip-empty { opacity: .45; }
				.hp-dns-loading { color: var(--muted, #68718a); }
				.hp-dns-err { color: #e05252; font-weight: 500; }
				/* 失败原因的简短说明：以前只放在 title 里，截图看不出是
				   rpcd 没加载新方法、还是 curl/ping 缺失或网络不通。
				   display:block 让它自成一行（父级 .hp-dns-lat 是 inline）。 */
				.hp-dns-err-detail { display: block; color: var(--muted, #8a8f9c);
					font-size: .72rem; line-height: 1.3; word-break: break-word; }
				.hp-dns-lat-cell { display: inline-flex; align-items: center; flex-wrap: wrap; gap: 6px 8px; }
				.hp-dns-test-btn { padding: 2px 10px; font-size: .75rem; line-height: 1.4; }
				.hp-lat-good { color: #2eb872; font-weight: 600; }
				.hp-lat-mid { color: #e08a1e; font-weight: 600; }
				.hp-lat-bad { color: #e05252; font-weight: 600; }
				.hp-dns-flow-title { font-weight: 600; margin-bottom: .35rem; }
				.hp-dns-flow-list { display: block; }
				.hp-dns-flow-row { display: flex; flex-wrap: wrap; align-items: baseline;
					gap: 0 .45rem; padding: .1rem 0; font-size: .88rem; }
				.hp-dns-flow-idx { flex: none; min-width: 1.5em; opacity: .65; }
				.hp-dns-flow-cond { flex: 1 1 auto; min-width: 0; word-break: break-all; }
				.hp-dns-flow-arrow { flex: none; opacity: .65; }
				.hp-dns-flow-target { flex: none; font-weight: 600; }
				.hp-dns-flow-default { margin-top: .35rem; padding-top: .35rem;
					border-top: 1px dashed rgba(128, 128, 128, .35); font-size: .88rem; }
				.hp-dns-flow-direct { color: #c0603a; }
				.hp-dns-flow-tip { margin-top: .35rem; font-size: .85rem; color: #c0603a; }
				.hp-dns-banner-compact { padding: .45rem .9rem; }
				.hp-dns-flow-note { margin-bottom: .2rem; }
				.hp-dns-flow-compact { font-size: .9rem; line-height: 1.85; }
				.hp-dns-flow-empty { opacity: .75; }
			` ]));
		}
		catch (e) {}
	},

	/* 名称列左侧插入序号列（建议4）。必须在 dedupeNameColumn() 之后调用，
	   使本包装位于外层：dedupe 先按原始表格分析首列，序号列随后再插入。
	   表头行取「首个子元素为 TH 且不含 TD」的 tr；数据行跳过空表占位行。 */
	prependIndexColumn(section, headerLabel) {
		const orig = section.renderContents;

		section.renderContents = function() {
			const el = orig.apply(this, arguments);

			try {
				const dataRows = [];

				for (const tr of el.querySelectorAll('tr')) {
					if (tr.classList.contains('cbi-section-table-row') &&
					    !tr.classList.contains('placeholder'))
						dataRows.push(tr);
				}

				if (dataRows.length === 0)
					return el;

				for (const tr of el.querySelectorAll('tr')) {
					if (tr.children.length === 0 || tr.children[0].tagName !== 'TH' ||
					    tr.querySelector('td'))
						continue;

					tr.insertBefore(E('th', { 'class': 'th' }, headerLabel || ''),
						tr.firstElementChild);
				}

				let index = 0;

				for (const tr of dataRows) {
					index++;
					tr.insertBefore(E('td', { 'class': 'td hp-index-cell' }, String(index)),
						tr.firstElementChild);
				}
			}
			catch (e) {
				/* 渲染后处理失败时保持原样，不影响表单功能 */
			}

			return el;
		};

		return section;
	},

	/* 表格末尾（操作按钮列之前）追加自定义列（建议6/7/9）。
	   columns: [{ header: '列头文本', renderCell: function(sid) → Node|String }]，
	   数据行通过 data-sid 属性取 section id，缺失时跳过不影响原表格。 */
	appendTableColumns(section, columns) {
			const orig = section.renderContents;

			/* 第三方主题可能在 renderContents 之后重建/修改 DOM，
			   用 delayedApply 在 rAF + 短延迟后再补丁一次；
			   MutationObserver 兜底捕捉晚到的 DOM 变化。 */
			const delayedApply = (el) => {
				const apply = () => {
					try {
						let changed = false;

						for (const tr of el.querySelectorAll('tr')) {
							/* 第三方主题可能不用 cbi-section-table-row，
							   优先 data-sid 属性（LuCI GridSection 标准），
							   再 fallback class 检查 */
							if (!tr.hasAttribute('data-sid') ||
							    tr.classList.contains('placeholder'))
								continue;

							const sid = tr.getAttribute('data-sid');

							if (!sid)
								continue;

							/* 跳过已补丁行（hp-extra-col 已有则不重复插入） */
							if (tr.querySelector('td.hp-extra-col'))
								continue;

							let anchor = null;

							for (const td of tr.children) {
								if (td.classList && td.classList.contains('cbi-section-actions')) {
									anchor = td;
									break;
								}
							}

							if (!anchor) {
								/* fallback：操作列在末尾，或无操作列时取最后一个 td */
								const lastTd = tr.querySelector('td:last-child');
								if (lastTd && !lastTd.classList.contains('hp-extra-col'))
									anchor = lastTd.nextSibling; /* null = append */
							}

							for (const col of columns) {
								const content = col.renderCell(sid),
								      td = E('td', { 'class': 'td cbi-value-field hp-extra-col' });

								td.appendChild((content instanceof Node)
									? content
									: document.createTextNode((content != null) ? String(content) : ''));

								if (anchor)
									tr.insertBefore(td, anchor);
								else
									tr.appendChild(td);
								changed = true;
							}
						}

						/* 表头行：额外列插到「操作」列标题之前，与数据行把新增
						   单元格插到操作列之前保持一致；否则表头会整体右移
						   一格，出现「空表头落在数据列上方」的错位。
						   主题可能重建表头，故用 hp-extra-col 计数去重。 */
						for (const tr of el.querySelectorAll('tr')) {
							if (tr.children.length === 0 || tr.children[0].tagName !== 'TH' ||
							    tr.querySelector('td'))
								continue;

							if (tr.querySelectorAll('th.hp-extra-col').length === columns.length)
								continue;

							let thAnchor = null;

							for (const th of tr.children) {
								if (th.classList && th.classList.contains('cbi-section-actions')) {
									thAnchor = th;
									break;
								}
							}

							for (const col of columns) {
								const th = E('th', { 'class': 'th hp-extra-col' }, col.header || '');

								if (thAnchor)
									tr.insertBefore(th, thAnchor);
								else
									tr.appendChild(th);
							}

							changed = true;
						}

						if (changed && !el.__hp_col_observer) {
							let debounceTimer = null;
							const mo = new MutationObserver(() => {
								/* apply() 修改 DOM 会再次触发 Observer，
								   加 50ms debounce 避免高频抖动 */
								if (debounceTimer)
									clearTimeout(debounceTimer);

								debounceTimer = setTimeout(() => {
									debounceTimer = null;
									apply();
								}, 50);
							});

							mo.observe(el, { childList: true, subtree: true });
							el.__hp_col_observer = mo;
						}
					}
					catch (e) {}
				};

				apply();
				requestAnimationFrame(apply);
				setTimeout(apply, 50);
			};

			section.renderContents = function() {
				const el = orig.apply(this, arguments);
				delayedApply(el);
				return el;
			};

			return section;
		},

	/* 「启用」列移动到名称列左侧（全局改进）。
	   两层保障，尽量不依赖具体 luci-base 版本与主题：
	   一、源码层（关键）：渲染前把 enabled 选项提到 children 首位。luci-base 的
	      表头 renderHeaderRows() 与数据行 renderContents() 都按 this.children
	      顺序生成列，所以这一步让「启用」成为第一个业务列，24.10 / 25.12 通用，
	      且不依赖任何 DOM 结构与主题 CSS。
	   二、DOM 层：luci-base 会把「名称」格固定插在所有业务列之前——25.12 是真实
	      td.cbi-section-table-titles；24.10 根本没有名称格，只给 tr[data-title]，
	      由主题用 ::before 画出来。所以再把名称格挪到「启用」之后；24.10 上没有
	      真实名称格时补一个，并关掉主题那一份伪元素名称。
	   必须在 dedupeNameColumn() 之后调用。 */
	moveEnableColumn(section) {
		const optionName = 'enabled';

		/* 源码层：把 enabled 提到 children 首位（幂等）。 */
		const orderChildren = function(self) {
			if (!self || !Array.isArray(self.children))
				return;

			let idx = -1;

			for (let i = 0; i < self.children.length; i++) {
				if (self.children[i] && self.children[i].option === optionName) {
					idx = i;
					break;
				}
			}

			if (idx <= 0)
				return;

			self.children.unshift(self.children.splice(idx, 1)[0]);
		};

		/* 关掉主题用伪元素画出来的那一份名称，避免与真实名称格重复显示。
		   选择器覆盖 tr / td / th 三种挂载位置；data-title 属性本身也会被移除，
		   即使主题用的是 content: attr(data-title) 也拿不到内容。 */
		const ensureTitleRealStyle = function() {
			if (window.__hpTitleRealStyleEx)
				return;

			window.__hpTitleRealStyleEx = true;

			try {
				document.head.appendChild(E('style', [ `
					.hp-title-real tr.cbi-section-table-row::before,
					.hp-title-real tr.cbi-section-table-titles::before,
					.hp-title-real tbody tr::before,
					.hp-title-real td.cbi-section-table-titles::before,
					.hp-title-real th.cbi-section-table-titles::before { content: none !important; }
				` ]));
			}
			catch (e) {}
		};

		const origRenderChildren = section.renderChildren;

		if (typeof origRenderChildren === 'function') {
			section.renderChildren = function() {
				try { orderChildren(this); } catch (e) {}

				return origRenderChildren.apply(this, arguments);
			};
		}

		const orig = section.renderContents;

		/* 第三方主题可能在 renderContents 之后重建/修改 DOM，
		   用 delayedApply 在 rAF + 短延迟后再补丁一次；
		   MutationObserver 兜底捕捉晚到的 DOM 变化。 */
		const delayedApply = (el) => {
			const apply = () => {
				try {
					const dataRows = [],
					      headerRows = [];

					for (const tr of el.querySelectorAll('tr')) {
						/* 表头行：首格是 TH 且整行没有 TD（25.12 的表头也带
						   cbi-section-table-titles，不能靠 class 判断） */
						if (tr.children.length > 0 && tr.children[0].tagName === 'TH' &&
						    !tr.querySelector('td')) {
							headerRows.push(tr);
							continue;
						}

						/* 第三方主题兼容：data-sid 优先，class fallback */
						if ((tr.hasAttribute('data-sid') ||
						     tr.classList.contains('cbi-section-table-row')) &&
						    !tr.classList.contains('placeholder'))
							dataRows.push(tr);
					}

					if (dataRows.length === 0)
						return;

					const ref = dataRows[0];

					const findNameIdx = function(tr) {
						for (let i = 0; i < tr.children.length; i++) {
							if (tr.children[i].classList &&
							    tr.children[i].classList.contains('cbi-section-table-titles'))
								return i;
						}

						return -1;
					};

					/* 源码层已把 enabled 提到首位，所以它必然是第一个业务列 */
					const findEnabledIdx = function(tr) {
						let fallback = -1;

						for (let i = 0; i < tr.children.length; i++) {
							const td = tr.children[i];

							if (td.tagName !== 'TD')
								continue;

							if (td.getAttribute('data-name') === optionName)
								return i;

							if (fallback < 0 && td.querySelector('input[type="checkbox"]'))
								fallback = i;
						}

						return fallback;
					};

					let nameIdx = findNameIdx(ref),
					    enabledIdx = findEnabledIdx(ref);

					if (enabledIdx < 0)
						return;

					const preCount = ref.children.length,
					      createName = (nameIdx < 0);

					ensureTitleRealStyle();
					el.classList.add('hp-title-real');

					if (createName) {
						/* 24.10 分支：没有真实名称格，用 tr[data-title] 补一个 */
						if (!ref.getAttribute('data-title'))
							return;

						for (const tr of dataRows) {
							const t = tr.getAttribute('data-title');

							if (!t || findNameIdx(tr) >= 0)
								continue;

							const e = findEnabledIdx(tr),
							      cell = E('td', {
								'class': 'td cbi-value-field cbi-section-table-titles'
							}, [ t ]);

							if (e >= 0 && tr.children[e] && tr.children[e].nextSibling)
								tr.insertBefore(cell, tr.children[e].nextSibling);
							else
								tr.appendChild(cell);

							tr.removeAttribute('data-title');
						}

						nameIdx = findNameIdx(ref);
						enabledIdx = findEnabledIdx(ref);

						if (nameIdx < 0 || enabledIdx < 0)
							return;
					}

					/* 幂等：名称已在启用右侧相邻位置则无需再搬动数据行。
					   表头仍需处理——24.10 分支的名称格是刚补出来的，
					   对应表头格还没建，不能在这里直接 return。 */
					const needMove = (nameIdx !== enabledIdx + 1);

					/* 数据行：名称格移到启用格之后 */
					if (needMove) {
						for (const tr of dataRows) {
							const n = findNameIdx(tr),
							      e = findEnabledIdx(tr);

							if (n < 0 || e < 0 || n === e + 1)
								continue;

							const nameCell = tr.children[n],
							      enabledCell = tr.children[e];

							if (!nameCell || !enabledCell || nameCell === enabledCell)
								continue;

							tr.insertBefore(nameCell, enabledCell.nextSibling);
						}
					}

					/* 表头行：与数据行同样处理，索引与数据行对齐 */
					for (const tr of headerRows) {
						if (tr.children.length !== preCount)
							continue;

						if (createName) {
							if (tr.querySelector('th.hp-name-col'))
								continue;

							const anchor = tr.children[enabledIdx],
							      title = tr.getAttribute('data-title') || _('Name'),
							      th = E('th', {
								'class': 'th cbi-section-table-cell hp-name-col'
							}, [ title ]);

							tr.insertBefore(th, anchor ? anchor.nextSibling : null);
							tr.removeAttribute('data-title');
						}
						else {
							const nameTh = tr.children[nameIdx],
							      enabledTh = tr.children[enabledIdx];

							if (!nameTh || !enabledTh || nameTh === enabledTh)
								continue;

							if (nameTh.previousElementSibling === enabledTh)
								continue;

							tr.insertBefore(nameTh, enabledTh.nextSibling);
						}
					}

					/* 首次 apply 成功后，挂载 MutationObserver 捕捉后续 DOM 变动 */
					if (!el.__hp_en_observer) {
						let debounceTimer = null;
						const mo = new MutationObserver(() => {
							if (debounceTimer)
								clearTimeout(debounceTimer);

							debounceTimer = setTimeout(() => {
								debounceTimer = null;
								apply();
							}, 50);
						});

						mo.observe(el, { childList: true, subtree: true });
						el.__hp_en_observer = mo;
					}
				}
				catch (e) {}
			};

			apply();
			requestAnimationFrame(apply);
			setTimeout(apply, 50);
		};

		section.renderContents = function() {
			try { orderChildren(this); } catch (e) {}

			const el = orig.apply(this, arguments);

			delayedApply(el);

			return el;
		};

		return section;
	},

	/* cron（本插件限定的 "M H * * D" 形式）转可读文本（建议8）。
	   解析失败时原样返回，避免显示空白。 */
	cronToHuman(value) {
		const parsed = parseCron(value);

		if (!parsed)
			return String(value || '');

		const time = parsed.hour + ':' + parsed.minute,
		      days = [ _('Sun'), _('Mon'), _('Tue'), _('Wed'),
		               _('Thu'), _('Fri'), _('Sat') ];

		return (parsed.day === '*')
			? _('Every day %s').format(time)
			: _('Every %s %s').format(days[+parsed.day % 7], time);
	},

	installCloseButtonText() {
		if (window.__homeproxyCloseButtonText)
			return;

		window.__homeproxyCloseButtonText = true;

		let fix = (root) => {
			for (let el of (root || document).querySelectorAll('button, .btn, input[type="button"], input[type="submit"]')) {
				let text = (el.textContent || el.value || '').trim();
				if (text !== 'Dismiss' && text !== '\u5ffd\u7565')
					continue;

				if ('value' in el && !el.textContent.trim())
					el.value = _('Close');
				else
					el.textContent = _('Close');
			}
		};

		let observe = () => {
			if (!document.body)
				return;

			fix(document);
			new MutationObserver((mutations) => {
				for (let mutation of mutations)
					for (let node of mutation.addedNodes)
						if (node.nodeType === 1)
							fix(node);
				fix(document);
			}).observe(document.body, { childList: true, subtree: true });
		};

		if (document.body)
			observe();
		else
			document.addEventListener('DOMContentLoaded', observe, { once: true });
	},

	uploadCertificate(_option, type, filename, ev) {
		const callWriteCertificate = rpc.declare({
			object: 'luci.homeproxy',
			method: 'certificate_write',
			params: ['filename'],
			expect: { '': {} }
		});

		return ui.uploadFile('/tmp/homeproxy_certificate.tmp', ev.target)
		.then(L.bind((_btn, res) => {
			return L.resolveDefault(callWriteCertificate(filename), {}).then((ret) => {
				if (ret.result === true)
					ui.addNotification(null, E('p', _('Your %s was successfully uploaded. Size: %sB.').format(type, res.size)));
				else
					ui.addNotification(null, E('p', _('Failed to upload %s, error: %s.').format(type, ret.error)));
			});
		}, this, ev.target))
		.catch((e) => { ui.addNotification(null, E('p', e.message)) });
	},

	uploadPanel(_option, ev) {
		const callInstallPanel = rpc.declare({
			object: 'luci.homeproxy',
			method: 'clash_api_install_panel',
			expect: { '': {} }
		});

		const normalizeMessage = (message) => {
			switch (message) {
			case 'panel_backup_failed':
				return _('Backup panel failed.');
			case 'panel_restore_failed':
				return _('Restore panel failed.');
			case 'empty_panel_zip':
				return _('Panel ZIP file is empty.');
			case 'unzip_unavailable':
				return _('The unzip command is unavailable.');
			case 'invalid_panel_zip':
				return _('Invalid panel ZIP file.');
			case 'panel_install_failed':
				return _('Install panel failed.');
			default:
				return message || _('unknown error');
			}
		};

		return ui.uploadFile('/tmp/homeproxy_panel.tmp', ev.target)
		.then(L.bind((_btn, res) => {
			return L.resolveDefault(callInstallPanel(), {}).then((ret) => {
				if (ret.result === true)
					ui.addNotification(null, E('p', _('Your %s was successfully uploaded. Size: %sB.').format(_('panel ZIP package'), res.size)), 'info');
				else
					ui.addNotification(null, E('p', _('Failed to upload %s, error: %s.').format(_('panel ZIP package'), normalizeMessage(ret.error))), 'danger');
			});
		}, this, ev.target))
		.catch((e) => { ui.addNotification(null, E('p', e.message || e), 'danger') });
	},

	validateBase64Key(length, section_id, value) {
		/* Thanks to luci-proto-wireguard */
		if (section_id && value)
			if (value.length !== length || !value.match(/^(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?$/) || value[length-1] !== '=')
				return _('Expecting: %s').format(_('valid base64 key with %d characters').format(length));

		return true;
	},

	validateCertificatePath(section_id, value) {
		if (section_id && value)
			if (!value.match(/^(\/etc\/homeproxy\/certs\/|\/etc\/acme\/|\/etc\/ssl\/).+$/))
				return _('Expecting: %s').format(_('/etc/homeproxy/certs/..., /etc/acme/..., /etc/ssl/...'));

		return true;
	},

	validatePortRange(section_id, value) {
		if (section_id && value) {
			value = value.match(/^(\d+)?\:(\d+)?$/);
			if (value && (value[1] || value[2])) {
				if (!value[1])
					value[1] = 0;
				else if (!value[2])
					value[2] = 65535;

				if (value[1] < value[2] && value[2] <= 65535)
					return true;
			}

			return _('Expecting: %s').format( _('valid port range (port1:port2)'));
		}

		return true;
	},

	validateUniqueValue(uciconfig, ucisection, ucioption, section_id, value) {
		if (section_id) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));
			if (ucioption === 'node' && (value === 'urltest' || value === 'selector'))
				return true;

			let duplicate = false;
			uci.sections(uciconfig, ucisection, (res) => {
				if (res['.name'] !== section_id)
					if (res[ucioption] === value)
						duplicate = true
			});
			if (duplicate)
				return _('Expecting: %s').format(_('unique value'));
		}

		return true;
	},

	validateOutboundTag(section_id, value) {
		/* sing-box outbound tags and Clash API proxy names are UTF-8, so
		   Chinese labels are supported. Only reject characters that break
		   tag handling or get rewritten by generate_client.uc. */
		if (!value)
			return _('Expecting: %s').format(_('non-empty value'));

		if (/[\/\\?#%\r\n\t]/.test(value))
			return _('Expecting: %s').format(_('valid tag'));

		return true;
	},

	validateUUID(section_id, value) {
		if (section_id) {
			if (!value)
				return _('Expecting: %s').format(_('non-empty value'));
			else if (value.match('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') === null)
				return _('Expecting: %s').format(_('valid uuid'));
		}

		return true;
	}
});
