/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require rpc';
'require ui';
'require view';

'require homeproxy as hp';

const css = '				\
	/* 设计令牌（DESIGN.md）：浅色为默认，深色随系统/主题类自动覆盖。 */	\
	:root {--hp-surface:#fff;--hp-wash:#fafbfc;--hp-panel:#f4f6f9;--hp-inset:#e9edf2;--hp-line:#eee;--hp-line-soft:#f0f0f0;--hp-line-faint:#eef0f2;--hp-line-fainter:#f4f5f6;--hp-ok-grad-a:#f7fbf5;--hp-text-strong:#2c3138;--hp-text-body:#5a6470;--hp-text-muted:#65727f;--hp-text-faint:#6b7683;--hp-ok:#1b7a43;--hp-ok-deep:#2d6d2d;--hp-ok-mint:#e8f5e9;--hp-danger:#a12825;--hp-danger-bg:#fdecec;--hp-danger-line:#f5c2c0;--hp-warn:#8a5a00;--hp-focus:#4a7dff}				\
	html[class*="dark"] {--hp-surface:#242930;--hp-wash:#1d2126;--hp-panel:#2b3138;--hp-inset:#2e343b;--hp-line:#3a4149;--hp-line-soft:#333a41;--hp-line-faint:#3d434b;--hp-line-fainter:#30363d;--hp-ok-grad-a:#222b24;--hp-text-strong:#e6e9ed;--hp-text-body:#b6bec7;--hp-text-muted:#97a1ac;--hp-text-faint:#818b96;--hp-ok:#4cc487;--hp-ok-deep:#82d4a8;--hp-ok-mint:#1e3428;--hp-danger:#e0706c;--hp-danger-bg:#3a2325;--hp-danger-line:#5c3234;--hp-warn:#d9a441;--hp-focus:#7ba2ff}				\
	@media (prefers-color-scheme: dark) {				\
		:root {--hp-surface:#242930;--hp-wash:#1d2126;--hp-panel:#2b3138;--hp-inset:#2e343b;--hp-line:#3a4149;--hp-line-soft:#333a41;--hp-line-faint:#3d434b;--hp-line-fainter:#30363d;--hp-ok-grad-a:#222b24;--hp-text-strong:#e6e9ed;--hp-text-body:#b6bec7;--hp-text-muted:#97a1ac;--hp-text-faint:#818b96;--hp-ok:#4cc487;--hp-ok-deep:#82d4a8;--hp-ok-mint:#1e3428;--hp-danger:#e0706c;--hp-danger-bg:#3a2325;--hp-danger-line:#5c3234;--hp-warn:#d9a441;--hp-focus:#7ba2ff}				\
	}				\
	/* 键盘焦点环：token 化后统一补齐（audit P1） */				\
	.homeproxy-connect-result:focus-visible, .homeproxy-score-ft a:focus-visible, .homeproxy-core-alert button:focus-visible {				\
		outline: 2px solid var(--hp-focus); outline-offset: 2px;				\
	}				\
.homeproxy-connect-grid {		\
	display: grid;			\
	grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));\
	gap: 12px;			\
}					\
.homeproxy-connect-card {		\
	display: grid;			\
	grid-template-columns: 44px 1fr;	\
	gap: 10px;			\
	align-items: center;		\
	min-height: 64px;		\
	padding: 8px 10px;		\
	border-radius: 6px;		\
	background: var(--hp-surface);		\
	box-shadow: 0 1px 4px rgba(0, 0, 0, .08);\
}					\
.homeproxy-connect-icon {		\
	display: flex;			\
	align-items: center;		\
	justify-content: center;		\
	width: 38px;			\
	height: 38px;			\
	border-radius: 50%;		\
	background: var(--hp-panel);		\
}					\
.homeproxy-connect-icon svg {		\
	display: block;			\
	width: 24px;			\
	height: 24px;			\
}					\
.homeproxy-connect-info {		\
	min-height: 42px;		\
	padding: 7px 12px;		\
	border-radius: 8px;		\
	background: var(--hp-inset);		\
}					\
.homeproxy-connect-title {		\
	color: var(--hp-text-muted);			\
	font-weight: 700;		\
	font-size: 13px;		\
	line-height: 1.2;		\
}					\
.homeproxy-connect-time { margin-top: 1px; color: var(--hp-text-muted); font-size: 11px; line-height: 1.2; min-height: 13px; } \
.homeproxy-connect-result {		\
	margin-top: 2px;		\
	color: var(--hp-text-muted);			\
	font-weight: 700;		\
	font-size: 13px;		\
	cursor: pointer;		\
	line-height: 1.2;		\
}					\
/* 综合评分卡片（每组独立排行） */ \
.homeproxy-score-grid {				\
	display: grid;				\
	grid-template-columns: 1fr;		\
	gap: 16px;				\
	max-width: 860px;			\
	margin: 0 auto;			\
}						\
.homeproxy-score-card {				\
	background: var(--hp-surface);			\
	border-radius: 8px;			\
	box-shadow: 0 1px 4px rgba(0,0,0,.08);	\
	overflow: hidden;			\
}						\
.homeproxy-score-hd {				\
	display: flex; align-items: center; justify-content: space-between; \
	padding: 12px 16px;			\
	border-bottom: 1px solid var(--hp-line);		\
	background: linear-gradient(90deg,var(--hp-ok-grad-a),var(--hp-surface)); \
}						\
.homeproxy-score-hd .ttl { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; } \
.homeproxy-score-hd h4 { margin: 0; font-size: 16px; font-weight: 700; } \
.homeproxy-score-hd .mode { font-size: 12.5px; color: var(--hp-text-muted); } \
.homeproxy-score-hd .stat { font-size: 12.5px; color: var(--hp-text-muted); white-space: nowrap; } \
.homeproxy-score-hd .stat-avail { color: var(--hp-ok-deep); font-weight: 600; } \
.homeproxy-score-badge { font-size: 12px; background: var(--hp-ok-mint); color: var(--hp-ok-deep); \
	padding: 2px 10px; border-radius: 10px; font-weight: 600; white-space: nowrap; } \
 .homeproxy-score-kv { display: grid; \
	grid-template-columns: 40px minmax(0, 1fr) 116px 68px 112px 74px 64px; \
	align-items: end; box-sizing: border-box; \
	border-bottom: 1px solid var(--hp-line-soft); } \
.homeproxy-score-kv > div { display: flex; flex-direction: column; gap: 3px; \
	align-items: center; text-align: center; padding: 14px 18px; box-sizing: border-box; } \
.homeproxy-score-kv > div > span { color: var(--hp-text-muted); font-size: 12px; white-space: nowrap; } \
.homeproxy-score-kv > div > b { font-size: 18px; font-weight: 600; color: var(--hp-text-strong); white-space: nowrap; } \
.homeproxy-score-kv b.hl { color: var(--hp-ok); font-size: 20px; } \
 .homeproxy-score-kv .kv-cur { min-width: 0; max-width: 100%; align-items: flex-start; text-align: left; } \
.homeproxy-score-kv .kv-cur > b { font-size: 15px; font-weight: 600; overflow: hidden; \
	text-overflow: ellipsis; white-space: nowrap; max-width: 100%; } \
.homeproxy-score-title { padding: 12px 18px 6px; font-size: 12.5px; color: var(--hp-text-muted); font-weight: 600; letter-spacing: .3px; } \
table.homeproxy-score-tbl { width: 100%; border-collapse: collapse; font-size: 14px; table-layout: fixed; } \
.homeproxy-score-tbl th { text-align: center; padding: 7px 18px; color: var(--hp-text-muted); \
	font-weight: 600; font-size: 12.5px; background: var(--hp-wash); border-bottom: 1px solid var(--hp-line-faint); } \
.homeproxy-score-tbl td { padding: 8px 18px; border-bottom: 1px solid var(--hp-line-fainter); } \
.homeproxy-score-tbl tbody tr:last-child td { border-bottom: 0; } \
.homeproxy-score-tbl .rk { width: 40px; color: var(--hp-text-faint); text-align: center; } \
.homeproxy-score-tbl .dl { width: 116px; white-space: nowrap; text-align: center; color: var(--hp-text-body); } \
.homeproxy-score-tbl .sc { width: 64px; text-align: center; color: var(--hp-ok); font-weight: 700; } \
.homeproxy-score-tbl .ls { width: 68px; white-space: nowrap; text-align: center; color: var(--hp-text-body); } \
.homeproxy-score-tbl .sp { width: 112px; white-space: nowrap; text-align: center; color: var(--hp-text-body); } \
.homeproxy-score-tbl .dg { width: 74px; text-align: center; } \
.homeproxy-score-tbl .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; } \
/* 表头与数据上下对齐：序号/延迟/评分表头居中，节点列表头左对齐（与数据一致） */ \
.homeproxy-score-tbl th.nm { text-align: left; } \
.homeproxy-score-ft { padding: 10px 18px; font-size: 12.5px; color: var(--hp-text-muted); \
	display: flex; justify-content: space-between; align-items: center; } \
.homeproxy-score-ft a { cursor: pointer; color: var(--hp-ok); font-weight: 600; } \
.homeproxy-score-empty { padding: 16px 18px; font-size: 14px; color: var(--hp-text-muted); } \
.homeproxy-core-alert { margin: 0 auto 12px; max-width: 860px; padding: 10px 14px; \
	border-radius: 8px; background: var(--hp-danger-bg); color: var(--hp-danger); font-size: 13px; line-height: 1.5; \
	border: 1px solid var(--hp-danger-line); } \
.homeproxy-score-nodata { padding: 10px 18px 14px; font-size: 13px; color: var(--hp-text-faint); }';

