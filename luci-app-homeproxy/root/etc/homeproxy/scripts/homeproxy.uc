/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

import { lstat, mkstemp } from 'fs';
import { urldecode_params } from 'luci.http';

/* Global variables start */
export const HP_DIR = '/etc/homeproxy';
export const RUN_DIR = '/var/run/homeproxy';

/* 单条命令 stdout / stderr 各自的最大采集字节数。
   原实现只 read(1024 * 512)，超过 512 KiB 的部分被静默丢弃：大型订阅
   （几 MB 的 Clash YAML、几千条节点的 base64 列表）会被悄悄截断，表现
   为「订阅导入后少了节点」且日志里毫无提示。这里放宽到 16 MiB，并且
   循环读到 EOF；真的超过上限时 truncated 标记为 true，调用方可以告警。 */
const CMD_OUTPUT_LIMIT = 16 * 1024 * 1024;
const CMD_READ_CHUNK = 64 * 1024;

/* 二进制探测只需要看开头：对 16 MiB 的正文逐字节 ord() 太浪费。 */
const CMD_BINARY_SCAN = 4096;
/* Global variables end */

/* Utilities start */
/* Kanged from luci-app-commands */
export function shellQuote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
};

export function isBinary(str) {
	const limit = (length(str) > CMD_BINARY_SCAN) ? CMD_BINARY_SCAN : length(str);

	for (let off = 0, byte = ord(str); off < limit; byte = ord(str, ++off))
		if (byte <= 8 || (byte >= 14 && byte <= 31))
			return true;

	return false;
};

/* 分块读完整个 fd，最多 limit 字节。
   返回 { data, size, truncated }：truncated 只在「确实还有数据没读完」
   时为 true，正常读完不会误报。 */
function readAll(fd, limit) {
	let chunks = [];
	let total = 0;
	let truncated = false;

	for (;;) {
		const chunk = fd.read(CMD_READ_CHUNK);

		if (chunk === null || length(chunk) === 0)
			break;

		const remain = limit - total;

		if (remain <= 0) {
			truncated = true;
			break;
		}

		if (length(chunk) > remain) {
			push(chunks, substr(chunk, 0, remain));
			total += remain;
			truncated = true;
			break;
		}

		push(chunks, chunk);
		total += length(chunk);
	}

	return { data: join('', chunks), size: total, truncated };
};

/* 执行命令。参数一律按 argv 处理并逐项 shellQuote —— 调用方不可能再
   「忘了加引号」，也就不存在把用户输入拼进命令行的注入面。
   需要复杂 shell 语法时请显式调用 /bin/sh -c <script>。 */
export function executeCommand(...args) {
	const argv = [];

	for (let arg in args)
		push(argv, shellQuote(sprintf('%s', arg)));

	let outfd = mkstemp();
	let errfd = mkstemp();

	const exitcode = system(`${join(' ', argv)} >&${outfd.fileno()} 2>&${errfd.fileno()}`);

	outfd.seek(0);
	errfd.seek(0);

	const stdout = readAll(outfd, CMD_OUTPUT_LIMIT);
	const stderr = readAll(errfd, CMD_OUTPUT_LIMIT);

	outfd.close();
	errfd.close();

	const binary = isBinary(stdout.data);

	return {
		command: join(' ', args),
		stdout: binary ? null : stdout.data,
		stderr: stderr.data,
		exitcode,
		binary,
		truncated: stdout.truncated || stderr.truncated,
		size: stdout.size
	};
};

/* 探测可执行文件是否存在（Makefile 只声明了 curl，但精简镜像里也可能
   只有 wget，反之亦然，所以两个都认）。 */
function findBinary(name) {
	for (let path in [`/usr/bin/${name}`, `/bin/${name}`, `/usr/sbin/${name}`]) {
		try {
			if (lstat(path).type === 'file')
				return path;
		} catch (e) {}
	}

	return null;
};

/* 统一下载器：优先 curl（DEPENDS 保证），缺失时回退 wget。
   返回 null 表示两者都没有——调用方据此给出明确的「缺依赖」提示，
   而不是把命令不存在（127）当成「服务器返回空」。 */
