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
import { log as math_log, pow as math_pow } from 'math';
import { cursor } from 'uci';
import { sqrt } from 'math';
import { isEmpty, shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const STATE_FILE = HP_DIR + '/score_state.json';
const LOCK_DIR = RUN_DIR + '/score_nodes.lock';
const LOG_FILE = RUN_DIR + '/homeproxy.log';
const HALF_LIFE = 30 * 60;
const DELAY_FRESH = 10 * 60;
const PROBE_TIMEOUT_MS = 4000;
/* quick 快速检测专用超时：2s。quick 语义是「尽快发现当前节点故障」，
   而卡死的坏节点会白占满分超时。238 实测：正常节点真实延迟仅 140~480ms
   （远小于 2s，零误判）；卡住的坏节点 4s 超时白等 4 秒、双确认最坏 9 秒，
   2s 后最坏仅 5 秒（快 44%）。全量评分仍用 4s（给慢节点留余量）。 */
const QUICK_PROBE_TIMEOUT_MS = 2000;

/* ===== 第一档（借鉴 mihomo Smart Group）：多维评分 + 防抖 + 退化检测 ===== */
const TOLERANCE = 0.10;          // 评分容差：最优分要优于现任 10% 才切换
/* 权重（分数越低越好）——按 mihomo Smart Group 官方方案：
   score = 0.3×延迟 + 0.3×丢包 + 0.4×(1-速度) + 退化0.5
   抖动项 W_JITTER=0（mihomo 模型不含独立抖动维度；稳定性由丢包 +
   EMA 基线退化检测覆盖）。速度无数据时中性（不奖不罚）。 */
const W_DELAY = 0.30;
const W_LOSS = 0.30;
const W_JITTER = 0.0;
const W_SPEED = 0.40;
const SPEED_SAMPLE_SECS = 6;            // 轮内两次采样间隔
const SPEED_REF_FLOOR = 512 * 1024;     // 速度参考地板 512KB/s
const SPEED_REF_CEIL = 32 * 1024 * 1024;// 上限 32MB/s
const SPEED_MIN_SAMPLES = 3;            // 组内至少 3 个样本才启用 P90 锚定
/* Paily 对数延迟曲线系数：低延迟区（<500ms）的微小差距不再线性放大，
   高延迟区（>1500ms）惩罚放缓——延迟维度整体更平滑。 */
const LATENCY_CURVE_K = 0.3;
const JITTER_MIN_SAMPLES = 3;    // 抖动样本不足不计惩罚（中性）
const HIST_MAX = 10;             // 每成员保留最近 10 次成功延迟
const DEGRADE_PENALTY = 0.5;     // 退化节点基础惩罚分
const BASE_ALPHA = 0.20;         // EMA 基线系数（新样本权重 20%）
const BASE_MIN_SAMPLES = 3;      // 建立基线的最少成功样本
const SPIKE_FACTOR = 3.0;        // 延迟 > 基线×3 视为 spike，不更新基线
const BASE_MAX_STEP_UP = 1.25;   // 基线单次最多上涨 25%
const DEGRADE_FACTOR = 1.5;      // 延迟 > 基线×1.5 标记退化
const RECOVER_FACTOR = 1.2;      // 延迟 ≤ 基线×1.2 才可清除退化
const RECOVER_SUCCESSES = 2;     // 连续成功次数清除退化
const LOSS_MIN_SAMPLES = 3;      // 失败率样本不足不惩罚

/* ===== 借鉴 mihomo Smart 的增强（2026-11-20）=====
   ③ 指数惩罚：连续失败次数越多，惩罚越大（封顶 DEGRADE_PENALTY_MAX）；
      同时按退化已持续时长做时间衰减，久未复现的旧故障不再重罚。
   ④ 时间衰减：样本越久未验证，权重越低（越不可信），分数向中性回摆。
   ② 分阶段恢复：退化节点按 5/10/15/30 分钟递增间隔再探测，避免永久惩罚。 */
const DEGRADE_INDEX_BASE = 0.5;  // 指数惩罚基数：penalty = base * min(n, cap)
const DEGRADE_MAX_FAILS = 3;     // 指数惩罚计入的失败次数上限（3 → 惩罚 3×base）
const DEGRADE_PENALTY_MAX = 1.5; // 指数惩罚绝对上限（不超过不退化满分区间太多）
const DEGRADE_TIME_DECAY = 15 * 60; // 退化惩罚的时间衰减半衰期（15 分钟减半）
const SAMPLE_DECAY_HALF = 20 * 60;  // ④ 样本新鲜度衰减半衰期（20 分钟权重减半）
/* 分阶段恢复：退化后第 1/2/3/4 次再探测的最小间隔（秒），递增，之后固定 30 分钟 */
const RECOVER_STEPS = [5 * 60, 10 * 60, 15 * 60, 30 * 60];
/* ① 快速检测：当前 now 节点延迟 > 基线×QUICK_FACTOR 或探测失败即判故障，触发全量评分 */
const QUICK_FACTOR = 1.5;
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

/* 被动速度采样（mihomo SpeedObserver 模式，适配本内核）：
   GET /connections 按 chains[0]（leaf outbound，sing-box 已反转链）
   聚合 download 字节。两次采样间隔 SPEED_SAMPLE_SECS 秒，
   delta/间隔 = 该 leaf 的近期吞吐（B/s）。无连接时返回空 map。 */
function sample_conn_bytes() {
	const out = {};
	const raw = api_get('/connections');
	if (isEmpty(raw))
		return out;
	const d = json(raw);
	if (type(d) !== 'object' || type(d.connections) !== 'array')
		return out;
	for (let con in d.connections) {
		if (type(con) !== 'object' || type(con.chains) !== 'array' || length(con.chains) === 0)
			continue;
		const leaf = con.chains[0];
		const dl = con.download ?? 0;
		if (type(leaf) === 'string' && !isEmpty(leaf) && dl > 0)
			out[leaf] = (out[leaf] ?? 0) + dl;
	}
	return out;
}

function sample_speeds() {
	const out = {};
	const t0 = sample_conn_bytes();
	system(sprintf('sleep %d >/dev/null 2>&1', SPEED_SAMPLE_SECS));
	const t1 = sample_conn_bytes();
	for (let leaf in t1) {
		const d = t1[leaf] - (t0[leaf] ?? 0);
		if (d > 0)
			out[leaf] = d / (SPEED_SAMPLE_SECS * 1.0);
	}
	return out;
}

/* P90 速度参考锚定（mihomo）：样本不足用地板值，P90 限幅 [floor, ceiling]。 */
function compute_speed_ref(speeds) {
	let vals = [];
	for (let k in speeds)
		push(vals, speeds[k]);
	if (length(vals) < SPEED_MIN_SAMPLES)
		return SPEED_REF_FLOOR;
	sort(vals, (a, b) => (a - b));
	let ref = vals[int(length(vals) * 0.9)];
	if (ref < SPEED_REF_FLOOR) ref = SPEED_REF_FLOOR;
	if (ref > SPEED_REF_CEIL) ref = SPEED_REF_CEIL;
	return ref;
}

/* 探测一个节点。timeout_ms 可选（默认全量用的 4s）：quick 传 2s，
   见 QUICK_PROBE_TIMEOUT_MS 注释——quick 是「快速发现故障」，卡住的坏节点
   用 4s 超时会白等满分，2s 足够（238 实测正常节点真实延迟仅 140~480ms）。 */
function probe_member(tag, timeout_ms) {
	const enc = uri_escape(tag);
	const resp = api_get(sprintf('/proxies/%s/delay?timeout=%d&url=%s',
		enc, timeout_ms ?? PROBE_TIMEOUT_MS, PROBE_URL_ENC));
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
					st.deg_fail_n = 0;
					st.deg_since = 0;
				}
			} else {
				st.deg_ok = 0;
			}
		}
	} else {
		/* 失败：标记退化，累计失败次数（供指数惩罚），记录退化起点（供时间衰减 +
		   分阶段恢复的递增间隔） */
		if (!st.deg) {
			st.deg = 1;
			st.deg_since = time();
		}
		st.deg_fail_n = (st.deg_fail_n ?? 0) + 1;
		st.deg_ok = 0;
	}
}

