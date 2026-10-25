/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require ui';
'require view';

'require homeproxy as hp';
'require homeproxy.logview as logview';

/* 日志设置：只剩两个数字 + 一个单位。
 *
 * 为什么不是 uci 表单：这两个值改了不该重启服务。uci commit 会改
 * /etc/config/homeproxy 的 mtime，procd 的 config.change 触发器随即把
 * homeproxy reload 一遍（= stop + start，所有连接断一次）；为了一个刷新
 * 间隔去重启隧道显然不能接受。所以走 rpcd 写 /etc/homeproxy/log.conf，
 * 前端、clean_log.sh 各读一次，和配置彻底解耦。
 *
 * 也因此这个页面没有「保存并应用」，只有一个「保存」——本来就没有需要
 * apply 的东西。 */

const css = `
.hp-logset-row {
	display: flex;
	align-items: center;
	flex-wrap: wrap;
	gap: 8px;
	padding: 10px 12px;
	border-bottom: 1px solid rgba(128,128,128,.18);
}
.hp-logset-row:last-child {
	border-bottom: none;
}
.hp-logset-label {
	flex: 0 0 13em;
	font-weight: 600;
}
.hp-logset-field {
	display: flex;
	align-items: center;
	gap: 6px;
}
.hp-logset-field input[type="number"] {
	width: 7em;
}
.hp-logset-hint {
	padding: 8px 12px 0;
	color: #666;
	font-size: 12px;
	line-height: 1.6;
}
.hp-logset-buttons {
	display: flex;
	gap: 8px;
	padding: 12px;
}
`;

function num(v, lo, hi, dflt) {
	return logview.clampInt(v, lo, hi, dflt);
}

