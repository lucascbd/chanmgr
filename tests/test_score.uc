'use strict';

let chan = require('chanmgr.chan');
let score = require('chanmgr.score');

const OPTS = { ref_rssi: -70, util_weight: 2, own_weight: 2, min_gain_abs: 0.5, min_gain_rel: 25, confirm: 2, min_switch_interval: 86400 };

function nb(band, ch, width, signal) {
	return { signal, spec: chan.spec(band, ch, width) };
}

let C5 = [ chan.spec('5g', 36, 80), chan.spec('5g', 149, 80) ];
let C2 = [ chan.spec('2g', 1, 20), chan.spec('2g', 6, 20), chan.spec('2g', 11, 20) ];

return function(t) {
	t.near(score.weight(-70, -70), 1, 'weight at ref');
	t.near(score.weight(-60, -70), 10, 'weight +10 dB');
	t.near(score.weight(-80, -70), 0.1, 'weight -10 dB');
	t.near(score.weight(-65, -70), 10 ** 0.5, 'weight +5 dB (no integer division)');

	let radio = { neighbors: [ nb('5g', 44, 20, -60) ], util: { '5745': 0.5 } };

	t.near(score.radio_cost(C5[0], radio, OPTS).cost, 10, 'cost: neighbor inside block');
	t.near(score.radio_cost(C5[1], radio, OPTS).cost, 2 * 0.5 / 4.0, 'cost: util averaged over subchannels');

	// single radio leaves a congested block
	let units = [ { id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5 } ];
	let p = score.plan(units, { 'a/r1': radio }, [], OPTS);

	t.eq(chan.key(p.best['a/r1']), '149/80', 'plan: moves away from neighbor');
	t.near(p.current_cost, 10, 'plan: current cost');
	t.eq(p.table['a/r1'][0].channel, 149, 'plan: table sorted by cost');
	t.ok(p.table['a/r1'][1].current, 'plan: table marks current');

	// two own APs on the same channel hearing each other at -50 dBm
	let quiet = { neighbors: [], util: {} };
	let two = [
		{ id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5 },
		{ id: 'b/r1', radios: [ 'b/r1' ], current: C5[0], candidates: C5 }
	];
	let pairs = [ { a: 'a/r1', b: 'b/r1', signal: -50 } ];

	p = score.plan(two, { 'a/r1': quiet, 'b/r1': quiet }, pairs, OPTS);
	t.near(p.current_cost, 200, 'own APs: penalty 2 x 100');
	t.near(p.best_cost, 0, 'own APs: separated');
	t.ok(!chan.same(p.best['a/r1'], p.best['b/r1']), 'own APs: different channels');

	// same, but tied to one mesh group: they must stay together
	let grp = [ { id: 'group:mesh', radios: [ 'a/r1', 'b/r1' ], current: C5[0], candidates: C5 } ];
	let rr = { 'a/r1': { neighbors: [ nb('5g', 36, 80, -65) ], util: {} }, 'b/r1': quiet };

	p = score.plan(grp, rr, pairs, OPTS);
	t.eq(chan.key(p.best['group:mesh']), '149/80', 'group: moves together');
	t.near(p.current_cost, 10 ** 0.5, 'group: no self penalty inside group');

	// locked unit keeps its channel but still repels others
	let lk = [
		{ id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5, locked: 'mesh' },
		{ id: 'b/r1', radios: [ 'b/r1' ], current: C5[0], candidates: C5 }
	];

	p = score.plan(lk, { 'a/r1': { neighbors: [ nb('5g', 36, 80, -50) ], util: {} }, 'b/r1': quiet }, pairs, OPTS);
	t.eq([ chan.key(p.best['a/r1']), chan.key(p.best['b/r1']) ], [ '36/80', '149/80' ], 'locked: only the free unit moves');

	// three own APs in 2.4 GHz spread over 1/6/11
	let three = map([ 'a', 'b', 'c' ], (n) => ({ id: n + '/r0', radios: [ n + '/r0' ], current: C2[0], candidates: C2 }));
	let p3 = [ { a: 'a/r0', b: 'b/r0', signal: -55 }, { a: 'b/r0', b: 'c/r0', signal: -55 }, { a: 'a/r0', b: 'c/r0', signal: -60 } ];
	let q3 = { 'a/r0': quiet, 'b/r0': quiet, 'c/r0': quiet };

	p = score.plan(three, q3, p3, OPTS);
	t.eq(sort(map(three, (u) => p.best[u.id].channel)), [ 1, 6, 11 ], '2g: 1/6/11 spread');
	t.ok(p.exhaustive, '2g: exhaustive search');
	t.eq(p.combos, 27, '2g: 27 combinations');

	let pd = score.plan(three, q3, p3, { ...OPTS, max_combos: 2 });
	t.ok(!pd.exhaustive, 'descent: used when too many combos');
	t.near(pd.best_cost, p.best_cost, 'descent: reaches same optimum here');

	// current channel outside candidates (e.g. DFS) stays an option
	let dfs = [ { id: 'a/r1', radios: [ 'a/r1' ], current: chan.spec('5g', 52, 80), candidates: C5 } ];

	p = score.plan(dfs, { 'a/r1': quiet }, [], OPTS);
	t.eq(chan.key(p.best['a/r1']), '52/80', 'dfs current kept when equal');

	// hysteresis
	let now = 1000000;

	p = score.plan(units, { 'a/r1': radio }, [], OPTS);

	let d = score.decide(units, p, null, {}, OPTS, now);
	t.eq([ d.action, d.streak, d.key ], [ 'wait', 1, 'a/r1=149/80' ], 'decide: first sighting waits');

	d = score.decide(units, p, d, {}, OPTS, now);
	t.eq([ d.action, d.streak ], [ 'switch', 2 ], 'decide: confirmed plan switches');

	t.eq(score.decide(units, p, d, { 'a/r1': now - 3600 }, OPTS, now).action, 'hold', 'decide: min interval');
	t.eq(score.decide(units, p, d, { 'a/r1': now - 90000 }, OPTS, now).action, 'switch', 'decide: interval passed');
	t.eq(score.decide(units, p, { key: 'other', streak: 5 }, {}, OPTS, now).streak, 1, 'decide: different plan resets streak');

	let small = { ...p, current_cost: 1.0, best_cost: 0.6 };
	t.eq(score.decide(units, small, null, {}, OPTS, now).action, 'keep', 'decide: abs gain too small');

	let rel = { ...p, current_cost: 10, best_cost: 8 };
	t.eq(score.decide(units, rel, null, {}, OPTS, now).action, 'keep', 'decide: rel gain too small');

	let none = { ...p, best: { 'a/r1': C5[0] } };
	t.eq(score.decide(units, none, null, {}, OPTS, now).action, 'keep', 'decide: nothing to change');
};