/* 计算单个成员的评分（分数越低越好，与 mihomo Smart 同构）：
   score = delay/2000(归一上限1) + W_LOSS*失败率 + (退化?DEGRADE_PENALTY:0) */
function compute_score(st, speed, speed_ref) {
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

	/* 速度项：有本轮实测吞吐才计入，无数据中性（不奖不罚）。
	   norm = min(1, speed/ref)，快节点 norm→1 → 惩罚→0；慢节点惩罚逼近 W_SPEED。 */
	if (speed != null && speed > 0 && speed_ref > 0) {
		let ns = speed / (speed_ref * 1.0);
		if (ns > 1) ns = 1;
		sc += W_SPEED * (1 - ns);
		st.speed = speed;
	}

	/* ③ 指数惩罚 + 时间衰减：失败次数越多罚越重（封顶），但惩罚随退化已持续
	   时长按半衰期衰减（久未复现的旧故障不再重罚）。deg_fail_n 由 update_baseline
	   在失败时累加、成功时清零。 */
	if (st.deg) {
		/* deg_fail_n 缺省（老状态文件）按 1 次算；下限 1、上限 DEGRADE_MAX_FAILS */
		let _fn = (st.deg_fail_n ?? 1);
		if (_fn < 1) _fn = 1;
		const n = min(_fn, DEGRADE_MAX_FAILS);
		let pen = DEGRADE_INDEX_BASE * n;
		if (pen > DEGRADE_PENALTY_MAX)
			pen = DEGRADE_PENALTY_MAX;
		/* 时间衰减：自 deg_since 起每 DEGRADE_TIME_DECAY 秒惩罚减半 */
		let since = (st.deg_since ?? 0);
		if (!since) since = (st.ts ?? 0);
		const age = (since > 0) ? (time() - since) : 0;
		if (age > 0)
			pen = pen * math_pow(0.5, age / DEGRADE_TIME_DECAY);
		sc += pen;
	}

	/* ④ 样本新鲜度衰减：样本越久未验证越不可信 → 分数向中性（0.5）回摆。
	   刚验证的样本权重 1.0，一个 SAMPLE_DECAY_HALF 后半衰。已 ok 的节点
	   st.ts 会在每轮探测刷新；这里只影响“久未探测”的陈旧样本。 */
	const _ts = (st.ts ?? 0);
	if (_ts > 0) {
		const sample_age = (time() - _ts);
		if (sample_age > 0) {
			const w = math_pow(0.5, sample_age / SAMPLE_DECAY_HALF);
			/* 用 (1-w) 把分数往中性 0.5 拉：w=1 不改，w→0 收缩到 0.5 */
			sc = sc * w + 0.5 * (1 - w);
		}
	}

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

	/* 被动速度采样（轮内一次，所有组共享）；无流量时几乎零成本 */
	const speeds = sample_speeds();
	let speed_vals = [];
	for (let k in speeds)
		push(speed_vals, speeds[k]);
	const speed_ref = compute_speed_ref(speeds);
	if (length(speed_vals) > 0)
		log(sprintf('速度采样: %d 个节点有吞吐, P90参考=%d KB/s', length(speed_vals), int(speed_ref / 1024)));

	for (let tag in score_groups) {
		const score_proxy = proxies.proxies[tag];
		if (type(score_proxy) !== 'object' || isEmpty(score_proxy.all))
			continue;

		const members = expand_score_members(score_proxy.all, proxies.proxies, score_groups, 0);
		const n = length(members);
		/* 探测预算：原来 sqrt(n)+1（82 → 10）太小，每轮只测 10 个、其余用
		   十几分钟前的旧样本，导致「98 分现任 vs 99 分挑战者」这种接近的候选
		   分数在轮间反复翻转、now 抖动。实测完整一轮仅 6 秒，扩预算代价很小。
		   现改为 ~2*sqrt(n)+6 且至少 20、至多全量（82 → 22）。 */
		let budget = int(sqrt(n)) * 2 + 6;
		if (budget < 20 && n > 20) budget = 20;
		if (budget > n) budget = n;
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
		/* 优先重探「当前算法分最好」的候选：保证竞争最优的几个（如 98 vs 99
		   分）每轮都是刚测过的，避免用旧样本比较导致排名翻转。取现有 state
		   里 score 有效且最小的前 ceil(budget/2) 个强制纳入。 */
		let cands = [];
		for (let m in members) {
			const st = state.members?.[m];
			if (st && st.ok && st.score != null) {
				/* 退化节点仍受分阶段恢复间隔约束，不在此强制重探 */
				if (st.deg) continue;
				push(cands, { m: m, sc: st.score });
			}
		}
		sort(cands, (a, b) => (a.sc - b.sc));
		const force_n = int((budget + 1) / 2);
		for (let c in cands) {
			if (length(probe_list) >= force_n) break;
			if (!~index(probe_list, c.m)) push(probe_list, c.m);
		}
		for (let m in members)
			if (state.members?.[m] == null && !~index(probe_list, m))
				push(probe_list, m);
		let olds = [];
		for (let m in members) {
			if (~index(probe_list, m))
				continue;
			const st = state.members?.[m];
			/* ② 分阶段自动恢复：退化节点按 5/10/15/30 分钟的递增间隔再探测，
			   刚挂的节点 5 分钟就重试，反复挂的才逐步拉长——避免永久惩罚，也
			   不让坏节点每轮都白占探测预算。deg_retry_n 是退化后已重试的次数。 */
			if (st && st.deg) {
				const step = RECOVER_STEPS[min((st.deg_retry_n ?? 0), length(RECOVER_STEPS) - 1)];
				if ((now_ts - (st.ts ?? 0)) < step)
					continue;
			}
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
				/* ② 退化节点被重探一次就推进阶段（下次按更长间隔再来） */
				if (st.deg)
					st.deg_retry_n = (st.deg_retry_n ?? 0) + 1;
				state.members[m] = st;
			}
			if (!st || !st.ok || st.delay == null)
				continue;
			const sc = compute_score(st, speeds[m] ?? null, speed_ref);
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
		const incumbent_score = (inc_st && inc_st.ok) ? compute_score(inc_st, speeds[incumbent] ?? null, speed_ref) : 9999;

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

/* ① 实时故障切换的快速检测（--quick，由 cron 每 3 分钟调用，开销极小）：
   探每个 score 组「当前选中的 now 节点」，正常则立即退出；一旦发现当前节点
   探测失败（不通）或延迟 > 基线×QUICK_FACTOR（明显劣化），立即触发一次完整
   评分把流量切走——不必等 30 分钟一轮的 cron。

   实现为两阶段（多个组常指向同一节点，如香港高速01 被 3 组共用）：
     阶段0：收集各冷却已过的组的 now，按节点去重；
     阶段1：对去重后的节点各探一次（2s 超时 + 双确认），结果缓存按节点复用；
     阶段2：按组判定，分摊阶段1 的探测结果。
   故障节点卡满超时时，去重把「N 组各探一次」压成「1 次」。
   借鉴 mihomo Smart「握手超历史平均 1.5 倍即怀疑 → 立即切换」。 */
function quick_check() {
	const raw = api_get('/proxies');
	const proxies = isEmpty(raw) ? null : json(raw);
	if (type(proxies) !== 'object' || isEmpty(proxies.proxies))
		return false;
	const score_groups = find_score_groups(proxies);
	const state = load_state();
	const now_ts = time();
	let need_full = false;

	/* 阶段 0：先收集「冷却已过」的组各自的当前节点 now，按节点去重。
	   多个组常指向同一节点（238 实测：香港高速01 被香港/全球/亚洲 3 组共用），
	   每个节点只探一次即可——探测结果被引用的所有组共享。故障节点卡 2s 超时时，
	   这能把「3 组各探一次=6s」压成「1 次=2s」。 */
	let group_now = {};          /* group tag -> now 节点名 */
	let uniq_nodes = [];         /* 去重后的待探节点 */
	for (let tag in score_groups) {
		const sp = proxies.proxies[tag];
		if (type(sp) !== 'object')
			continue;
		const now = sp.now ?? '';
		if (isEmpty(now))
			continue;
		if ((state.quick_cd?.[tag] ?? 0) > now_ts)   /* 冷却中：不探 */
			continue;
		group_now[tag] = now;
		if (!~index(uniq_nodes, now))
			push(uniq_nodes, now);
	}

	/* 阶段 1：对去重后的节点各探一次（QUICK 用 2s 超时）。缓存 delay 供各组分摊。
	   探测失败做二次确认（sleep 1 再探），两次都失败才算该节点故障。 */
	let node_delay = {};         /* node -> delay 或 null(故障) */
	for (let node in uniq_nodes) {
		let delay = probe_member(node, QUICK_PROBE_TIMEOUT_MS);
		if (delay == null) {
			/* 单次失败做二次确认，过滤瞬时抖动。两测皆失败才算真故障。 */
			system('sleep 1');
			delay = probe_member(node, QUICK_PROBE_TIMEOUT_MS);
		}
		node_delay[node] = delay;   /* null 表示确认故障 */
	}

	/* 阶段 2：按组判定。故障 = 探测确认失败(null)，或延迟 > 基线×QUICK_FACTOR。 */
	for (let tag in group_now) {
		const now = group_now[tag];
		const delay = node_delay[now];
		const st = state.members?.[now] ?? null;
		let bad = false;
		if (delay == null) {
			bad = true;                                  /* 双确认后仍失败 */
		} else if (st && st.base != null && delay > st.base * QUICK_FACTOR) {
			bad = true;                                  /* 明显劣化 */
		}
		if (bad) {
			/* ⚠ 关键：把探测结果【写回 state】再触发全量评分。否则全量评分
			   看到 incumbent 的 state 还是「样本新鲜、ok=true」（上次成功的旧
			   值，10 分钟内不重探），会判定 keep 不切 —— quick 每分钟报故障、
			   全量每分钟 keep，永远切不掉（237 现场：香港高速05 delay 端点
			   3/3 超时，但全量 keep 用旧样本 0.03）。写回 ok=false/fail_cnt++
			   后，全量评分就会把它当失败样本（999）并切到真正可用的节点。 */
			const bad_st = state.members?.[now] ?? { ok_cnt: 0, fail_cnt: 0 };
			bad_st.ok = false;
			bad_st.delay = null;
			bad_st.fail_cnt = (bad_st.fail_cnt ?? 0) + 1;
			bad_st.ts = now_ts;
			state.members[now] = bad_st;
			if (type(state.quick_cd) !== 'object')
				state.quick_cd = {};
			state.quick_cd[tag] = now_ts + 300;   /* 5 分钟冷却，防每分钟空转 */
			save_state(state);   /* 落盘，供随后触发的全量评分读取 */
			log(sprintf('[quick] %s 当前节点 %s 异常（delay=%s base=%s），已标记失败并触发即时评分切换',
				tag, now, delay == null ? '失败' : sprintf('%d', delay),
				st && st.base != null ? sprintf('%d', int(st.base)) : '-'));
			need_full = true;
		}
	}
	return need_full;
}

/* 参数解析：--quick 只做快速检测，发现异常才跑完整评分；否则直接完整评分 */
let quick_mode = false;
{
	/* ucode 用全局 ARGV 读命令行参数（ucode -S script.uc --quick） */
	for (let a in ARGV)
		if (a == '--quick')
			quick_mode = true;
}

let result;
if (quick_mode) {
	if (quick_check()) {
		result = run();
		log(sprintf('==== 即时评分（故障触发）完成：变更 %d 项 ====', length(result.summary ?? [])));
	}
	else
		result = { result: true, changes: 0, summary: [] };
}
else {
	result = run();
	log(sprintf('==== 综合评分完成：变更 %d 项 ====', length(result.summary ?? [])));
}
for (let line in result.summary ?? [])
	log(line);

return result;