function httpFetcher() {
	const curl = findBinary('curl');

	if (curl)
		return { name: 'curl', path: curl };

	const wget = findBinary('wget');

	if (wget)
		return { name: 'wget', path: wget };

	return null;
};

/* 取回正文 + 响应头。curl 用 -D 把响应头写进 stderr（/proc/self/fd/2
   就是本次调用被重定向的那个 stderr），与 wget -S 的输出通道完全一致，
   上层解析逻辑不必区分下载器。用 /proc 而不是 /dev/stderr：OpenWrt 的
   /dev 由 devtmpfs 生成，不保证有 stderr 这个链接，而 /proc 一定在。 */
function httpFetch(url, ua, timeout) {
	const fetcher = httpFetcher();

	if (!fetcher)
		return null;

	if (fetcher.name === 'curl')
		return executeCommand(fetcher.path, '-fsSL',
			'--user-agent', ua,
			'--connect-timeout', '10',
			'--max-time', sprintf('%d', timeout),
			'-D', '/proc/self/fd/2', url);

	return executeCommand(fetcher.path, '-O-', '-S',
		'--user-agent', ua, sprintf('--timeout=%d', timeout), url);
};

export function getTime(epoch) {
	const local_time = localtime(epoch);
	return replace(replace(sprintf(
		'%d-%2d-%2d@%2d:%2d:%2d',
		local_time.year,
		local_time.mon,
		local_time.mday,
		local_time.hour,
		local_time.min,
		local_time.sec
	), ' ', '0'), '@', ' ');

};

export function wGETResponse(url, ua) {
	if (!url || type(url) !== 'string')
		return null;

	if (!ua)
		ua = 'Wget/1.21 (HomeProxy, like v2rayN)';

	const output = httpFetch(url, ua, 300);

	/* 两个下载器都不存在：返回 exitcode 127 而不是 null，让上层日志能看出
	   是环境缺依赖，而不是订阅服务器返回了空内容。 */
	if (!output)
		return { body: null, headers: '', exitcode: 127, size: 0, truncated: false };

	return {
		body: trim(output.stdout),
		headers: output.stderr || '',
		exitcode: output.exitcode,
		/* size 是 stdout 的真实字节数（截断前）。上层抓不到正文时要靠它
		   区分「服务器真的返回了 0 字节」和「连上了但被 curl -f 吞掉了正文」。 */
		size: output.size,
		truncated: output.truncated
	};
};

export function wGET(url, ua) {
	return wGETResponse(url, ua)?.body;
};

export function wGETHeaders(url, ua) {
	if (!url || type(url) !== 'string')
		return null;

	if (!ua)
		ua = 'clash.meta';

	const fetcher = httpFetcher();

	if (!fetcher)
		return '';

	/* curl 把响应头写到 stdout（-D -），wget 写到 stderr（-S）；
	   两者都只回传「头」，正文丢进 /dev/null。 */
	if (fetcher.name === 'curl') {
		const output = executeCommand(fetcher.path, '-fsSL',
			'--user-agent', ua,
			'--connect-timeout', '10',
			'--max-time', '20',
			'-o', '/dev/null', '-D', '-', url);

		return output.stdout || '';
	}

	const output = executeCommand(fetcher.path, '-O', '/dev/null', '-S',
		'--user-agent', ua, '--timeout=10', url);

	return output.stderr || '';
};
/* Utilities end */

/* String helper start */
export function isEmpty(res) {
	return !res || res === 'nil' || (type(res) in ['array', 'object'] && length(res) === 0);
};

export function strToBool(str) {
	return (str === '1') || null;
};

/* 段「启用」状态的唯一判断口径，供所有生成/探测脚本共用。
 *
 * LuCI 的 form.Flag 在本插件的每个表格里都是「默认勾选」：default = '1'
 * （`so.default = so.enabled`）、rmempty = false（关闭一定会被明确写成
 * '0'）。也就是说，取值缺失只可能意味着这一段从没走过保存流程 —— 旧版本
 * 创建的段、备份还原、手工编辑 /etc/config/homeproxy —— 而界面照样把它
 * 显示成「已启用」。
 *
 * 各处原先一律写 `cfg.enabled === '1'`，于是键一缺失就变成「界面显示启用、
 * 后端当成关闭」：规则集一条都不下载、出站不进生成配置、内核直接「未运行」，
 * 且日志里没有任何异常。统一成「只有明确写 0/false 才算关闭」。 */
