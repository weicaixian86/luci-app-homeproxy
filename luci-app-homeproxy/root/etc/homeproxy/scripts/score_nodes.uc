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
/* ⚠ 本文件的自定义 log(msg) 是写日志函数，会覆盖内置/数学的 log——
   对数曲线必须用别名导入，否则 log(1+k·nd) 会把数值当消息打出
   并返回 undefined（分数 NaN，现场教训）。 */
import { log as math_log } from 'math';
import { cursor } from 'uci';
import { sqrt } from 'math';
import { isEmpty, shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const STATE_FILE = HP_DIR + '/score_state.json';
const LOCK_DIR = RUN_DIR + '/score_nodes.lock';
const LOG_FILE = RUN_DIR + '/homeproxy.log';
const HALF_LIFE = 30 * 60;
const DELAY_FRESH = 10 * 60;
const PROBE_TIMEOUT_MS = 4000;

/* ===== 第一档（借鉴 mihomo Smart Group）：多维评分 + 防抖 + 退化检测 ===== */
const TOLERANCE = 0.10;          // 评分容差：最优分要优于现任 10% 才切换
/* 权重（分数越低越好）：延迟仍是最强区分项；抖动衡量稳定性；
   速度维度因 reF1nd 内核 /connections 无连接追踪数据（实测恒为空）
   改由抖动承担“稳定性”目标——完全基于既有延迟样本，零额外探测。 */
const W_DELAY = 0.30;
/* Paily 对数延迟曲线系数：低延迟区（<500ms）的微小差距不再线性放大，
   高延迟区（>1500ms）惩罚放缓——延迟维度整体更平滑。 */
const LATENCY_CURVE_K = 0.3;
const W_LOSS = 0.30;
const W_JITTER = 0.40;
const JITTER_MIN_SAMPLES = 3;    // 抖动样本不足不计惩罚（中性）
const HIST_MAX = 10;             // 每成员保留最近 10 次成功延迟
const DEGRADE_PENALTY = 0.5;     // 退化节点额外惩罚分
const BASE_ALPHA = 0.20;         // EMA 基线系数（新样本权重 20%）
const BASE_MIN_SAMPLES = 3;      // 建立基线的最少成功样本
const SPIKE_FACTOR = 3.0;        // 延迟 > 基线×3 视为 spike，不更新基线
const BASE_MAX_STEP_UP = 1.25;   // 基线单次最多上涨 25%
const DEGRADE_FACTOR = 1.5;      // 延迟 > 基线×1.5 标记退化
const RECOVER_FACTOR = 1.2;      // 延迟 ≤ 基线×1.2 才可清除退化
const RECOVER_SUCCESSES = 2;     // 连续成功次数清除退化
const LOSS_MIN_SAMPLES = 3;      // 失败率样本不足不惩罚
/* 与 urltest 同口径：google.com/generate_204（别用 gstatic —— 它在 china_list 里，
   且实测有节点通 gstatic 却连不上 google.com，会选出口径上"最优"实则不通的节点，
   237 现场：台湾高速01 gstatic 158ms 最优，google.com 却 000。 */
const PROBE_URL_ENC = 'https%3A%2F%2Fwww.google.com%2Fgenerate_204';

function log(msg) {
	system(sprintf('printf "%%s %%s\n" "$(date +%%Y-%%m-%%dT%%H:%%M:%%S)" %s >> %s 2>/dev/null',
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

function probe_member(tag) {
	const enc = uri_escape(tag);
	const resp = api_get(sprintf('/proxies/%s/delay?timeout=%d&url=%s',
		enc, PROBE_TIMEOUT_MS, PROBE_URL_ENC));
	if (isEmpty(resp))
		return null;
	const d = json(resp);
	return (type(d) === 'object' && d.delay != null) ? d.delay : null;
}

/* 更新单个成员的 EMA 延迟基线 + 退化标记（借鉴 mihomo Smart）：
   · 成功：样本<BASE_MIN_SAMPLES 用算术平均 bootstrap，之后用 EMA（新 20%）；
     延迟 > 基线×SPIKE_FACTOR 视为 spike 不更新；单次上涨限 BASE_MAX_STEP_UP。
   · 失败：立即标记退化。
   · 恢复：延迟 ≤ 基线×RECOVER_FACTOR 且连续 RECOVER_SUCCESSES 次成功才清除（滞后防抖）。 */
function update_baseline(st, success, delay) {
	if (success && delay != null) {
		const base = st.base ?? null;
		if (base == null || st.base_n == null || st.base_n < BASE_MIN_SAMPLES) {
			/* bootstrap：累加平均 */
			const prev_sum = (st.base_sum ?? 0) + delay;
			st.base_sum = prev_sum;
			st.base_n = (st.base_n ?? 0) + 1;
			st.base = prev_sum / (st.base_n * 1.0);
		} else if (delay > base * SPIKE_FACTOR) {
			/* spike：不更新基线（异常值忽略） */
		} else {
			let nb = base * (1 - BASE_ALPHA) + delay * BASE_ALPHA;
			/* 单次最多上涨 BASE_MAX_STEP_UP 倍 */
			if (nb > base * BASE_MAX_STEP_UP)
				nb = base * BASE_MAX_STEP_UP;
			st.base = nb;
		}

		/* 退化恢复：延迟回到基线附近且连续成功 N 次 */
		const nb = st.base ?? null;
		if (st.deg) {
			if (nb != null && delay <= nb * RECOVER_FACTOR) {
				st.deg_ok = (st.deg_ok ?? 0) + 1;
				if (st.deg_ok >= RECOVER_SUCCESSES) {
					st.deg = 0;
					st.deg_ok = 0;
				}
			} else {
				st.deg_ok = 0;
			}
		}
	} else {
		/* 失败：标记退化 */
		st.deg = 1;
		st.deg_ok = 0;
	}
}

/* 计算单个成员的评分（分数越低越好，与 mihomo Smart 同构）：
   score = delay/2000(归一上限1) + W_LOSS*失败率 + (退化?DEGRADE_PENALTY:0) */
function compute_score(st) {
	if (!st || !st.ok || st.delay == null)
		return 999;      /* 无样本/失败：极高，仅当全部如此才用 */
	let nd = st.delay / 2000.0;   /* /2000 会被 ucode 当整数除法截断成 0，必须用浮点 */
	if (nd > 1) nd = 1;
	/* Paily 对数延迟曲线：delay_term = ln(1+k·nd)/ln(1+k)。150ms→0.085、
	   500ms→0.285、1000ms→0.533、2000ms→1.0——与线性接近但高延迟区
	   增长放缓，低延迟节点之间的差距不再主导评分。 */
	nd = math_log(1 + LATENCY_CURVE_K * nd) / math_log(1 + LATENCY_CURVE_K);
	let loss = 0;
	const total = (st.ok_cnt ?? 0) + (st.fail_cnt ?? 0);
	if (total >= LOSS_MIN_SAMPLES)
		loss = (st.fail_cnt ?? 0) / (total * 1.0);
	let sc = W_DELAY * nd + W_LOSS * loss;

	/* 抖动维度：最近 N 次成功延迟的极差 / 基线（归一上限 1）。
	   稳定节点极差约为基线的 10~20%（惩罚 0.03~0.06）；
   忽高忽低的节点极差接近基线甚至更高（惩罚逼近 0.30）。 */
	if (type(st.hist) === 'array' && length(st.hist) >= JITTER_MIN_SAMPLES) {
		let mx = st.hist[0], mn = st.hist[0];
		for (let v in st.hist) {
			if (v > mx) mx = v;
			if (v < mn) mn = v;
		}
		const jb = st.base ?? ((mx + mn) / 2.0);
		if (jb > 0) {
			let jn = (mx - mn) / (jb * 1.0);
			if (jn > 1) jn = 1;
			sc += W_JITTER * jn;
		}
	}

	if (st.deg)
		sc += DEGRADE_PENALTY;
	return sc;
}

/* 识别综合评分组：uci 里 node=='score' 的 routing_node 段（生成器把它们
   生成为 type=Selector、tag=组显示名）。返回 [tag, ...]（已确认在
   Clash API 里存在且类型为 Selector 的）。 */
/* 递归展开成员（对齐 mihomo Smart 的 resolve 语义）：score 组引用其它
   score 组时，展开到叶子节点——评叶子、选叶子，外层 now 直接指向全池
   综合最优的真实节点。叶子延迟数据节点级共享（state.members 按节点名
   存），子组评分器的实测外层直接复用，几乎不增加探测量。
   urltest/selector 子组不展开：内核 urltest 自选、用户手选的内层自治
   不应被外层绕过。depth 限 4 防配置成环。 */
function expand_score_members(tags, proxies, score_tags, depth) {
	let out = [];
	for (let t in tags) {
		const sub = proxies[t];
		if (depth < 4 && sub != null && type(sub.all) === 'array' &&
		    length(sub.all) > 0 && ~index(score_tags, t)) {
			for (let x in expand_score_members(sub.all, proxies, score_tags, depth + 1))
				if (!~index(out, x))
					push(out, x);
		} else if (!~index(out, t)) {
			push(out, t);
		}
	}
	return out;
}

function find_score_groups(proxies) {
	const uci = cursor();
	uci.load('homeproxy');
	let groups = [];
	uci.foreach('homeproxy', 'routing_node', (cfg) => {
		if (cfg.node !== 'score' || cfg.enabled === '0' || isEmpty(cfg.label))
			return;
		const p = proxies.proxies?.[cfg.label];
		if (type(p) === 'object' && p.type === 'Selector')
			push(groups, cfg.label);
	});
	return groups;
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

	const score_groups = find_score_groups(proxies);

	for (let tag in score_groups) {
		const score_proxy = proxies.proxies[tag];
		if (type(score_proxy) !== 'object' || isEmpty(score_proxy.all))
			continue;

		const members = expand_score_members(score_proxy.all, proxies.proxies, score_groups, 0);
		const n = length(members);
		const budget = (n <= 4) ? (n + 1) : (int(sqrt(n)) + 1);
		let probe_count = 0;

		const incumbent = score_proxy.now ?? '';
		const incumbent_st = state.members?.[incumbent] ?? null;
		const incumbent_fresh = incumbent_st && incumbent_st.ok && (now_ts - incumbent_st.ts) < DELAY_FRESH;

		/* 探测名单（有界）：现任样本过期优先补测，其次未测成员，最后按
		   样本时间【最旧优先】轮询补足预算——保证基线与抖动历史（hist）
		   在全体成员上逐步积累，而不是只有现任/新成员有样本。 */
		let probe_list = [];
		if (incumbent && !incumbent_fresh)
			push(probe_list, incumbent);
		for (let m in members)
			if (state.members?.[m] == null && !~index(probe_list, m))
				push(probe_list, m);
		let olds = [];
		for (let m in members) {
			if (~index(probe_list, m))
				continue;
			const st = state.members?.[m];
			/* ok=false 的成员也要参与“最老优先”轮询——否则探测失败的节点
			   永远没有重测机会（评分池持续缩水，组会退化成“无可用样本”）。 */
			if (st && (st.ok || (st.fail_cnt ?? 0) > 0))
				push(olds, { m: m, ts: st.ts ?? 0 });
		}
		sort(olds, (a, b) => (a.ts - b.ts));
		for (let o in olds) {
			if (length(probe_list) >= budget)
				break;
			push(probe_list, o.m);
		}
		if (length(probe_list) > budget)
			probe_list = slice(probe_list, 0, budget);

		let best_tag = '', best_score = 9999;
		for (let m in members) {
			let st = state.members?.[m] ?? null;
			/* 需要探测时更新样本与基线 */
			if (!(st && st.ok && (now_ts - st.ts) < DELAY_FRESH) &&
			    (~index(probe_list, m) && probe_count < budget)) {
				probe_count++;
				const delay = probe_member(m);
				const success = (delay != null);
				if (!st) st = { ok_cnt: 0, fail_cnt: 0 };
				st.delay = delay;
				st.ok = success;
				st.ts = now_ts;
				if (success) {
					st.ok_cnt = (st.ok_cnt ?? 0) + 1;
					/* 记录最近 HIST_MAX 次成功延迟，供抖动维度使用。
					   ⚠ ucode 的 push(arr, x) 返回的是新长度（int），不是数组——
					   不能写 st.hist = push(...)，必须语句式调用原地修改。 */
					if (type(st.hist) !== 'array')
						st.hist = [];
					push(st.hist, delay);
					if (length(st.hist) > HIST_MAX)
						st.hist = slice(st.hist, length(st.hist) - HIST_MAX);
				}
				else st.fail_cnt = (st.fail_cnt ?? 0) + 1;
				update_baseline(st, success, delay);
				state.members[m] = st;
			}
			if (!st || !st.ok || st.delay == null)
				continue;
			const sc = compute_score(st);
			/* 持久化算法分（分越低越好），供状态页统一显示：
			   质量分 = 100 - min(100, 分×50)，越高越好。 */
			st.score = sc;
			if (sc < best_score) {
				best_score = sc;
				best_tag = m;
			}
		}

		for (let k in (state.members ?? {}))
			if (now_ts - (state.members[k].ts ?? 0) > 2 * HALF_LIFE)
				delete state.members[k];

		if (!best_tag) {
			log(sprintf('组「%s」无可用成员样本，维持现状。', tag));
			continue;
		}

		/* 现任评分（用于容差防抖） */
		const inc_st = state.members?.[incumbent] ?? null;
		const incumbent_score = (inc_st && inc_st.ok) ? compute_score(inc_st) : 9999;

		if (best_tag === incumbent) {
			log(sprintf('[keep] %s: incumbent %s score=%.2f', tag, incumbent, best_score));
		} else if (incumbent_score < 9999 && best_score >= incumbent_score * (1 - TOLERANCE)) {
			log(sprintf('[hold] %s: challenger %s score=%.2f vs incumbent %s score=%.2f (within tolerance %.0f%%)',
				tag, best_tag, best_score, incumbent, incumbent_score, TOLERANCE * 100));
		} else {
			const rc = api_put(sprintf('/proxies/%s', uri_escape(tag)), { name: best_tag });
			log(sprintf('[switch] %s: %s -> %s score=%.2f incumbent_score=%.2f rc=%d',
				tag, incumbent, best_tag, best_score, incumbent_score, rc));
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
