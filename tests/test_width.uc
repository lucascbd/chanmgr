'use strict';

let chan = require('chanmgr.chan');
let score = require('chanmgr.score');
let uci = require('uci');
let agent = require('chanmgr.agent');   // stub
let ctl = require('chanmgr.controller');

function util(map_ch) {
	let u = {};

	for (let ch, v in map_ch)
		u['' + chan.chan2freq('5g', +ch)] = v;

	return u;
}

return function(t) {
	let free = util({ '149': 0, '153': 0, '157': 0, '161': 0 });

	t.near(score.capacity(chan.spec('5g', 149, 20), free), 1, 'capacity: free 20 MHz = 1');
	t.near(score.capacity(chan.spec('5g', 149, 40), free), 2, 'capacity: free 40 MHz = 2');
	t.near(score.capacity(chan.spec('5g', 149, 80), free), 4, 'capacity: free 80 MHz = 4');

	let half = util({ '149': 0.5, '153': 0.5, '157': 0.5, '161': 0.5 });
	t.near(score.capacity(chan.spec('5g', 149, 80), half), 0.5 + 0.25 + 2 * 0.0625, 'capacity: half busy 80 MHz');

	// 80 MHz only pays off when the extra 40 MHz is free
	let busy2nd = util({ '149': 0.1, '153': 0.1, '157': 1, '161': 1 });
	t.near(score.capacity(chan.spec('5g', 149, 80), busy2nd), score.capacity(chan.spec('5g', 149, 40), busy2nd), 'capacity: busy secondary 40 adds nothing');

	// a busy primary hurts more than a busy secondary
	let p_busy = util({ '149': 0.6, '153': 0 }), s_busy = util({ '149': 0, '153': 0.6 });
	t.ok(score.capacity(chan.spec('5g', 149, 40), p_busy) < score.capacity(chan.spec('5g', 149, 40), s_busy), 'capacity: primary weighs more');

	t.eq(score.capacity(chan.spec('5g', 149, 80), util({ '149': 0 })), null, 'capacity: missing data -> null');

	// history: cumulative counters give per-evaluation deltas, resets are taken as is
	let st = { chanstats: {} }, now = 1000000;

	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 100, busy: 50, tx: 0 } ], 3, now);
	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 300, busy: 70, tx: 0 } ], 3, now + 3600);
	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 100, busy: 90, tx: 10 } ], 3, now + 7200);
	t.eq(map(st.chanstats['a/r1']['5745'].samples, (x) => x[1]), [ 0.5, 0.1, 0.8 ], 'history: deltas, reset, own tx excluded');

	let sum = ctl.chanstats_summary(st.chanstats['a/r1'], 3, now + 7200);
	t.near(sum.util['5745'], (0.5 + 0.1 + 0.8) / 3.0, 'history: mean');
	t.eq([ sum.count['5745'], sum.first['5745'] ], [ 3, now ], 'history: count and oldest');

	ctl.record_chanstats(st, 'a/r1', [], 3, now + 5 * 86400);
	t.eq(length(st.chanstats['a/r1']['5745'].samples), 0, 'history: old samples dropped');

	// model pieces
	let nb = [ { signal: -60, spec: chan.spec('5g', 36, 20) } ];
	let prior = score.busy_prior('5g', 36, nb, { ref_rssi: -70 });
	t.near(prior, 10.0 / 20, 'prior: one -60 dBm neighbor -> 50% busy');
	t.near(score.busy_prior('5g', 149, nb, { ref_rssi: -70 }), 0, 'prior: nobody on 149');

	let est = score.busy_estimate('5g', [ 36 ], nb, { '5180': { mean: 0.1, n: 6 } }, { ref_rssi: -70 });
	t.near(est['5180'], (6 * 0.1 + 2 * 0.5) / 8.0, 'estimate: measurements outweigh the prior');
	est = score.busy_estimate('5g', [ 36 ], nb, {}, { ref_rssi: -70 });
	t.near(est['5180'], 0.5, 'estimate: prior without data');

	t.near(score.share_factor(chan.spec('5g', 36, 40), chan.spec('5g', 36, 40), -50), 0.5, 'share: same channel, strong link -> half');
	t.near(score.share_factor(chan.spec('5g', 36, 40), chan.spec('5g', 149, 40), -50), 1, 'share: no overlap');
	t.near(score.share_factor(chan.spec('5g', 36, 40), chan.spec('5g', 36, 40), -90), 1, 'share: not heard');

	// joint channel + width search
	let busy = util({ '36': 0.6, '40': 0.6, '44': 0.6, '48': 0.6, '149': 0.05, '153': 0.05, '157': 0.05, '161': 0.05 });
	let opts = [ chan.spec('5g', 36, 40), chan.spec('5g', 44, 40), chan.spec('5g', 149, 40), chan.spec('5g', 157, 40),
		chan.spec('5g', 36, 80), chan.spec('5g', 149, 80) ];
	let units = [ { id: 'g', radios: [ 'a', 'b' ], current: chan.spec('5g', 36, 40), candidates: opts } ];
	let p = score.plan_capacity(units, { a: { busy }, b: { busy } }, [], {});
	t.eq(chan.key(p.best.g), '149/80', 'capacity plan: free block at 80 MHz wins');
	t.ok(p.best_value > p.current_value * 3, 'capacity plan: values');
	t.eq(p.table.a[0].best, true, 'capacity plan: table sorted, best first');

	// a busy secondary 40: 80 MHz adds nothing, 40 MHz is kept (ties keep the narrower)
	let busy2 = util({ '149': 0.05, '153': 0.05, '157': 1, '161': 1, '36': 0.6, '40': 0.6, '44': 0.6, '48': 0.6 });
	p = score.plan_capacity([ { id: 'r', radios: [ 'a' ], current: chan.spec('5g', 149, 40), candidates: opts } ], { a: { busy: busy2 } }, [], {});
	t.eq(chan.key(p.best.r), '149/40', 'capacity plan: busy secondary -> stays 40 MHz');

	// two own APs that hear each other well are kept apart
	let flat = util({ '36': 0.1, '40': 0.1, '44': 0.1, '48': 0.1, '149': 0.1, '153': 0.1, '157': 0.1, '161': 0.1 });
	let two = [ { id: 'a', radios: [ 'a' ], current: chan.spec('5g', 36, 40), candidates: opts },
		{ id: 'b', radios: [ 'b' ], current: chan.spec('5g', 36, 40), candidates: opts } ];
	p = score.plan_capacity(two, { a: { busy: flat }, b: { busy: flat } }, [ { a: 'a', b: 'b', signal: -45 } ], {});
	t.eq(chan.overlap(p.best.a, p.best.b), 0, 'capacity plan: own APs on separate blocks');

	// width change rules
	let u1 = [ { id: 'g', radios: [ 'a' ], current: chan.spec('5g', 36, 40) } ];
	let pw = { metric: 'capacity', best: { g: chan.spec('5g', 149, 80) }, best_value: 4, current_value: 1, ready: { g: false } };
	let dd = score.decide(u1, pw, { key: 'g=149/80', streak: 5 }, {}, { history_days: 3 }, 0);
	t.eq(dd.action, 'wait', 'decide: width change waits for data');
	t.ok(index(dd.reason, '3 days') > 0, 'decide: says why');
	pw.ready = { g: true };
	t.eq(score.decide(u1, pw, { key: 'g=149/80', streak: 1 }, {}, {}, 0).action, 'wait', 'decide: width change needs 3 confirmations');
	t.eq(score.decide(u1, pw, { key: 'g=149/80', streak: 2 }, {}, {}, 0).action, 'switch', 'decide: third confirmation switches');
	let pc = { metric: 'capacity', best: { g: chan.spec('5g', 149, 40) }, best_value: 1.3, current_value: 1.0 };
	t.eq(score.decide(u1, pc, { key: 'g=149/40', streak: 1 }, {}, {}, 0).action, 'switch', 'decide: channel only, normal rules (+30%, 2x)');
	pc.best_value = 1.1;
	t.eq(score.decide(u1, pc, null, {}, {}, 0).action, 'keep', 'decide: small capacity gain kept');

	// end to end with width analysis on: one plan, channel and width together
	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', mode: 'recommend', scan_gap: '0', apply_gap: '0', history_days: '3', width_analysis: '1' },
		local: { '.type': 'node' }
	};
	require('fs').unlink(getenv('CHANMGR_RUN_DIR') + '/state.json');

	agent.dev.radios.radio1.channel = 36;
	agent.dev.radios.radio1.width = 40;
	agent.dev.radios.radio1.htmode = 'HE40';
	agent.dev.neighbors.radio1 = [];
	agent.dev.survey = { radio1: map([ 36, 40, 44, 48, 149, 153, 157, 161 ], (c) => ({
		freq: chan.chan2freq('5g', c), active: 100, busy: (c >= 149) ? 5 : 60, tx: 0
	})) };

	let calls = length(agent.calls);
	ctl.evaluate({ apply: false });

	let s = ctl.status();
	let plan = s.plans['5g'];

	t.eq(plan.metric, 'capacity', 'unified: 5 GHz planned by capacity');
	t.eq([ plan.units[0].best.channel, plan.units[0].best.width ], [ 149, 80 ], 'unified: channel and width together');
	t.eq(plan.action, 'wait', 'unified: width change waits');
	t.ok(index(plan.reason, 'days of measurements') > 0, 'unified: waiting for data');
	t.eq(s.plans['2g'].metric, 'cost', 'unified: 2.4 GHz unchanged');

	let o = s.radios['local/radio1'].options;
	t.ok(length(o) >= 4 && o[0].capacity >= o[1].capacity, 'unified: options ranked by capacity');
	t.ok(o[0].samples >= 1 && o[0].days != null, 'unified: data behind each option');
	t.eq(s.radios['local/radio1'].costs, null, 'unified: no separate cost table');
	t.eq(length(filter(slice(agent.calls, calls), (c) => index(c, 'switch') == 0)), 0, 'unified: nothing switched');

	// with enough history it is recommended after the confirmations
	uci.data.chanmgr.main.history_days = '0';
	ctl.evaluate({ apply: false });
	ctl.evaluate({ apply: false });
	t.eq(ctl.status().plans['5g'].action, 'recommend', 'unified: recommended once data and confirmations are there');

	// width analysis off: back to the interference cost, current width only
	delete uci.data.chanmgr.main.width_analysis;
	ctl.evaluate({ apply: false });
	s = ctl.status();
	t.eq([ s.plans['5g'].metric, s.plans['5g'].units[0].best.width ], [ 'cost', 40 ], 'width analysis off: cost model, width kept');
	t.eq(length(keys(json(require('fs').readfile(getenv('CHANMGR_RUN_DIR') + '/state.json')).chanstats)), 0, 'width analysis off: history cleared');

	agent.dev.survey = null;
	agent.dev.radios.radio1.width = 80;
	agent.dev.radios.radio1.htmode = 'HE80';
};
