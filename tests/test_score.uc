'use strict';

let chan = require('chanmgr.chan');
let score = require('chanmgr.score');

const OPTS = { ref_rssi: -70, min_gain_rel: 25, confirm: 2, min_switch_interval: 86400, history_days: 3 };

function nb(band, ch, width, signal) {
	return { signal, spec: chan.spec(band, ch, width) };
}

// busy estimate of a radio from the neighbors it hears (no measurements yet)
function prior(band, channels, neighbors) {
	return { busy: score.busy_estimate(band, channels, neighbors, {}, OPTS) };
}

let C5 = [ chan.spec('5g', 36, 80), chan.spec('5g', 149, 80) ];
let CH5 = [ 36, 40, 44, 48, 149, 153, 157, 161 ];
let C2 = [ chan.spec('2g', 1, 20), chan.spec('2g', 6, 20), chan.spec('2g', 11, 20) ];

return function(t) {
	t.near(score.weight(-70, -70), 1, 'weight at ref');
	t.near(score.weight(-60, -70), 10, 'weight +10 dB');
	t.near(score.weight(-80, -70), 0.1, 'weight -10 dB');
	t.near(score.weight(-65, -70), 10 ** 0.5, 'weight +5 dB (no integer division)');

	// a single radio leaves the block of a loud neighbor
	let loud = prior('5g', CH5, [ nb('5g', 44, 20, -55) ]);
	let units = [ { id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5 } ];
	let p = score.plan(units, { 'a/r1': loud }, [], OPTS);

	t.eq(chan.key(p.best['a/r1']), '149/80', 'plan: moves away from neighbor');
	t.ok(p.current_value < p.best_value, 'plan: values');
	t.eq(p.table['a/r1'][0].channel, 149, 'plan: table sorted by capacity');
	t.ok(p.table['a/r1'][1].current, 'plan: table marks current');

	// two own APs on the same channel hearing each other at -50 dBm
	let quiet = prior('5g', CH5, []);
	let two = [
		{ id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5 },
		{ id: 'b/r1', radios: [ 'b/r1' ], current: C5[0], candidates: C5 }
	];
	let pairs = [ { a: 'a/r1', b: 'b/r1', signal: -50 } ];

	p = score.plan(two, { 'a/r1': quiet, 'b/r1': quiet }, pairs, OPTS);
	t.near(p.current_value, 4, 'own APs: sharing one free 80 MHz block halves both');
	t.near(p.best_value, 8, 'own APs: separated, each on a free block');
	t.ok(!chan.same(p.best['a/r1'], p.best['b/r1']), 'own APs: different channels');

	// the same radios in one mesh group stay together and leave the neighbor
	let grp = [ { id: 'group:mesh', radios: [ 'a/r1', 'b/r1' ], current: C5[0], candidates: C5 } ];

	p = score.plan(grp, { 'a/r1': prior('5g', CH5, [ nb('5g', 36, 80, -60) ]), 'b/r1': quiet }, pairs, OPTS);
	t.eq(chan.key(p.best['group:mesh']), '149/80', 'group: moves together');
	t.near(p.best_value, 8, 'group: no sharing penalty inside the group');

	// a locked unit keeps its channel, the other one avoids it
	let lk = [
		{ id: 'a/r1', radios: [ 'a/r1' ], current: C5[0], candidates: C5, locked: 'mesh' },
		{ id: 'b/r1', radios: [ 'b/r1' ], current: C5[0], candidates: C5 }
	];

	p = score.plan(lk, { 'a/r1': prior('5g', CH5, [ nb('5g', 36, 80, -50) ]), 'b/r1': quiet }, pairs, OPTS);
	t.eq([ chan.key(p.best['a/r1']), chan.key(p.best['b/r1']) ], [ '36/80', '149/80' ], 'locked: only the free unit moves');

	// three own APs in 2.4 GHz spread over 1/6/11
	let q2 = prior('2g', [ 1, 6, 11 ], []);
	let three = map([ 'a', 'b', 'c' ], (n) => ({ id: n + '/r0', radios: [ n + '/r0' ], current: C2[0], candidates: C2 }));
	let p3 = [ { a: 'a/r0', b: 'b/r0', signal: -55 }, { a: 'b/r0', b: 'c/r0', signal: -55 }, { a: 'a/r0', b: 'c/r0', signal: -60 } ];
	let q3 = { 'a/r0': q2, 'b/r0': q2, 'c/r0': q2 };

	p = score.plan(three, q3, p3, OPTS);
	t.eq(sort(map(three, (u) => p.best[u.id].channel)), [ 1, 6, 11 ], '2g: 1/6/11 spread');
	t.ok(p.exhaustive, '2g: exhaustive search');
	t.eq(p.combos, 27, '2g: 27 combinations');

	let pd = score.plan(three, q3, p3, { ...OPTS, max_combos: 2 });
	t.ok(!pd.exhaustive, 'descent: used when too many combos');
	t.near(pd.best_value, p.best_value, 'descent: reaches same optimum here');

	// 2.4 GHz: a neighbor on channel 3 also weighs on 1 (overlap)
	let n3 = prior('2g', [ 1, 6, 11 ], [ nb('2g', 3, 20, -50) ]);
	t.ok(n3.busy['2412'] > 0 && n3.busy['2462'] == 0, '2g: overlapping neighbor counted');

	// current channel outside the candidates (e.g. DFS) stays an option
	let dfs = [ { id: 'a/r1', radios: [ 'a/r1' ], current: chan.spec('5g', 52, 80), candidates: C5 } ];
	let busy52 = prior('5g', [ ...CH5, 52, 56, 60, 64 ], []);

	p = score.plan(dfs, { 'a/r1': busy52 }, [], OPTS);
	t.eq(chan.key(p.best['a/r1']), '52/80', 'dfs current kept when equal');

	// hysteresis: every automatic change needs history_days of measurements
	let now = 1000000;

	p = score.plan(units, { 'a/r1': loud }, [], OPTS);

	let d = score.decide(units, { ...p, ready: { 'a/r1': false }, days: { 'a/r1': 1.2 } }, null, {}, OPTS, now);
	t.eq(d.action, 'wait', 'decide: waits for measurements');
	t.eq(d.reason, 'collecting measurements (1.2 of 3 days)', 'decide: says how far');

	p.ready = { 'a/r1': true };
	d = score.decide(units, p, null, {}, OPTS, now);
	t.eq([ d.action, d.streak, d.key ], [ 'wait', 1, 'a/r1=149/80' ], 'decide: first sighting waits');

	d = score.decide(units, p, d, {}, OPTS, now);
	t.eq([ d.action, d.streak ], [ 'switch', 2 ], 'decide: confirmed plan switches');

	t.eq(score.decide(units, p, d, { 'a/r1': now - 3600 }, OPTS, now).action, 'hold', 'decide: min interval');
	t.eq(score.decide(units, p, d, { 'a/r1': now - 90000 }, OPTS, now).action, 'switch', 'decide: interval passed');
	t.eq(score.decide(units, p, { key: 'other', streak: 5 }, {}, OPTS, now).streak, 1, 'decide: different plan resets streak');

	t.eq(score.decide(units, { ...p, current_value: 1.0, best_value: 1.1 }, null, {}, OPTS, now).action, 'keep', 'decide: abs gain too small');
	t.eq(score.decide(units, { ...p, current_value: 10, best_value: 11 }, null, {}, OPTS, now).action, 'keep', 'decide: rel gain too small');
	t.eq(score.decide(units, { ...p, best: { 'a/r1': C5[0] } }, null, {}, OPTS, now).action, 'keep', 'decide: nothing to change');
	t.eq(score.decide(units, { ...p, best: { 'a/r1': C5[0] }, ready: {} }, null, {}, OPTS, now).action, 'keep', 'decide: no data needed to keep');
};
