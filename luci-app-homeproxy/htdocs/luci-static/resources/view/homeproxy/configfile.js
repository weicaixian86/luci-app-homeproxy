'use strict';
'require baseclass';
'require rpc';
'require ui';
'require view';

const callList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_list',
	expect: { '': {} }
});
const callCheck = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_check',
	params: [ 'name' ],
	expect: { '': {} }
});
const callSwitch = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_switch',
	params: [ 'name' ],
	expect: { '': {} }
});
const callUpload = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_upload',
	params: [ 'name' ],
	expect: { '': {} }
});
const callDelete = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_delete',
	params: [ 'name' ],
	expect: { '': {} }
});

function notify(message, level) {
	ui.addNotification(null, E('p', {}, message), level || 'info');
}

return view.extend({
	load() {
		return callList();
	},

	render(data) {
		const state = data || {};
		const current = state.current || 'homeproxy-default';
		const files = state.files || [];
		const select = E('select', { 'class': 'cbi-input-select', 'style': 'min-width: 22em;' },
			[ 'homeproxy-default' ].concat(files).map((name) =>
				E('option', { value: name, selected: name === current }, name)));
		const nameInput = E('input', {
			'class': 'cbi-input-text', 'type': 'text', 'placeholder': 'homeproxy-123',
			'style': 'min-width: 18em;'
		});
		const fileInput = E('input', { 'type': 'file', 'accept': '.conf,.uci,*/*' });
		const checkBox = E('div', { 'class': 'cbi-value-description' }, _('切换前会检查 UCI 配置格式，错误时当前配置不会改变。'));
		const currentText = E('div', { 'class': 'cbi-value-description' }, _('当前配置文件：%s').format(current));
		const status = E('div', { 'class': 'cbi-value-description' }, _('配置文件目录：/etc/config/；默认配置文件不参与上传列表。'));
		const apply = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('切换并应用'));
		const check = E('button', { 'class': 'cbi-button cbi-button-action' }, _('检查配置'));
		const upload = E('button', { 'class': 'cbi-button cbi-button-add' }, _('上传配置文件'));
		const remove = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('删除选中配置'));
		const refresh = E('button', { 'class': 'cbi-button' }, _('刷新列表'));
		const panel = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('配置文件')),
			E('div', { 'class': 'cbi-map-descr' }, _('管理 HomeProxy 配置文件。普通设置仍使用页面右下角的“保存并应用”；切换配置使用本页“切换并应用”。')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('选择配置文件')), E('div', { 'class': 'cbi-value-field' }, [ select, ' ', apply, ' ', check, ' ', remove ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('状态')), E('div', { 'class': 'cbi-value-field' }, [ currentText, checkBox ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('上传配置文件')), E('div', { 'class': 'cbi-value-field' }, [ nameInput, ' ', fileInput, ' ', upload, ' ', refresh, status ]) ])
			])
		]);

		const selected = () => select.value || 'homeproxy-default';
		const reload = () => L.resolveDefault(callList(), {}).then((next) => {
			const url = window.location.href;
			window.location.href = url;
			return next;
		});
		check.addEventListener('click', () => callCheck(selected()).then((res) => notify(res.result ? _('配置格式正确。') : _('配置格式错误：%s').format(res.error || _('未知错误')), res.result ? 'info' : 'danger')));
		apply.addEventListener('click', () => callSwitch(selected()).then((res) => {
			if (res.result) notify(_('已切换配置：%s，服务正在重新加载。').format(selected()), 'info');
			else notify(_('切换失败：%s').format(res.error || _('未知错误')), 'danger');
			if (res.result) window.setTimeout(() => window.location.reload(), 1200);
		}));
		upload.addEventListener('click', () => {
			const name = nameInput.value.trim();
			if (!/^homeproxy-[A-Za-z0-9_.-]+$/.test(name) || name === 'homeproxy-back') {
				notify(_('文件名必须是 homeproxy- 前缀，例如 homeproxy-123。'), 'danger');
				return;
			}
			if (!fileInput.files || !fileInput.files[0]) {
				notify(_('请选择要上传的配置文件。'), 'danger');
				return;
			}
			ui.uploadFile('/tmp/homeproxy_profile.tmp', fileInput).then(() => callUpload(name)).then((res) => {
				notify(res.result ? _('上传成功：%s。请在列表中选择后点击“切换并应用”。').format(name) : _('上传失败：%s').format(res.error || _('未知错误')), res.result ? 'info' : 'danger');
				if (res.result) window.setTimeout(() => window.location.reload(), 500);
			});
		});
		remove.addEventListener('click', () => {
			const name = selected();
			if (name === 'homeproxy-default') { notify(_('默认配置文件不能删除。'), 'danger'); return; }
			callDelete(name).then((res) => {
				notify(res.result ? _('已删除：%s').format(name) : _('删除失败：%s').format(res.error || _('未知错误')), res.result ? 'info' : 'danger');
				if (res.result) window.setTimeout(() => window.location.reload(), 500);
			});
		});
		refresh.addEventListener('click', () => window.location.reload());
		return panel;
	}
});
