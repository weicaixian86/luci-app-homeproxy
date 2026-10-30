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
			[ 'homeproxy-default' ].concat(files).map((name) => E('option', { value: name }, name)));

		/* 选中项用 value 显式设定，不能把 `selected: false` 交给 E()：那会写出
		   selected="false"，而 HTML 里**属性存在就算选中**，于是所有 option 都成
		   了选中态，刷新后下拉停下来的那一项并不是当前配置（0.3.1 现场：状态行写
		   homeproxy-default，下拉却停在 homeproxy-0.2.15）。 */
		select.value = current;

		if (select.value !== current)
			select.value = 'homeproxy-default';
		/* 文件选择器藏在「上传文件」按钮后面：页面上只留一个动作，名字从文件名
		   推导，用户既不用先想名字，也不会看见一个空的文件框。
		   不设 accept：UCI 配置本来就没有扩展名，一旦写了 *.conf;*.uci，Windows
		   的「打开」对话框会变成「自定义文件」，那些无后缀的 homeproxy 备份直接
		   看不见（就算再补一个通配项，浏览器也会把它折叠掉，放不了行）。 */
		const fileInput = E('input', { 'type': 'file', 'style': 'display: none;' });
		const checkBox = E('div', { 'class': 'cbi-value-description' }, _('The UCI syntax is checked when switching; if it fails, the current profile is kept and the error is written to the log.'));
		const status = E('div', { 'class': 'cbi-value-description' }, _('Configuration directory: /etc/config/; the default profile is not uploadable; uploaded files must be named homeproxy-<your-name>; the default profile is /etc/config/homeproxy-default.'));
		const apply = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Switch & Apply'));
		const uploadFile = E('button', { 'class': 'cbi-button cbi-button-add' }, _('Upload file'));
		const refresh = E('button', { 'class': 'cbi-button' }, _('Refresh list'));

		const uploadProfile = (name) => ui.uploadFile('/tmp/homeproxy_profile.tmp', fileInput).then(() => callUpload(name)).then((res) => {
			notify(res.result ? _('Uploaded %s. Choose it in the dropdown above, then click Switch & Apply.').format(name) : _('Upload failed: %s').format(res.error || _('Unknown error')), res.result ? 'info' : 'danger');
			fileInput.value = '';
			if (res.result) window.setTimeout(() => window.location.reload(), 500);
		}, () => {
			notify(_('Upload failed: %s').format(_('Unknown error')), 'danger');
			fileInput.value = '';
		});

		/* 选完文件立刻上传，名字取自文件名。只切掉 .conf/.uci/.bak 这类真扩展名：
		   `homeproxy-0.2.15` 里的 `.15` 是名字的一部分，不能被当成扩展名切掉。
		   文件名不合规时清空选择框，让用户能马上重选同一个位置的文件。 */
		fileInput.addEventListener('change', () => {
			const picked = fileInput.files && fileInput.files[0];

			if (!picked)
				return;

			const name = picked.name.replace(/\.(conf|uci|bak|txt|cfg|gz|tgz|tar|zip)$/i, '');

			if (!/^homeproxy-[A-Za-z0-9_.-]+$/.test(name) || name === 'homeproxy-back') {
				notify(_('The file name must start with homeproxy- and may only contain letters, digits, dots, underscores and dashes.'), 'danger');
				fileInput.value = '';
				return;
			}

			/* 真实的 UCI 配置是几十 KB。不挡大小的话，误选一个镜像或日志就会
			   被写进 overlay 的 /etc/config，把 flash 塞满。 */
			if (picked.size > 1048576) {
				notify(_('The selected file is larger than 1 MB; check that it is a UCI configuration file.'), 'danger');
				fileInput.value = '';
				return;
			}

			uploadProfile(name);
		});

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

		/* 条件子节点必须用数组 push，不能写 `cond ? null : E(...)`：LuCI 的 E()
		   不会跳过 null，会把它变成一个文本节点，界面上直接显示字面 "null"
		   （0.3.1 现场：「使用中」那一行的删除按钮位置就印着 null）。 */
		const fileRow = (name) => {
			const inUse = (name === current);
			const cells = [
				E('span', { 'style': 'min-width:16em;' }, inUse ? [ name, ' ', _('(in use)') ] : [ name ]),
				E('button', { 'class': 'cbi-button', 'click': () => downloadProfile(name) }, _('Download'))
			];

			/* 正在用的那份不给删：脚本也会拒，界面上直接不给按钮更省事。 */
			if (!inUse)
				cells.push(E('button', { 'class': 'cbi-button cbi-button-remove', 'click': () => confirmDelete(name) }, _('Delete')));

			return E('div', { 'style': 'display:flex;align-items:center;gap:.5em;margin:.25em 0;' }, cells);
		};

		const panel = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Configuration File')),
			E('div', { 'class': 'cbi-map-descr' }, _('Manage HomeProxy configuration files. Ordinary settings still use Save & Apply at the bottom right; switching a profile uses Switch & Apply on this page.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Select configuration file')), E('div', { 'class': 'cbi-value-field' }, [ select, ' ', apply ]) ]),
				/* 这一行只放那句校验说明：当前配置已经从上面的下拉里看得到，
				   再写一遍「当前配置文件：xxx」是重复；用户也明确要求去掉「状态」
				   这个标签，所以标题留空占位，保持与其它行左对齐。 */
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, ''), E('div', { 'class': 'cbi-value-field' }, [ checkBox ]) ]),
				/* 上传只留一个按钮：点它选文件，选完就直接传上去，名字取自文件名。
				   「刷新列表」排在它下面一行。 */
				E('div', { 'class': 'cbi-value' }, [ E('div', { 'class': 'cbi-value-title' }, _('Upload configuration file')),
					E('div', { 'class': 'cbi-value-field' }, [
						fileInput,
						E('div', {}, [ uploadFile ]),
						E('div', { 'style': 'margin-top: .4em;' }, [ refresh ]),
						status
					]) ]),
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
		/* 「上传文件」只是把那个隐藏的文件选择框点开；真正的上传在 change 里。 */
		uploadFile.addEventListener('click', () => fileInput.click());
		refresh.addEventListener('click', () => window.location.reload());
		return panel;
	}
});