export function isSectionEnabled(value) {
	/* 只用 null 判断：ucode 里成员缺失就是 null；真拿到 undefined 时下面
	   的模板串会退化成 "undefined"，同样落在「不是明确关闭」的一侧。 */
	if (value === null || value === '')
		return true;

	const v = `${value}`;

	return !(v in [ '0', 'false', 'no', 'off', 'disabled' ]);
};

export function strToInt(str) {
	return !isEmpty(str) ? (int(str) || null) : null;
};

export function strToTime(str) {
	return !isEmpty(str) ? (str + 's') : null;
};

export function removeBlankAttrs(res) {
	let content;

	if (type(res) === 'object') {
		content = {};
		map(keys(res), (k) => {
			if (type(res[k]) in ['array', 'object'])
				content[k] = removeBlankAttrs(res[k]);
			else if (res[k] !== null && res[k] !== '')
				content[k] = res[k];
		});
	} else if (type(res) === 'array') {
		content = [];
		map(res, (k, i) => {
			if (type(k) in ['array', 'object'])
				push(content, removeBlankAttrs(k));
			else if (k !== null && k !== '')
				push(content, k);
		});
	} else
		return res;

	return content;
};

export function validateHostname(hostname) {
	return (match(hostname, /^[a-zA-Z0-9_]+$/) != null ||
		(match(hostname, /^[a-zA-Z0-9_][a-zA-Z0-9_%-.]*[a-zA-Z0-9]$/) &&
			match(hostname, /[^0-9.]/)));
};

export function validation(datatype, data) {
	if (!datatype || !data)
		return null;

	const ret = system(`/sbin/validate_data ${shellQuote(datatype)} ${shellQuote(data)} 2>/dev/null`);
	return (ret === 0);
};
/* String helper end */

/* String parser start */
export function decodeBase64Str(str) {
	if (isEmpty(str))
		return null;

	str = trim(str);
	str = replace(str, '_', '/');
	str = replace(str, '-', '+');

	const padding = length(str) % 4;
	if (padding)
		str = str + substr('====', padding);

	return b64dec(str);
};

export function parseURL(url) {
	if (type(url) !== 'string')
		return null;

	const services = {
		http: '80',
		https: '443'
	};

	const objurl = {};

	objurl.href = url;

	url = replace(url, /#(.+)$/, (_, val) => {
		objurl.hash = val;
		return '';
	});

	url = replace(url, /^(\w[A-Za-z0-9\+\-\.]+):/, (_, val) => {
		objurl.protocol = val;
		return '';
	});

	url = replace(url, /\?(.+)/, (_, val) => {
		objurl.search = val;
		objurl.searchParams = urldecode_params(val);
		return '';
	});

	url = replace(url, /^\/\/([^\/]+)/, (_, val) => {
		val = replace(val, /^([^@]+)@/, (_, val) => {
			objurl.userinfo = val;
			return '';
		});

		val = replace(val, /:(\d+)$/, (_, val) => {
			objurl.port = val;
			return '';
		});

		if (validation('ip4addr', val) ||
		    validation('ip6addr', replace(val, /\[|\]/g, '')) ||
		    validation('hostname', val))
			objurl.hostname = val;

		return '';
	});

	objurl.pathname = url || '/';

	if (!objurl.protocol || !objurl.hostname)
		return null;

	if (objurl.userinfo) {
		objurl.userinfo = replace(objurl.userinfo, /:(.+)$/, (_, val) => {
			objurl.password = val;
			return '';
		});

		if (match(objurl.userinfo, /^[A-Za-z0-9\+\-\_\.]+$/)) {
			objurl.username = objurl.userinfo;
			delete objurl.userinfo;
		} else {
			delete objurl.userinfo;
			delete objurl.password;
		}
	};

	if (!objurl.port)
		objurl.port = services[objurl.protocol];

	objurl.host = objurl.hostname + (objurl.port ? `:${objurl.port}` : '');
	objurl.origin = `${objurl.protocol}://${objurl.host}`;

	return objurl;
};
/* String parser end */