function renderScoreCards() {
	const callScoreStatus = rpc.declare({
		object: 'luci.homeproxy',
		method: 'score_status',
		expect: { '': {} }
	});
	const callMembers = rpc.declare({
		object: 'luci.homeproxy',
		method: 'score_group_members',
		params: ['group'],
		expect: { '': {} }
	});

	const container = E('div', { 'class': 'homeproxy-score-grid' }, [
		E('div', { 'class': 'homeproxy-score-empty' }, [ _('Loading...') ])
	]);

	function fmtLoss(m) {
		/* 无样本（loss 未定义）显示 —，有样本显示百分比 */
		if (m.loss == null) return '—';
		return '%d%%'.format(Math.round(m.loss * 100));
	}
	function fmtSpeed(m) {
		if (!m.speed) return '—';
		const kb = m.speed / 1024.0;
		return (kb >= 1024) ? '%.1f MB/s'.format(kb / 1024.0) : '%d KB/s'.format(Math.round(kb));
	}

	function showMembers(group) {
		return L.resolveDefault(callMembers(group), {}).then((ret) => {
			const rows = (ret.members || []).map((m, i) => E('tr', {}, [
				E('td', { 'class': 'rk' }, [ m.ok ? String(i + 1) : '—' ]),
				E('td', { 'class': 'nm', 'title': m.name }, [ m.name ]),
				E('td', { 'class': 'dl' }, [ m.ok ? '%d ms'.format(m.delay) : _('Timeout / failed') ]),
				E('td', { 'class': 'ls' }, [ fmtLoss(m) ]),
				E('td', { 'class': 'sp' }, [ fmtSpeed(m) ]),
				E('td', { 'class': 'dg' }, [ m.deg ? E('b', { style: 'color:var(--hp-danger)' }, [ _('Yes') ]) : '—' ]),
				E('td', { 'class': 'sc' }, [ String(m.score) ])
			]));
			ui.showModal(group, [
				E('style', [ '#modal_overlay > .modal, #modal_overlay > .modal.cbi-modal' +
					' { max-width: 90vw !important; width: 860px !important; }' ].join('')),
				E('div', { 'style': 'max-height:60vh;overflow:auto' }, [
					E('table', { 'class': 'homeproxy-score-tbl' }, [
						E('thead', {}, [ E('tr', {}, [
							E('th', { 'class': 'rk' }, [ '#' ]),
							E('th', { 'class': 'nm' }, [ _('Node') ]),
							E('th', { 'class': 'dl' }, [ _('Latency') ]),
							E('th', { 'class': 'ls' }, [ _('Loss') ]),
							E('th', { 'class': 'sp' }, [ _('Speed') ]),
							E('th', { 'class': 'dg' }, [ _('Degraded') ]),
							E('th', { 'class': 'sc' }, [ _('Score') ])
						]) ]),
						E('tbody', {}, rows)
					])
				]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, [ _('Close') ])
				])
			]);
		});
	}

	return L.resolveDefault(callScoreStatus(), {}).then((ret) => {
		const groups = ret.groups || [];
		const scoring = ret.scoring === true;   /* 是否正在评分（评分器锁存在） */
		const core_running = ret.core_running !== false;   /* 内核是否在跑（false=未运行，数据为历史快照） */
		if (!groups.length) {
			dom.content(container, E('div', { 'class': 'homeproxy-score-empty' }, [
				_('No policy group is using comprehensive score mode.')
			]));
			return container;
		}
		const cards = groups.map((g) => {
			const rows = (g.top || []).map((m, i) => E('tr', {}, [
				E('td', { 'class': 'rk' }, [ String(i + 1) ]),
				E('td', { 'class': 'nm', 'title': m.name }, [ m.name ]),
				E('td', { 'class': 'dl' }, [ '%d ms'.format(m.delay) ]),
				E('td', { 'class': 'ls' }, [ fmtLoss(m) ]),
				E('td', { 'class': 'sp' }, [ fmtSpeed(m) ]),
				E('td', { 'class': 'dg' }, [ m.deg ? E('b', { style: 'color:var(--hp-danger)' }, [ _('Yes') ]) : '—' ]),
				E('td', { 'class': 'sc', 'style': core_running ? '' : 'color:var(--hp-text-faint)' }, [ String(m.score) ])
			]));
			const hasTop = rows.length > 0;
			/* 上次评分时间：年月日 + 时:分（秒不显示） */
			const fmtScored = (ts) => {
				if (!ts)
					return '—';
				const d = new Date(ts * 1000);
				const p2 = (n) => (n < 10 ? '0' + n : '' + n);
				return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes());
			};
			return E('div', { 'class': 'homeproxy-score-card' }, [
				E('div', { 'class': 'homeproxy-score-hd' }, [
					E('div', { 'class': 'ttl' }, [
						/* P3：去掉 emoji 噪点；工作模式收进标题 tooltip（不再挤占标题行）；
						   保留「上次评分」与「可用/总数」两条真正有用的状态。 */
						E('h4', { 'title': _('Auto select (comprehensive score)') }, [ g.tag ]),
						E('span', { 'class': 'stat' }, [ _('Last scored') + ' ' + fmtScored(g.updated) ]),
						E('span', { 'class': 'stat stat-avail' }, [ _('Available / Total') + ' ' + '%d / %d'.format(g.ok, g.total) ])
					]),
					/* 「评分中」只在评分器真的在跑时显示（rpcd 查 score_nodes.lock）。
					   以前是无条件静态渲染，导致永远显示、误导用户以为一直评分中。 */
					scoring ? E('span', { 'class': 'homeproxy-score-badge' }, [ _('Scoring') ]) : ''
				]),
				E('div', { 'class': 'homeproxy-score-kv' }, [
					E('div', { 'class': 'kv-sp' }, [ ]),
					E('div', { 'class': 'kv-cur' }, [ E('span', {}, [ _('Current') ]), E('b', { 'title': g.now || '—' }, [ g.now || '—' ]) ]),
					E('div', {}, [ E('span', {}, [ _('Latency') ]), E('b', {}, [ g.now_delay != null ? '%d ms'.format(g.now_delay) : '—' ]) ]),
					E('div', {}, [ E('span', {}, [ _('Loss') ]), E('b', {}, [ fmtLoss({ loss: g.now_loss }) ]) ]),
					E('div', {}, [ E('span', {}, [ _('Speed') ]), E('b', {}, [ fmtSpeed({ speed: g.now_speed }) ]) ]),
					E('div', {}, [ E('span', {}, [ _('Degraded') ]), E('b', { 'style': g.now_deg ? 'color:var(--hp-danger)' : '' }, [ g.now_deg ? _('Yes') : '—' ]) ]),
					E('div', {}, [ E('span', {}, [ _('Score') ]), E('b', { 'class': 'hl', 'style': core_running ? '' : 'color:var(--hp-text-faint)', 'title': core_running ? '' : _('Stale snapshot — core not running') }, [ String(g.score) ]) ])
				]),
				hasTop ? E('div', { 'class': 'homeproxy-score-title' }, [
					_('Top 3 by score'),
					/* P3 bridging：一句说明「上方 kv 是当前选中节点、这里是组内按综合分的前三名」，
					   让新用户不被两段数字搞混。 */
					E('span', { 'class': 'score-hint', 'style': 'font-weight:400;margin-left:8px' }, [
						'— ' + _('ranked within this group; the row above is the current pick')
					])
				]) : '',
				hasTop ? E('table', { 'class': 'homeproxy-score-tbl' }, [
					E('thead', {}, [ E('tr', {}, [
						E('th', { 'class': 'rk' }, [ '#' ]), E('th', { 'class': 'nm' }, [ _('Node') ]),
						E('th', { 'class': 'dl' }, [ _('Latency') ]),
						E('th', { 'class': 'ls' }, [ _('Loss') ]),
						E('th', { 'class': 'sp' }, [ _('Speed') ]),
						E('th', { 'class': 'dg' }, [ _('Degraded') ]),
						E('th', { 'class': 'sc' }, [ _('Score') ])
					]) ]),
					E('tbody', {}, rows)
				]) : E('div', { 'class': 'homeproxy-score-nodata' }, [ _('No available node data yet.') ]),
				E('div', { 'class': 'homeproxy-score-ft' }, [
					E('span', {}, [ '%d'.format(g.total) + ' ' + _('members') ]),
					E('a', {
						'role': 'button',
						'tabindex': '0',
						'click': ui.createHandlerFn(this, () => showMembers(g.tag)),
						'keydown': ui.createHandlerFn(this, (ev) => {
							if (ev.key === 'Enter' || ev.key === ' ' || ev.key === 'Spacebar') {
								ev.preventDefault();
								showMembers(g.tag);
							}
						})
					}, [ _('View all') + ' ↗' ])
				])
			]);
		});
		if (!core_running) {
			/* P1 阻断式告警：内核未运行 → 下列评分/节点数据全是历史快照，不代表
			   当前可用性。用 danger 横幅明确告诉用户，避免误读"一切正常"。 */
			/* 内核未运行的横幅里给一个「启动服务」直达按钮，省得用户再去找入口
			   （critique P3）。用 LuCI 标准 rc.init 调用启动 homeproxy。 */
			const callStartService = rpc.declare({
				object: 'rc', method: 'init',
				params: ['name', 'action']
			});
			const startBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-left: 8px',
				'click': ui.createHandlerFn(this, () => {
					startBtn.disabled = true;
					startBtn.textContent = _('Starting…');
					return L.resolveDefault(callStartService('homeproxy', 'start'), {})
						.then(() => {
							/* 明确告知即将自动刷新，避免"点了页面空白=点坏了"的焦虑。 */
							startBtn.textContent = _('Restarting, page will refresh…');
							window.setTimeout(() => window.location.reload(), 3000);
						})
						.catch(() => { startBtn.disabled = false; startBtn.textContent = _('Start service'); });
				})
			}, [ _('Start service') ]);
			dom.content(container, [
				E('div', { 'class': 'homeproxy-core-alert', 'role': 'alert' }, [
					E('div', {}, [ E('b', {}, [ '⚠ ' + _('sing-box core is not running.') ]), ' ',
						_('The scores and node data below are historical snapshots and do not reflect current availability. Please start the service to get live data.') ]),
					E('div', { 'style': 'margin-top:8px' }, [ startBtn ])
				])
			].concat(cards));
		} else {
			dom.content(container, cards);
		}
		return container;
	});
}

