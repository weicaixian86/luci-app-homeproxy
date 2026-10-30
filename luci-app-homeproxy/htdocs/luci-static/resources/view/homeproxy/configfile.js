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
		const checkBox = E('div', { 'class': 'cbi-value-description' }, _('The UCI syntax is checked before switching; if it fails, the current profile is kept and the error is written to the log.'));
		const currentText = E('div', { 'class': 'cbi-value-description' }, _('Current configuration file: %s').format(current));
		const status = E('div', { 'class': 'cbi-value-description' }, _('Configuration directory: /etc/config/; the default profile cannot be uploaded; names must match homeproxy-*.'));
		const apply = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Switch & Apply'));
		const upload = E('button', { 'class': 'cbi-button cbi-button-add' }, _('Upload configuration file'));
		const refresh = E('button', { 'class': 'cbi-button' }, _('Refresh list'));

		/* 下载走 ubus 取内容、前端造 Blob 落盘：文件名由界面决定，
		   /etc/config 就不必为它开 cgi-io 的下载权限。 */
		const downloadProfile = (name) => callRead(name).then((res) => {
			if (!res.result) {
				notify(_('Download failed: %s').format(res.error || _('Unknown error')), 'danger');
				return;
			}

			const blob = new Blob([ res.content ], { type: 'text/plain;charset=utf-8' });
			const url = URL.createObjectURL(blob);
			const link = E('a', { href: url, download: name });

			document.body.appendChild(link);
			link.click();
			document.body.removeChild(link);
			window.setTimeout(() => URL.revokeObjectURL(url), 1000);
		}, (err) => notify(_('Download failed: %s').format(err || _('Unknown error')), 'danger'));

		const deleteProfile = (name) => callDelete(name).then((res) => {
			notify(res.result ? _('Deleted: %s').format(name) : _('Delete failed: %s').format(res.error || _('Unknown error')), res.result ? 'info' : 'danger');
			if (res.result) window.setTimeout(() => window.location.reload(), 500);
		}, (err) => notify(_('Delete failed: %s').format(err || _('Unknown error')), 'danger'));

		/* 删除按**文件行**做，并且二次确认：一份配置删掉就只能重新上传，
		   以前那个贴在选下拉右边的「删除选中配置」一歪手就是另一份配置没了。 */
		const confirmDelete = (name) => ui.showModal(_('Delete configuration file'), [
			E('p', {}, _('Delete %s? It can only be brought back by uploading it again.').format(name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'cbi-button cbi-button-remove', 'click': () => { ui.hideModal(); deleteProfile(name); } }, _('Delete'))
			])
		]);

		const fileRow = (name) => {
			const inUse = (name === current);

			return E('div', { 'style': 'display:flex;align-items:center;gap:.5em;margin:.25em 0;' }, [
				E('span', { 'style': 'min-width:16em;' }, [ name, inUse ? ' ' + _('(in use)') : null ]),
				E('button', { 'class': 'cbi-button', 'click': () => downloadProfile(name) }, _('Download')),
				/* 正在用的那份不给删：脚本也会拒，界面上直接不给按钮更省事。 */
				inUse ? null : E('button', { 'class': 'cbi-button cbi-button-remove', 'click': () => confirmDelete(name) }, _('Delete'))
			]);
		};

		const panel = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Configuration File')),
			E('div', { 'class': 'cbi-map-descr' }, _('Manage HomeProxy configuration files. Ordinary settings still use Save & Apply at the bottom right; switching a profile uses Switch & Apply on this page.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Select configuration file')), E('div', { 'class': 'cbi-value-field' }, [ select, ' ', apply ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Status')), E('div', { 'class': 'cbi-value-field' }, [ currentText, checkBox ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Upload configuration file')), E('div', { 'class': 'cbi-value-field' }, [ nameInput, ' ', fileInput, ' ', upload, ' ', refresh, status ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Uploaded configuration files')),
					E('div', { 'class': 'cbi-value-field' }, files.length
						? files.map(fileRow)
						: [ E('div', { 'class': 'cbi-value-description' }, _('No additional configuration file has been uploaded yet.')) ]) ])
			])
		]);

		const selected = () => select.value || 'homeproxy-default';
		/* 「切换并应用」自带校验：脚本先在校验目录里跑一遍 `uci show`，通过才
		   替换激活配置。失败时下拉必须退回当前生效的那一个 —— 否则界面停在
		   一个「看起来已选中、其实没生效」的选项上，用户会以为已经切过去了。 */
		apply.addEventListener('click', () => {
			const target = selected();

			if (target === current) {
				notify(_('Already the current profile: %s.').format(target), 'info');
				return;
			}

			callSwitch(target).then((res) => {
				if (res.result) {
					notify(_('Switched to %s; the service is reloading.').format(target), 'info');
					window.setTimeout(() => window.location.reload(), 1200);
					return;
				}

				select.value = current;
				notify(_('Switch failed: %s (reverted to the current profile %s)').format(res.error || _('Unknown error'), current), 'danger');
			}, (err) => {
				/* 请求本身失败（rpcd 挂掉、超时）也要退回，不能让下拉停在
				   一个根本没生效的选项上。 */
				select.value = current;
				notify(_('Switch failed: %s (reverted to the current profile %s)').format(err || _('Unknown error'), current), 'danger');
			});
		});
		upload.addEventListener('click', () => {
			const name = nameInput.value.trim();
			if (!/^homeproxy-[A-Za-z0-9_.-]+$/.test(name) || name === 'homeproxy-back') {
				notify(_('The name must start with homeproxy-, e.g. homeproxy-123.'), 'danger');
				return;
			}
			if (!fileInput.files || !fileInput.files[0]) {
				notify(_('Select a configuration file to upload.'), 'danger');
				return;
			}
			/* 真实的 UCI 配置是几十 KB。不挡大小的话，误选一个镜像或日志就会
			   被写进 overlay 的 /etc/config，把 flash 塞满。 */
			if (fileInput.files[0].size > 1048576) {
				notify(_('The selected file is larger than 1 MB; check that it is a UCI configuration file.'), 'danger');
				return;
			}
			ui.uploadFile('/tmp/homeproxy_profile.tmp', fileInput).then(() => callUpload(name)).then((res) => {
				notify(res.result ? _('Uploaded %s. Select it in the list and click Switch & Apply.').format(name) : _('Upload failed: %s').format(res.error || _('Unknown error')), res.result ? 'info' : 'danger');
				if (res.result) window.setTimeout(() => window.location.reload(), 500);
			}, () => notify(_('Upload failed: %s').format(_('Unknown error')), 'danger'));
		});
		refresh.addEventListener('click', () => window.location.reload());
		return panel;
	}
});
