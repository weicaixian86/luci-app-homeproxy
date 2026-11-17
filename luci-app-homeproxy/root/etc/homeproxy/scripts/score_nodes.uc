#!/usr/bin/ucode
'use strict';

/* =====================================================================
 * 综合评分器（对齐 honk 的 Score 语义，sing-box 插件层实现）
 *
 * 数据源（按成本分层）：
 *   ① 业务失败观测（零流量）：tail homeproxy.log 的 ERROR 行，
 *      按 `using outbound/<tag>` 归因到节点；罚分封顶（min(次数,3)*200），
 *      因为一次无关 ERROR（目标服务器拒绝）不该否决一个 183ms 的好节点
 *      （237 现场：日本专线01 被 +500 罚成 683，导致 2% 改善也被切换）。
 *   ② 有界验证（预算制）：每轮预算 ceil(sqrt(n))+1 次真实探测，
 *      经 Clash API `GET /proxies/{tag}/delay` 逐节点实测（delay 接口
 *      对 emoji/中文/竖线 tag 需字节级 URI 编码）。
 *
 * 切换规则（对齐 honk）：
 *   · 样本窗口 10 分钟（第一版 2 分钟导致现任样本刚过期就被切，
 *     香港→台湾→日本来回横跳，237 现场实测）；
 *   · 探测名单按优先级：现任（样本过期先补测）→ 未测成员；
 *     ——按遍历顺序顺测会让每轮测不同的成员、现任永远过期；
 *   · 挑战者需比现任 **>10% 改善** 才切换（在位保护）；
 *   · 现任无有效样本（上一轮探测失败）→ 直接切最优可用；
 *   · 无样本成员本轮不参评（不猜）；
 *   · 状态持久化 /etc/homeproxy/score_state.json，>60 分钟条目清理。
 *
 * 触发：rpcd `score_group_update`（异步脱管）或手动；mkdir 锁互斥，
 *       锁陈旧判定用 mtime（ucode 无 getpid）。
 * ===================================================================== */

import { readfile, writefile, access, popen, stat } from 'fs';
import { cursor } from 'uci';
import { sqrt } from 'math';
import { isEmpty, shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const STATE_FILE = HP_DIR + '/score_state.json';
const LOCK_DIR = RUN_DIR + '/score_nodes.lock';
const LOG_FILE = RUN_DIR + '/homeproxy.log';
const SCORE_SUFFIX = '(综合评分)';
const HALF_LIFE = 30 * 60;
const DELAY_FRESH = 10 * 60;
const SWITCH_RATIO = 0.9;
const FAIL_PENALTY_MS = 100000;
const PROBE_TIMEOUT_MS = 4000;
const PROBE_URL_ENC = 'https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204';

function log(msg) {
	system(sprintf('printf "%%s %%s\n" "$(date +%%Y-%%m-%%d\ %%H:%%M:%%S)" %s >> %s 2>/dev/null',
		shellQuote('[SCORE] ' + msg), shellQuote(LOG_FILE)));
}

function lock_acquire() {
	if (access(LOCK_DIR)) {
		const st = stat(LOCK_DIR);
		if (st && (time() - st.mtime) < 600) {
			log('已有评分任务在跑（锁 mtime 在 10 分钟内），本轮跳过。');
			return false;
		}
		log('发现陈旧评分锁（mtime 超过 10 分钟），清理。');
		system('rm -rf ' + shellQuote(LOCK_DIR));
	}
	system('mkdir -p ' + shellQuote(LOCK_DIR));
	return true;
}

function lock_release() {
	system('rm -rf ' + shellQuote(LOCK_DIR));
}

function api_secret() {
	const uci = cursor();
	return trim(uci.get('homeproxy', 'clash_api', 'secret') || '');
}

function api_get(path) {
	const sec = api_secret();
	const fd = popen(sprintf('curl -s -m 8 -H %s %s 2>/dev/null',
		shellQuote('Authorization: Bearer ' + sec),
		shellQuote('http://127.0.0.1:9095' + path)));
	if (!fd)
		return '';
	let out = '';
	for (let line = fd.read('line'); length(line); line = fd.read('line'))
		out = out + line;
	fd.close();
	return out;
}

function api_put(path, body) {
	const sec = api_secret();
	const tmp = RUN_DIR + '/score_put.json';
	writefile(tmp, sprintf('%J\n', body));
	const rc = system(sprintf('curl -s -o /dev/null -m 8 -X PUT -H %s -H %s --data-binary @%s %s',
		shellQuote('Authorization: Bearer ' + sec),
		shellQuote('Content-Type: application/json'),
		shellQuote(tmp),
		shellQuote('http://127.0.0.1:9095' + path)));
	system('rm -f ' + shellQuote(tmp));
	return rc;
}

function uri_escape(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		const b = ord(s, i);
		const c = substr(s, i, 1);
		if ((b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) ||
		    c == '-' || c == '_' || c == '.' || c == '~')
			out = out + c;
		else
			out = out + sprintf('%%%02X', b);
	}
	return out;
}

function load_state() {
	const raw = trim(readfile(STATE_FILE) || '');
	if (isEmpty(raw))
		return { members: {}, updated: 0 };
	const d = json(raw);
	return (type(d) === 'object') ? d : { members: {}, updated: 0 };
}

function save_state(st) {
	writefile(STATE_FILE, sprintf('%.J\n', st));
}