/* Brand logos are inlined so the cards render without external assets and
   without pulling remote images into the router's web UI. */
const connLogos = {
	aliyun: '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ff6a00" d="M7.2 18.6a4.7 4.7 0 0 1 0-9.4 6.6 6.6 0 0 1 12.4 1.6 4 4 0 0 1-1.1 7.8z"/>' +
		'</svg>',
	google: '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ea4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>' +
		'<path fill="#4285f4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>' +
		'<path fill="#fbbc05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>' +
		'<path fill="#34a853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>' +
		'</svg>',
	github: '<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#1f2328" d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.04-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68.78 1.31.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/>' +
		'</svg>',
	youtube: '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="24" height="24">' +
		'<path fill="#ff0033" d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/>' +
		'</svg>'
};

function renderConnCards() {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxy',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	const checkFns = [];   /* P3：收集每张卡的检测函数，供「全部检测」批量触发 */

	const items = [
		{ site: 'aliyun', title: _('Aliyun Connection') },
		{ site: 'google', title: _('Google Connection') },
		{ site: 'github', title: _('GitHub Connection') },
		{ site: 'youtube', title: _('YouTube Connection') }
	];

	const grid = E('div', { 'class': 'homeproxy-connect-grid' }, items.map((item) => {
		const icon = E('div', { 'class': 'homeproxy-connect-icon', 'aria-hidden': 'true' });
		icon.innerHTML = connLogos[item.site] || '';
		let result = E('div', {
			'class': 'homeproxy-connect-result',
			/* P2：可点击元素不能是裸 div——加 role/tabindex 与键盘处理，
			   让纯键盘与读屏用户也能触发检测；aria-live 让结果变化被播报。 */
			'role': 'button',
			'tabindex': '0',
			'aria-live': 'polite',
			'title': _('HTTP request latency: time from sending the request to receiving the first byte. DNS, TCP and TLS handshakes are NOT included, so the value is much smaller than ping or node latency. Same metric as Passwall.'),
			'click': ui.createHandlerFn(this, () => runConnCheck()),
			'keydown': (ev) => {
				if (ev.key === 'Enter' || ev.key === ' ' || ev.key === 'Spacebar') {
					ev.preventDefault();
					runConnCheck();
				}
			}
		}, [ _('Click to check') ]);

		/* P1：失败语义分类——把 curl 错误码映射成可操作的中文短词，
		   用户一眼看出是 DNS/TLS/超时/被拒，而不是笼统 failed。
		   成功时主数字仍是 HTTP 请求延迟（与 passwall 一致），细节进 tooltip。 */
		const failLabel = (ret) => {
			/* ret.error 已是语义码（dns/refused/timeout/tls/cert/reset/empty），
			   兼容旧后端（直接给中文句）时原样展示。 */
			switch (ret.error) {
			case 'dns':     return _('DNS failed');
			case 'refused': return _('Connection refused');
			case 'timeout': return _('Timed out');
			case 'tls':     return _('TLS handshake failed');
			case 'cert':    return _('Certificate error');
			case 'reset':   return _('Connection reset');
			case 'empty':   return _('Empty reply');
			default:        return ret.error ? _('Failed') : _('Failed');
			}
		};

		const lastCheckEl = E('span', { 'class': 'homeproxy-connect-time' }, [ ]);   /* P1 上次检测时间 */
		const runConnCheck = () => {
			result.textContent = _('Checking...', 'homeproxy');
			result.style.setProperty('color', 'var(--hp-warn)');
			result.title = _('Checking...', 'homeproxy');

			return L.resolveDefault(callConnStat(item.site), {}).then((ret) => {
				const now = new Date();
				const p2 = (n) => (n < 10 ? '0' + n : '' + n);
				const stamp = '%s:%s:%s'.format(p2(now.getHours()), p2(now.getMinutes()), p2(now.getSeconds()));
				if (ret.result && ret.latency != null) {
					/* 成功态用中性深灰（配 ✓ 图标已足够表达"通"），把 Signal Green
					   独占给「最佳得分」——修复绿语义被拉伸成 3 义。 */
					result.style.setProperty('color', 'var(--hp-text-strong)');
					result.textContent = '✓ %s ms'.format(ret.latency);
					result.title = _('HTTP request latency: %s ms (handshake excluded)')
						.format(ret.latency)
						+ '\n' + _('DNS + TCP + TLS handshake: %s ms').format(ret.handshake)
						+ '\n' + _('Time to first byte: %s ms').format(ret.total)
						+ '\n' + _('HTTP status code: %s').format(ret.code);
				} else {
					result.style.setProperty('color', 'var(--hp-danger)');
					/* 主标签只留语义词；curl 原始退出码挪进 tooltip，别推给普通用户。 */
					result.textContent = '✕ ' + failLabel(ret);
					result.title = failLabel(ret) + (ret.curl_rc ? '\n' + _('curl exit code: %s').format(ret.curl_rc) : '')
						+ '\n' + _('Click to retry');
				}
				if (lastCheckEl) {
					lastCheckEl.textContent = _('Checked at %s').format(stamp);
				}
			});
		};

		checkFns.push(runConnCheck);

		return E('div', { 'class': 'homeproxy-connect-card' }, [
			icon,
			E('div', { 'class': 'homeproxy-connect-info' }, [
				E('div', { 'class': 'homeproxy-connect-title' }, [ item.title ]),
				result,
				lastCheckEl
			])
		]);
	}));

	/* P3：「全部检测」——一次性触发所有连接卡，省去逐卡点的摩擦。
	   并发发起，各自更新自己的结果；按钮在全部返回前 disabled 防重复。 */
	/* 检测是中性"操作"，不用 action 蓝——蓝色在系统里专属「手动选择」语义，
	   避免一色二义（critique H4）。用普通按钮 + 检测中文案与恢复。 */
	const allBtn = E('button', {
		'class': 'btn cbi-button',
		'style': 'margin-bottom: 10px',
		'click': ui.createHandlerFn(this, () => {
			const label = _('Check all');
			allBtn.disabled = true;
			allBtn.textContent = _('Checking…');
			const done = () => { allBtn.disabled = false; allBtn.textContent = label; };
			const ps = checkFns.map((fn) => L.resolveDefault(Promise.resolve().then(fn), {}));
			return Promise.all(ps).then(done, done);
		})
	}, [ _('Check all') ]);

	return E('div', { 'class': 'homeproxy-connect-wrap' }, [ allBtn, grid ]);
}

