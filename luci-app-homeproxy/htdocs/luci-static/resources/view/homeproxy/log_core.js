/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require view';

'require homeproxy as hp';
'require homeproxy.logview as logview';

/* 内核日志：只有 sing-box 自己的输出（客户端 + 服务端两个实例），
 * **一个过滤器都没有** —— 不分级别，debug/trace 也照样显示。
 *
 * 与插件日志分开的理由：内核的行带级别 token、时间戳可能来自 UTC（本机没有
 * tzdata 时），混在插件日志里既看不清 `outbound/xxx` 之类的明细，也容易被
 * 「显示视图」的下拉一过滤就整片消失。这里原样给出，UTC→本地 的换算说明由
 * logview 按 core_tz 标记自动补上。 */
const log_sources = [
	{ file: 'sing-box-c', core: true },
	{ file: 'sing-box-s', core: true }
];

return view.extend({
	render() {
		hp.installCloseButtonText();

		const page = logview.renderPage(this, {
			key: 'log-core-refresh',
			sources: log_sources,
			empty: _('The core has not written anything yet.')
		});

		return E(page.nodes);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