return view.extend({
	render() {
		hp.installCloseButtonText();

		let settings = logview.normalizeSettings(logview.DEFAULT_SETTINGS);

		/* 刷新间隔：只决定这个页面多久重读一次日志文件。 */
		const refresh_in = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': String(logview.REFRESH_MIN),
			'max': String(logview.REFRESH_MAX),
			'step': '1',
			'value': String(settings.refresh)
		});

		/* 大小上限：值 + 单位（与截图一致，两个独立的控件）。 */
		const size_in = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': String(logview.SIZE_MIN),
			'max': String(logview.SIZE_MAX),
			'step': '1',
			'value': String(settings.size)
		});

		const unit_sel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'MB' }, [ 'MB' ]),
			E('option', { 'value': 'KB' }, [ 'KB' ])
		]);
		unit_sel.value = settings.unit;

		/* 生效值回显：让人一眼看到「1 MB」到底是多少字节、会不会被下限夹住。 */
		const effective = E('div', { 'class': 'hp-logset-hint' });

		function paint() {
			const bytes = logview.settingsBytes(settings);

			dom_content(effective, [
				logview.zh('Currently in effect: %s per log file.',
					_('Currently in effect: %s per log file.'), '当前生效：每个日志文件 %s。').format(logview.formatBytes(bytes)),
				' ',
				logview.zh('There are six log files in total.',
					_('There are six log files in total.'), '一共 6 个日志文件。')
			]);
		}

		/* dom.content 只在小区域里用一次，直接内联实现，免得为了一个方法把
		   dom 整个 require 进来（这个页面其余部分全是静态节点）。 */
		function dom_content(node, children) {
			while (node.firstChild)
				node.removeChild(node.firstChild);

			(Array.isArray(children) ? children : [ children ]).forEach((c) => {
				if (c === null || c === undefined)
					return;
				node.appendChild((typeof c === 'string' || typeof c === 'number')
					? document.createTextNode(String(c)) : c);
			});
		}

		paint();

		L.resolveDefault(logview.callSettings(), null).then((raw) => {
			settings = logview.normalizeSettings(raw ? raw : logview.DEFAULT_SETTINGS);
			refresh_in.value = String(settings.refresh);
			size_in.value = String(settings.size);
			unit_sel.value = settings.unit;
			paint();
		});

		const save_btn = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': ui.createHandlerFn(this, () => {
				settings = logview.normalizeSettings({
					refresh: refresh_in.value,
					size: size_in.value,
					unit: unit_sel.value
				});

				/* 夹过的值写回控件：输入 0 或 99999 时不该让界面停在一个
				   后端根本不会采用、也不显示的数字上。 */
				refresh_in.value = String(settings.refresh);
				size_in.value = String(settings.size);
				unit_sel.value = settings.unit;

				return logview.saveSettings(
					String(settings.refresh), String(settings.size), settings.unit
				).then((res) => {
					if (res && res.result === false)
						throw new Error(res.error || 'save failed');

					const applied = logview.normalizeSettings(res || settings);
					settings = applied;
					refresh_in.value = String(applied.refresh);
					size_in.value = String(applied.size);
					unit_sel.value = applied.unit;
					paint();

					ui.addNotification(null, E('p', [
						logview.zh('Log settings saved.', _('Log settings saved.'), '日志设置已保存。')
					]), 'info');
				}).catch((e) => {
					/* 最常见的两种失败：rpcd 里还是旧版 ucode（Method not
					   found）和 /etc/homeproxy 不可写。说清该怎么办，不要
					   只回一个英文异常 —— 但原文也留着（小字），否则「为什么
					   失败」又变成了猜。 */
					ui.addNotification(null, E('div', {}, [
						E('p', [
							logview.zh('Failed to save the log settings: %s',
								_('Failed to save the log settings: %s'),
								'日志设置保存失败：%s').format(
								logview.zh('if this is a fresh upgrade, restart rpcd first (/etc/init.d/rpcd restart)',
									_('if this is a fresh upgrade, restart rpcd first (/etc/init.d/rpcd restart)'),
									'如果是刚升级完，请先重启 rpcd（/etc/init.d/rpcd restart）')
							)
						]),
						E('p', {}, [ E('small', {}, [ String((e && e.message) || e || '') ]) ])
					]), 'danger');
				});
			})
		}, [ logview.zh('Save', _('Save'), '保存') ]);

		const reset_btn = E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(this, () => {
				settings = logview.normalizeSettings(logview.DEFAULT_SETTINGS);
				refresh_in.value = String(settings.refresh);
				size_in.value = String(settings.size);
				unit_sel.value = settings.unit;
				paint();
			})
		}, [ logview.zh('Restore defaults', _('Restore defaults'), '恢复默认') ]);

		return E([
			E('style', [ css ]),
			E('div', { 'class': 'cbi-map' }, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'hp-logset-row' }, [
						E('div', { 'class': 'hp-logset-label' }, [
							logview.zh('Log refresh interval', _('Log refresh interval'), '日志刷新时间')
						]),
						E('div', { 'class': 'hp-logset-field' }, [
							refresh_in,
							E('span', {}, [ logview.zh('seconds', _('seconds'), '秒') ])
						])
					]),
					E('div', { 'class': 'hp-logset-row' }, [
						E('div', { 'class': 'hp-logset-label' }, [
							logview.zh('Log size limit', _('Log size limit'), '日志大小上限')
						]),
						E('div', { 'class': 'hp-logset-field' }, [ size_in ])
					]),
					E('div', { 'class': 'hp-logset-row' }, [
						E('div', { 'class': 'hp-logset-label' }, [
							logview.zh('Log size limit unit', _('Log size limit unit'), '日志大小上限单位')
						]),
						E('div', { 'class': 'hp-logset-field' }, [ unit_sel ])
					]),
					effective,
					E('div', { 'class': 'hp-logset-hint' }, [
						logview.zh('The refresh interval only decides how often these log pages re-read their files. It is stored separately from the service configuration, so changing it never restarts the core.',
							_('The refresh interval only decides how often these log pages re-read their files. It is stored separately from the service configuration, so changing it never restarts the core.'),
							'刷新时间只决定这几个日志页面多久重新读一次文件。它和服务配置分开存放，改它不会重启内核。'),
						E('br'),
						logview.zh('When a log file reaches the size limit it is copied to .1 (one generation) and then emptied, so the oldest lines are the ones that go. The log pages no longer cut the display at a fixed number of lines: whatever is in the file is shown.',
							_('When a log file reaches the size limit it is copied to .1 (one generation) and then emptied, so the oldest lines are the ones that go. The log pages no longer cut the display at a fixed number of lines: whatever is in the file is shown.'),
							'日志文件达到上限时先另存为 .1（保留一代）再清空，被丢弃的是最早的行。日志页面不再按固定条数截断显示：文件里有多少行就显示多少行。')
					])
				]),
				E('div', { 'class': 'hp-logset-buttons' }, [ save_btn, reset_btn ])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