function getResVersion(o, type) {
	const callResVersion = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_get_version',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdate = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update',
		params: ['type'],
		expect: { '': {} }
	});

	/* 上面那个后台任务的进度。resources_update 现在只负责启动（立即返回
	   {started:true}，已有任务在跑时返回 {started:false, running:true}），
	   真正的结果靠这个轮询：running=false 时 rc 就是 update_resources.sh 的
	   退出码（0 成功 / 1 失败 / 2 已有任务在跑 / 3 已是最新），log 是本次
	   运行新写入的日志行。
	   ⚠️ running 由**进程是否存活**决定，不只看 rc 文件在不在：连点两次时
	   第二个实例会立刻写下 rc=2（抢锁失败）而第一个还在下载，只看 rc 会让
	   界面提前两秒解锁并显示「Already in updating.」。 */
	const callResUpdatePoll = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update_poll',
		params: ['type'],
		expect: { '': {} }
	});

	/* 只把**本次**新写入的日志行拼在错误后面：脚本每次至少写一行
	   `[CHINA_IP4] …`，所以「增量有内容」本身就是「脚本真的跑起来了」的
	   证据。多行压成一行 —— 这个位置是 cbi-value-field 里的一小段文字，
	   换行会被压没、还会把相邻字段挤下去。 */
	const resReason = function(res) {
		return (res && res.log) ? ' ' + res.log.replace(/\s+/g, ' ').trim() : '';
	};

	const resOutcome = function(o, rc, res) {
		const reason = resReason(res);

		switch (rc) {
		case 0:
			o.description = _('Successfully updated.');
			break;
		case 1:
			o.description = _('Update failed.') + reason;
			break;
		case 2:
			o.description = _('Already in updating.');
			break;
		case 3:
			o.description = _('Already at the latest version.');
			break;
		default:
			/* 拿不到 rc（超时 / 轮询本身出错）时说「未知错误」是误导：脚本
			   可能还在跑。让用户去看日志，日志里有真实进度。 */
			o.description = _('Timed out waiting for the update. Please check the log.') + reason;
			break;
		}

		return o.map.reset();
	};

	return L.resolveDefault(callResVersion(type), {}).then((res) => {
		/* 按钮先建出来再挂 handler：handler 里的 `this` 是
		   ui.createHandlerFn 传进来的 ctx（LuCI 是 `fn.call(ctx, ev)`），
		   不是按钮元素 —— 用 `this` 当 btnEl 会拿到 undefined。 */
		const btnEl = E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(this, function() {
				/* 后台任务：rpcd 的 resources_update 只负责启动，立即返回
				   {started:true}；结果靠 resources_update_poll 轮询。
				   为什么不直接等一个同步返回值：那个 system() 会阻塞整个
				   rpcd（uci 也同进程），下载期间任何页面都渲染不出来。
				   实测见 luci.homeproxy 里 resources_update 的注释。
				   1.2 秒一轮、最多 150 秒（脚本两个 curl 的上限是
				   30 + 120 秒，再留一点收尾余量）。 */
				const POLL_MS = 1200;
				const DEADLINE_MS = 150000;
				const started_at = Date.now();

				const finish = function(rc, pres) {
					btnEl.disabled = false;
					btnEl.textContent = _('Check update');

					return resOutcome(o, rc, pres);
				};

				const poll = function() {
					/* 卸载守卫：页面已离开就停止轮询（对照 core 轮询的
					   document.body.contains 做法，audit P2）。 */
					if (!document.body.contains(btnEl))
						return finish(null, null);
					if (Date.now() - started_at > DEADLINE_MS)
						return finish(null, null);

					return L.resolveDefault(callResUpdatePoll(type), {})
						.then((ps) => {
							if (ps && ps.running === false)
								return finish(ps.rc, ps);

							return new Promise((r) => setTimeout(r, POLL_MS)).then(poll);
						})
						.catch(() => finish(null, null));
				};

				btnEl.disabled = true;
				btnEl.textContent = _('Updating...');

				/* 必须把这个 Promise 一路 return 出去：CBI 是在 handler 返回的
				   Promise resolve 之后才处理按钮状态的，早返回（返回 null）
				   等于「轮询期间按钮又能点」。 */
				return L.resolveDefault(callResUpdate(type), {}).then((ret) => {
					/* started=true  → 这次真的派生了新任务；
					   running=true  → 已有任务在跑，rpcd 没起第二个，回报现状。
					   两种情况都要转去轮询**同一个**任务：后者若不轮询，界面
					   会显示「更新失败」，而下载其实正在进行（多标签页 / 刷新后
					   再点就是这个场景）。 */
					if (ret && (ret.started === true || ret.running === true))
						return poll();

					/* 参数校验类错误（type 非法、脚本缺失）当场就回来，
					   不需要轮询。 */
					btnEl.disabled = false;
					btnEl.textContent = _('Check update');
					o.description = _('Update failed.') + (ret && ret.error ? ' ' + ret.error : '');
					return o.map.reset();
				}).catch(() => {
					btnEl.disabled = false;
					btnEl.textContent = _('Check update');
					o.description = _('Update failed.');
					return o.map.reset();
				});
			})
		}, [ _('Check update') ]);

		let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
			btnEl,
			' ',
			E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
				[ res.error ? 'not found' : res.version ]
			),
		]);

		o.default = spanTemp;
	});
}

