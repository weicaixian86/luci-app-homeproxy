/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require view';

'require homeproxy as hp';
'require homeproxy.logview as logview';

/* 插件日志：只有插件自己写的那四个文件，**一个过滤器都没有**。
 *
 * 这个页面存在的意义就是「原样看全部」：运行日志页有两个下拉（显示视图 /
 * 内核级别），排查时最怕的就是「明明有这行，界面上却看不到」——而问题常常
 * 只是某个过滤器还停在上次选的值。这里不做任何过滤，也不读 uci 里的
 * log_view，每一行都显示。
 *
 * 内核日志（sing-box-c / sing-box-s）单独成页，见 log_core.js。 */
const log_sources = [
	{ file: 'homeproxy' },
	{ file: 'ruleset_download' },
	{ file: 'core_download' },
	{ file: 'panel_download' }
];

return view.extend({
	render() {
		hp.installCloseButtonText();

		const page = logview.renderPage(this, {
			key: 'log-plugin-refresh',
			sources: log_sources,
			empty: _('The plugin has not written anything yet.')
		});

		return E(page.nodes);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
