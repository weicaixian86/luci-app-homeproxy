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
const callRead = rpc.declare({
	object: 'luci.homeproxy',
	method: 'config_profile_read',
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
			'class': 'cbi-input-text', 'type': 'text',
			'style': 'min-width: 18em;'
		});
		const fileInput = E('input', { 'type': 'file', 'accept': '.conf,.uci,*/*' });
		const checkBox = E('div', { 'class': 'cbi-value-description' }, _('切换时会先检查 UCI 配置格式；不通过则退回当前配置，并把错误写入日志。'));
		const currentText = E('div', { 'class': 'cbi-value-description' }, _('当前配置文件：%s').format(current));
		const status = E('div', { 'class': 'cbi-value-description' }, _('配置文件目录：/etc/config/，默认配置文件不参与上传列表，文件名为 homeproxy-*。'));
		const apply = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('切换并应用'));
		const upload = E('button', { 'class': 'cbi-button cbi-button-add' }, _('上传配置文件'));
		const refresh = E('button', { 'class': 'cbi-button' }, _('刷新列表'));

		/* 下载走 ubus 取内容、前端造 Blob 落盘：文件名由界面决定，
		   /etc/config 就不必为它开 cgi-io 的下载权限。 */
		const downloadProfile = (name) => callRead(name).then((res) => {
			if (!res.result) {
				notify(_('下载失败：%s').format(res.error || _('未知错误')), 'danger');
				return;
			}

			const blob = new Blob([ res.content ], { type: 'text/plain;charset=utf-8' });
			const url = URL.createObjectURL(blob);
			const link = E('a', { href: url, download: name });

			document.body.appendChild(link);
			link.click();
			document.body.removeChild(link);
			window.setTimeout(() => URL.revokeObjectURL(url), 1000);
		}, (err) => notify(_('下载失败：%s').format(err || _('未知错误')), 'danger'));

		const deleteProfile = (name) => callDelete(name).then((res) => {
			notify(res.result ? _('已删除：%s').format(name) : _('删除失败：%s').format(res.error || _('未知错误')), res.result ? 'info' : 'danger');
			if (res.result) window.setTimeout(() => window.location.reload(), 500);
		});

		/* 删除按**文件行**做，并且二次确认：一份配置删掉就只能重新上传，
		   以前那个贴在选下拉右边的「删除选中配置」一歪手就是另一份配置没了。 */
		const confirmDelete = (name) => ui.showModal(_('删除配置文件'), [
			E('p', {}, _('确定要删除 %s 吗？删除后只能重新上传。').format(name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
				' ',
				E('button', { 'class': 'cbi-button cbi-button-remove', 'click': () => { ui.hideModal(); deleteProfile(name); } }, _('删除'))
			])
		]);

		const fileRow = (name) => {
			const inUse = (name === current);

			return E('div', { 'style': 'display:flex;align-items:center;gap:.5em;margin:.25em 0;' }, [
				E('span', { 'style': 'min-width:16em;' }, [ name, inUse ? ' ' + _('（使用中）') : null ]),
				E('button', { 'class': 'cbi-button', 'click': () => downloadProfile(name) }, _('下载')),
				/* 正在用的那份不给删：脚本也会拒，界面上直接不给按钮更省事。 */
				inUse ? null : E('button', { 'class': 'cbi-button cbi-button-remove', 'click': () => confirmDelete(name) }, _('删除'))
			]);
		};

		const panel = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('配置文件')),
			E('div', { 'class': 'cbi-map-descr' }, _('管理 HomeProxy 配置文件。普通设置仍使用页面右下角的“保存并应用”；切换配置使用本页“切换并应用”。')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('选择配置文件')), E('div', { 'class': 'cbi-value-field' }, [ select, ' ', apply ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('状态')), E('div', { 'class': 'cbi-value-field' }, [ currentText, checkBox ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('上传配置文件')), E('div', { 'class': 'cbi-value-field' }, [ nameInput, ' ', fileInput, ' ', upload, ' ', refresh, status ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('已上传的配置文件')),
					E('div', { 'class': 'cbi-value-field' }, files.length
						? files.map(fileRow)
						: [ E('div', { 'class': 'cbi-value-description' }, _('还没有上传过配置文件。')) ]) ])
			])
		]);

		const selected = () => select.value || 'homeproxy-default';
		const reload = () => L.resolveDefault(callList(), {}).then((next) => {
			const url = window.location.href;
			window.location.href = url;
			return next;
		});
		/* 「切换并应用」自带校验：脚本先在校验目录里跑一遍 `uci show`，通过才
		   替换激活配置。失败时下拉必须退回当前生效的那一个 —— 否则界面停在
		   一个「看起来已选中、其实没生效」的选项上，用户会以为已经切过去了。 */
		apply.addEventListener('click', () => {
			const target = selected();

			if (target === current) {
				notify(_('已经是当前配置：%s。').format(target), 'info');
				return;
			}

			callSwitch(target).then((res) => {
				if (res.result) {
					notify(_('已切换配置：%s，服务正在重新加载。').format(target), 'info');
					window.setTimeout(() => window.location.reload(), 1200);
					return;
				}

				select.value = current;
				notify(_('切换失败：%s（已退回当前配置 %s）').format(res.error || _('未知错误'), current), 'danger');
			}, (err) => {
				/* 请求本身失败（rpcd 挂掉、超时）也要退回，不能让下拉停在
				   一个根本没生效的选项上。 */
				select.value = current;
				notify(_('切换失败：%s（已退回当前配置 %s）').format(err || _('未知错误'), current), 'danger');
			});
		});
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
		refresh.addEventListener('click', () => window.location.reload());
		return panel;
	}
});