function collect_business_failures() {
	/* 按行计数即可：tail 窗口（800 行）本身就是“近期”的近似，不解析时间戳
	   （ucode 没有 mktime）。时间衰减交给 30 分钟半衰期的样本清理处理。 */
	const fails = {};
	const fd = popen(sprintf('tail -n 800 %s 2>/dev/null | grep "ERROR" | grep "using outbound/"', shellQuote(LOG_FILE)));
	if (!fd)
		return fails;
	for (let line = fd.read('line'); length(line); line = fd.read('line')) {
		const m = match(line, /using outbound\/[a-z0-9]+\[(.*)\]:/);
		if (!m)
			continue;
		fails[m[1]] = (fails[m[1]] ?? 0) + 1;
	}
	fd.close();
	return fails;
}

function probe_member(tag) {
	const enc = uri_escape(tag);
	const resp = api_get(sprintf('/proxies/%s/delay?timeout=%d&url=%s',
		enc, PROBE_TIMEOUT_MS, PROBE_URL_ENC));
	if (isEmpty(resp))
		return null;
	const d = json(resp);
	return (type(d) === 'object' && d.delay != null) ? d.delay : null;
}

function run() {
	if (!lock_acquire())
		return { result: false, error: 'already_running' };

	const now_ts = time();
	const state = load_state();
	let summary = [];

	const raw = api_get('/proxies');
	const proxies = isEmpty(raw) ? null : json(raw);
	if (type(proxies) !== 'object' || isEmpty(proxies.proxies)) {
		lock_release();
		return { result: false, error: 'clash_api_unreachable' };
	}

	const biz_fails = collect_business_failures();

	for (let tag in proxies.proxies) {
		if (length(tag) <= length(SCORE_SUFFIX) ||
		    substr(tag, length(tag) - length(SCORE_SUFFIX)) !== SCORE_SUFFIX ||
		    proxies.proxies[tag]?.type !== 'Selector')
			continue;

		const urltest_tag = substr(tag, 0, length(tag) - length(SCORE_SUFFIX));
		const urltest = proxies.proxies[urltest_tag];
		if (type(urltest) !== 'object' || isEmpty(urltest.all))
			continue;

		const members = urltest.all;
		const n = length(members);
		const budget = (n <= 4) ? (n + 1) : (int(sqrt(n)) + 1);
		let probe_count = 0;

		const score_proxy = proxies.proxies[tag];
		const incumbent = score_proxy.now ?? '';
		const incumbent_st = state.members?.[incumbent] ?? null;
		const incumbent_fresh = incumbent_st && incumbent_st.ok && (now_ts - incumbent_st.ts) < DELAY_FRESH;

		/* 探测名单（有界）：现任样本过期优先补测，其次未测成员。 */
		let probe_list = [];
		if (incumbent && !incumbent_fresh)
			push(probe_list, incumbent);
		for (let m in members)
			if (state.members?.[m] == null && !~index(probe_list, m))
				push(probe_list, m);
		if (length(probe_list) > budget)
			probe_list = slice(probe_list, 0, budget);

		let best_tag = '', best_eff = -1;
		for (let m in members) {
			const st = state.members?.[m] ?? null;
			let delay = null;
			if (st && st.ok && (now_ts - st.ts) < DELAY_FRESH)
				delay = st.delay;
			else if (~index(probe_list, m) && probe_count < budget) {
				probe_count++;
				delay = probe_member(m);
				state.members[m] = { delay: delay, ok: (delay != null), ts: now_ts };
			} else if (st && st.ok)
				delay = st.delay;
			if (delay == null)
				continue;
			const biz = (biz_fails[m] ?? 0);
			const eff = delay + (biz > 3 ? 3 : biz) * 200;
			if (best_eff < 0 || eff < best_eff) {
				best_eff = eff;
				best_tag = m;
			}
		}

		for (let k in (state.members ?? {}))
			if (now_ts - state.members[k].ts > 2 * HALF_LIFE)
				delete state.members[k];

		if (!best_tag) {
			log(sprintf('组「%s」无可用成员样本，维持现状。', tag));
			continue;
		}
		const ibiz = (biz_fails[incumbent] ?? 0);
		const incumbent_eff = (incumbent_st && incumbent_st.ok)
			? (incumbent_st.delay + (ibiz > 3 ? 3 : ibiz) * 200)
			: -1;

		if (best_tag === incumbent) {
			log(sprintf('[keep] %s: incumbent %s best=%d', tag, incumbent, best_eff));
		} else if (incumbent_eff > 0 && best_eff > incumbent_eff * SWITCH_RATIO) {
			log(sprintf('[hold] %s: challenger %s best=%d vs incumbent eff=%d (10%% rule)', tag, best_tag, best_eff, incumbent_eff));
		} else {
			const rc = api_put(sprintf('/proxies/%s', uri_escape(tag)), { name: best_tag });
			log(sprintf('[switch] %s: %s -> %s best=%d incumbent=%d rc=%d', tag, incumbent, best_tag, best_eff, incumbent_eff, rc));
			push(summary, sprintf('%s: %s -> %s', tag, incumbent, best_tag));
		}
	}

	state.updated = now_ts;
	save_state(state);
	lock_release();

	return { result: true, changes: length(summary), summary: summary };
}

const result = run();
log(sprintf('==== 综合评分完成：变更 %d 项 ====', length(result.summary ?? [])));
for (let line in result.summary ?? [])
	log(line);

return result;
