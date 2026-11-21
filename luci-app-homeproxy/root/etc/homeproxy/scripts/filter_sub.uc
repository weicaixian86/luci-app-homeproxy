#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * 方案 B helper：把订阅正文（base64 链接列表）解码 → 逐条按「导入同一套」
 * 关键词过滤节点名（URL 解码后匹配，中文关键词必须 urldecode 才能对上）
 * → 重新 base64 编码输出。
 *
 * 用法：ucode -S filter_sub.uc <body_file> <mode> <keywords_file>
 *   body_file      : curl 拉到的订阅正文（单行 base64 或明文链接列表）
 *   mode           : blacklist / whitelist / disabled
 *   keywords_file  : 每行一个关键词（来自 UCI subscription.filter_keywords，
 *                    条目本身可能是 官网|剩余|… 的管道串，shell 侧已拆行）
 * stdout: 过滤后的 base64 单行（无 userinfo 头；由 shell 侧拼回）
 *
 * 必须从此脚本所在目录运行（ucode 靠 cwd 解析 `import 'homeproxy'`），
 * shell 调用方会 cd 到 scripts 目录。
 */

'use strict';

import { readfile } from 'fs';
import { urldecode } from 'luci.http';
import { decodeBase64Str } from 'homeproxy';

const body_file = ARGV[0],
      mode = ARGV[1] || 'blacklist',
      kw_file = ARGV[2];

if (!body_file || !kw_file)
	exit(2);

let body = readfile(body_file);
if (!body)
	exit(3);

/* 解码：先试 base64（订阅一般是 base64 链接列表），失败则当明文 */
let text = null;
try {
	text = decodeBase64Str(body);
} catch (e) {
	text = null;
}
/* base64 解出来不像链接列表（没有 ://）→ 退回明文正文 */
if (!text || index(text, '://') < 0)
	text = body;

/* 关键词：按行读，管道串也拆成多个 */
let keywords = [];
const kw_raw = readfile(kw_file) || '';
for (let line in split(replace(kw_raw, /\r/g, ''), '\n')) {
	line = trim(line);
	if (!line)
		continue;
	for (let k in split(line, '|')) {
		k = trim(k);
		if (k)
			push(keywords, k);
	}
}

/* 逐行过滤：节点名有三个来源，必须全部参与匹配，否则会漏过滤——
   ① URL 的 #fragment（vless/trojan/ss/hysteria2/anytls 等）；
   ② vmess:// 的**内部 base64-JSON 的 ps 字段**：vmess 分享链接把节点名
      编码在链接体内（没有 #），机场的「❗如果只显示此节点|0.1x」等提示
      节点就是这么藏的。只解 # 会全部漏掉（237 实测 4 个漏网节点）；
   ③ 原始行本身（兜底，覆盖未编码的明文名）。 */
let kept = [];
for (let raw in split(replace(text, /\r/g, ''), '\n')) {
	raw = trim(raw);
	if (!raw) {
		push(kept, raw);
		continue;
	}

	/* 收集所有候选名称片段 */
	let names = [ raw ];

	/* ① #fragment */
	const hash_i = index(raw, '#');
	if (hash_i >= 0)
		push(names, urldecode(substr(raw, hash_i + 1)));

	/* ② vmess:// 内部 base64-JSON 的 ps / remarks / name */
	if (index(raw, 'vmess://') === 0) {
		let inner = null;
		try { inner = decodeBase64Str(substr(raw, 8)); } catch (e) { inner = null; }
		if (inner) {
			let j = null;
			try { j = json(inner); } catch (e) { j = null; }
			if (j) {
				if (j.ps) push(names, j.ps);
				if (j.remarks) push(names, j.remarks);
				if (j.name) push(names, j.name);
			} else {
				/* 不是 JSON 也把解出来的明文纳入匹配 */
				push(names, inner);
			}
		}
	}

	let hit = false;
	for (let kw in keywords) {
		for (let nm in names) {
			if (index(nm, kw) >= 0) {
				hit = true;
				break;
			}
		}
		if (hit)
			break;
	}

	if (mode === 'whitelist') {
		if (hit)
			push(kept, raw);
	} else if (mode === 'blacklist') {
		if (!hit)
			push(kept, raw);
	} else {
		push(kept, raw);
	}
}

/* 重新编码为单行 base64 */
const out = join('\n', kept);
print(b64enc(out));