return view.extend({
	render() {
		let m, s, o;

		/* The card styles below are not part of any stylesheet shipped with
		   the package, so they have to be injected here. Without them the
		   brand SVGs keep their intrinsic size and overflow the page. */
		if (!document.getElementById('homeproxy-connect-css')) {
			const style = E('style', { 'id': 'homeproxy-connect-css' });
			style.textContent = css;
			document.head.appendChild(style);
		}

		hp.installCloseButtonText();

		m = new form.Map('homeproxy');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_connection_check');
		o.rawhtml = true;
		o.render = renderConnCards;

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
		o.rawhtml = true;

		o = s.option(form.Value, 'github_token', _('GitHub token'));
		o.password = true;
		/* 必须显式 rmempty：值为空时 CBI 会 uci delete 掉该项。若不加，
		   再叠加密码框「空值不清 DOM」的行为（ui.Textfield 的 setValue 只在
		   value 非空时才写 DOM），用户清空后提交仍会把旧 token 写回 ——
		   现场：清空保存后 /etc/config/homeproxy 里仍有 option github_token。 */
		o.rmempty = true;
		o.optional = true;
		o.placeholder = _('leave empty = no token');
		o.description = _('Optional. It is only used when checking resource updates, to raise the GitHub API rate limit from 60 to 5000 requests per hour. Leave it empty (or click "Clear") to remove it. Note that the token is stored in plain text in /etc/config/homeproxy, so use a read-only one.');
		o.renderWidget = function() {
			/* 直接读 uci 判断「是否已设置」，不依赖 section 内部字段名。 */
			let current = '';
			try { current = this.map.uci.get('homeproxy', 'config', 'github_token') || ''; } catch (e) { current = ''; }
			let node = form.Value.prototype.renderWidget.apply(this, arguments);

			/* 令牌默认以星号（password）显示真实值；旁边一个「👁」按钮可切换
			   明文/遮挡。去掉原来的「已设置 — 输入可替换」占位提示。 */
			const input = node.querySelector ? node.querySelector('input') : null;
			if (input) {
				input.value = current;
				input.placeholder = '';
			}

			const actions = node.querySelector('.control-group') || node;

			actions.appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'title': _('Save'),
				'click': ui.createHandlerFn(this, () => {
					return this.map.save(null, true).then(() => {
						ui.changes.apply(true);
					});
				}, this.option)
			}, [ _('Save') ]));

			/* 显式「清除」：删掉该 option 再 commit + apply，绕开密码框的
			   「空值不清 DOM」问题，确保 uci 里真的没有 github_token。
			   ⚠ 必须用 uci.set(conf, sid, opt, null)：LuCI 的 uci.remove()
			   签名只有 (conf, sid) 两个参数（删整个段）。早期误传三个参数，
			   第三参数被忽略 → 删掉了整个 config 段 → 配置损坏、内核起不来
			   （2026-11 现场事故）。 */
			actions.appendChild(E('button', {
				'class': 'cbi-button cbi-button-reset',
				'title': _('Clear GitHub token (cannot be undone)'),
				'click': ui.createHandlerFn(this, () => {
					const map = this.map;
					const doClear = () => {
						map.uci.set('homeproxy', 'config', 'github_token', null);
						return map.uci.save().then(() => {
							if (input)
								input.value = '';
							return map.uci.apply().then(() => {
								ui.addNotification(null, E('p', _('GitHub token cleared and applied.')), 'info');
							});
						});
					};
					/* P0：清除令牌不可逆（早期误删 config 段的事故见上），点击
					   即执行太危险。先弹确认框，用户明确确认后才清除。用 LuCI
					   原生 showModal，不引入外来弹窗样式。 */
					ui.showModal(_('Clear GitHub token?'), [
						E('p', { 'class': 'cbi-section' }, [
							_('This will permanently remove the stored GitHub token. It cannot be undone. Resource-update checks that need the token will stop working until you enter a new one.')
						]),
						E('div', { 'class': 'right' }, [
							E('button', {
								'class': 'btn cbi-button',
								'click': ui.hideModal
							}, [ _('Cancel', 'homeproxy') ]),
							' ',
							E('button', {
								'class': 'btn cbi-button cbi-button-negative',
								'click': ui.createHandlerFn(this, () => {
									ui.hideModal();
									return doClear();
								})
							}, [ _('Yes, clear it') ])
						])
					]);
				}, this.option)
			}, [ _('Clear') ]));

			return node;
		}

	s = m.section(form.NamedSection, 'config', 'homeproxy', _('sing-box core management'));
	s.anonymous = true;

	const callCoreStatus = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_status',
		expect: { '': {} }
	});

	const callCoreUpdate = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_update',
		expect: { '': {} }
	});

	const callCoreProgress = rpc.declare({
		object: 'luci.homeproxy',
		method: 'singbox_core_progress',
		expect: { '': {} }
	});

	/* A 34 MB core tarball needs anywhere from 4 to 33 minutes on the mirrors
	   we ship, so the update now runs detached on the router and this page
	   polls for progress. Holding one request open for the whole transfer is
	   what used to make the download fail halfway with an empty log. */
	const CORE_POLL_INTERVAL = 3000;

	function coreLastLogLine(text) {
		const lines = (text || '').split('\n').map(l => l.trim()).filter(l => l);

		if (!lines.length)
			return '';

		/* The progress lines contain full mirror URLs (100+ chars); showing
		   one verbatim next to the button would blow out the row layout. */
		const line = lines[lines.length - 1];
		return (line.length > 90) ? line.slice(0, 90) + '…' : line;
	}

	o = s.option(form.DummyValue, '_singbox_core', _('reF1nd sing-box core'));
	o.rawhtml = true;
	o.render = function() {
		const self = this;
		let polling = false;

		const statusEl = E('strong', { 'style': 'color:var(--hp-text-muted)', 'aria-live': 'polite' }, [ _('loading...') ]);

		function showResult(res) {
			polling = false;
			btn.disabled = false;

			let msg, level;
			if (res.result) {
				msg = _('Download / update succeeded.');
				level = 'info';
			}
			else if (res.output && res.output.indexOf('unsupported') !== -1) {
				msg = _('Current architecture is not supported by reF1nd yet.');
				level = 'danger';
			}
			else if (res.output && res.output.indexOf('no_asset') !== -1) {
				msg = _('No matching binary for this architecture yet.');
				level = 'danger';
			}
			else {
				msg = _('Download / update failed. See log for details.');
				const tail = (res.log || '').split('\n').filter(l => l.trim()).slice(-4).join(' ; ');
				if (tail)
					msg += ' ' + tail;
				level = 'danger';
			}

			/* self.description is not rendered by this custom DummyValue
			   render, so surface the outcome as a toast — otherwise a failed
			   update looked like a dead button. */
			ui.addNotification(null, E('p', msg), level);
			return self.map.reset();
		}

		function startPolling() {
			if (polling)
				return;

			polling = true;
			btn.disabled = true;
			dom.content(statusEl, _('Downloading sing-box core…'));

			const tick = () => {
				/* The user may have navigated away while a 30-minute download
				   ran. Polling is detached from this view's lifecycle, so bail
				   out once our node is gone instead of resetting a form that
				   no longer exists. */
				if (!document.body.contains(statusEl)) {
					polling = false;
					return;
				}

				L.resolveDefault(callCoreProgress(), {}).then((res) => {
					tick.err_n = 0;   /* 成功响应即清零重试计数 */
					if (res.running) {
						const line = coreLastLogLine(res.log);
						if (line)
							dom.content(statusEl, line);
						window.setTimeout(tick, CORE_POLL_INTERVAL);
						return;
					}
					showResult(res);
				}).catch(() => {
					/* A transient rpc error (rpcd restart, page reload race)
					   must not orphan a download that is still running on the
					   router: keep polling instead of declaring failure —
					   but cap retries so a dead rpcd doesn't spin forever
					   (audit P2: 无限重试 → 上限 20 次 ≈ 60s 后停止）。 */
					tick.err_n = (tick.err_n || 0) + 1;
					if (tick.err_n > 20) {
						polling = false;
						return;
					}
					window.setTimeout(tick, CORE_POLL_INTERVAL);
				});
			};

			/* Give the detached wrapper a moment to create its pid file. */
			window.setTimeout(tick, 1500);
		}

		const btn = E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(this, () => {
				if (polling)
					return;

				btn.disabled = true;
				dom.content(statusEl, _('Starting download…'));

				return L.resolveDefault(callCoreUpdate(), {}).then((res) => {
					/* Running (freshly started, or already in progress from an
					   earlier click) — switch to polling instead of waiting
					   for a response that will not arrive for many minutes. */
					if (res.running || res.started) {
						startPolling();
						return;
					}

					btn.disabled = false;
					dom.content(statusEl, res.log || _('unavailable'));
					ui.addNotification(null, E('p', res.log || _('Download / update failed. See log for details.')), 'danger');
					return null;
				}).catch(() => {
					btn.disabled = false;
				});
			})
		}, [ _('Download / update core') ]);

		let content = E('div', { 'style': 'cbi-value-field' }, [ btn, ' ', statusEl ]);

		/* Resume the display when the page is reopened mid-download: the
		   helper keeps running detached, so a reload must not lose progress. */
		L.resolveDefault(callCoreProgress(), {}).then((res) => {
			if (res.running) {
				startPolling();
				return null;
			}

			return L.resolveDefault(callCoreStatus(), {}).then((sres) => {
				let detail;
				if (sres.installed_version && sres.installed_version !== '-')
					detail = _('Installed: %s').format(sres.installed_version);
				else
					detail = _('Not installed');

				detail += ' / ' + _('Arch: %s').format(sres.arch || '-');

				/* 目标版本用「完整版本串」（1.14.4-reF1nd_<发布版本>），
				   与安装后 sing-box version 报出来的完全一致；旧后端没有
				   target_version 时回落到基础版本号。 */
				if (sres.asset_available)
					detail += ' / ' + _('Target: %s').format(sres.target_version || sres.refind_version || '-');
				else
					detail += ' / ' + _('No binary for this arch yet');

				dom.content(statusEl, detail);
			});
		}).catch(() => {
			dom.content(statusEl, _('unavailable'));
		});

		return content;
	};


		/* 综合评分：只展示 node=='score' 的组，每组独立排行（手动选择 /
		   延时最低不参与）。无评分组时整个区块仍显示一句提示。 */
		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Comprehensive score'));
		s.anonymous = true;
		o = s.option(form.DummyValue, '_score_status');
		o.rawhtml = true;
		o.render = renderScoreCards;

	return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
