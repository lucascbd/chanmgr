// SPDX-License-Identifier: GPL-2.0-only
// Cost model, joint plan search and switching hysteresis. No I/O in here.

'use strict';

let chan = require('chanmgr.chan');

// Linear interference weight of a signal: 1.0 at ref_rssi, x10 per +10 dB.
function weight(rssi, ref_rssi) {
	return 10 ** ((rssi - (ref_rssi ?? -70)) / 10.0);
}

// Mean utilization (0..1) over the 20 MHz subchannels of spec.
// util: { "<freq>": fraction }
function util_of(s, util) {
	let subs = chan.subchannels(s), sum = 0;

	for (let c in subs)
		sum += util?.['' + chan.chan2freq(s.band, c)] ?? 0;

	return 1.0 * sum / length(subs);
}

// External cost of running a radio on spec s.
//   radio: { neighbors: [ { spec, signal } ], util: { freq: fraction } }
function radio_cost(s, radio, opts) {
	let ext = 0;

	for (let n in radio.neighbors)
		ext += chan.overlap(s, n.spec) * weight(n.signal, opts.ref_rssi);

	let u = util_of(s, radio.util);

	return { cost: ext + (opts.util_weight ?? 2) * u, ext, util: u };
}

function own_penalty(a, b, signal, opts) {
	return (opts.own_weight ?? 2) * chan.overlap(a, b) * weight(signal, opts.ref_rssi);
}

// Joint search over all units of one band.
//   units:  [ { id, radios: [rid..], current: spec, candidates: [spec..], locked } ]
//   radios: { rid: radio }
//   pairs:  [ { a: rid, b: rid, signal } ]  own APs hearing each other
// Returns { best: { unit_id: spec }, best_cost, current_cost, table, exhaustive }
function plan(units, radios, pairs, opts) {
	let unit_of = {}, cands = [], ext = [];

	for (let i, u in units) {
		let list = u.locked ? [ u.current ] : u.candidates;

		// the current channel is always an option, even if no longer allowed
		if (u.current && !length(filter(list, (s) => chan.same(s, u.current))))
			list = [ ...list, u.current ];

		cands[i] = list;
		ext[i] = map(list, (s) => {
			let sum = 0;

			for (let rid in u.radios)
				sum += radio_cost(s, radios[rid], opts).cost;

			return sum;
		});

		for (let rid in u.radios)
			unit_of[rid] = i;
	}

	let pp = filter(pairs ?? [], (p) => unit_of[p.a] != null && unit_of[p.b] != null && unit_of[p.a] != unit_of[p.b]);

	let total = (idx) => {
		let c = 0;

		for (let i, j in idx)
			c += ext[i][j];

		for (let p in pp)
			c += own_penalty(cands[unit_of[p.a]][idx[unit_of[p.a]]], cands[unit_of[p.b]][idx[unit_of[p.b]]], p.signal, opts);

		return c;
	};

	let cur_idx = map(units, (u, i) => {
		for (let j, s in cands[i])
			if (chan.same(s, u.current))
				return j;

		return 0;
	});

	let combos = 1;

	for (let l in cands)
		combos *= max(1, length(l));

	let best_idx = [ ...cur_idx ], best = total(cur_idx), exhaustive = (combos <= (opts.max_combos ?? 50000));

	if (exhaustive) {
		let idx = map(cands, () => 0);

		while (true) {
			let c = total(idx);

			if (c < best - 1e-9) {
				best = c;
				best_idx = [ ...idx ];
			}

			let k = 0;

			while (k < length(idx) && ++idx[k] >= length(cands[k]))
				idx[k++] = 0;

			if (k >= length(idx))
				break;
		}
	}
	else {
		// coordinate descent from the current assignment
		for (let round = 0, improved = true; improved && round < 20; round++) {
			improved = false;

			for (let i = 0; i < length(cands); i++) {
				for (let j = 0; j < length(cands[i]); j++) {
					let idx = [ ...best_idx ];

					idx[i] = j;

					let c = total(idx);

					if (c < best - 1e-9) {
						best = c;
						best_idx = idx;
						improved = true;
					}
				}
			}
		}
	}

	// per-radio table: cost of each candidate with the other units at their best
	let table = {};

	for (let i, u in units) {
		for (let rid in u.radios) {
			table[rid] = map(cands[i], (s, j) => {
				let rc = radio_cost(s, radios[rid], opts), own = 0;

				for (let p in pp) {
					let other = (p.a == rid) ? p.b : (p.b == rid) ? p.a : null;

					if (other != null)
						own += own_penalty(s, cands[unit_of[other]][best_idx[unit_of[other]]], p.signal, opts);
				}

				return {
					channel: s.channel, width: s.width,
					cost: rc.cost + own, ext: rc.ext, util: rc.util, own,
					current: j == cur_idx[i], best: j == best_idx[i]
				};
			});

			table[rid] = sort(table[rid], (a, b) => a.cost - b.cost);
		}
	}

	let bestmap = {};

	for (let i, u in units)
		bestmap[u.id] = cands[i][best_idx[i]];

	return {
		best: bestmap,
		best_cost: best,
		current_cost: total(cur_idx),
		table,
		combos,
		exhaustive
	};
}

// Signature of the changes a plan proposes, used to confirm it over runs.
function plan_key(units, best) {
	let parts = [];

	for (let u in units)
		if (!chan.same(u.current, best[u.id]))
			push(parts, u.id + '=' + chan.key(best[u.id]));

	return join(',', sort(parts));
}

// Hysteresis.
//   prev: previous decision for this band ({ key, streak }) or null
//   last_switch: { rid: ts }
// Returns { action: keep|wait|hold|switch, reason, key, streak, gain, rel }
function decide(units, p, prev, last_switch, opts, now) {
	let key = plan_key(units, p.best);
	let gain = p.current_cost - p.best_cost;
	let rel = (p.current_cost > 0) ? 1.0 * gain / p.current_cost : 0;
	let res = { key, gain, rel, streak: 0 };

	if (key == '')
		return { ...res, action: 'keep', reason: 'current channels are already the best' };

	if (gain < (opts.min_gain_abs ?? 0.5) || rel * 100 < (opts.min_gain_rel ?? 25))
		return { ...res, action: 'keep', reason: sprintf('gain too small (%.2f, %.0f%%)', gain, rel * 100) };

	res.streak = (prev?.key == key) ? (prev.streak ?? 0) + 1 : 1;

	if (res.streak < (opts.confirm ?? 2))
		return { ...res, action: 'wait', reason: sprintf('plan seen %d/%d times', res.streak, opts.confirm ?? 2) };

	for (let u in units) {
		if (chan.same(u.current, p.best[u.id]))
			continue;

		for (let rid in u.radios) {
			let ts = last_switch?.[rid];

			if (ts && now - ts < (opts.min_switch_interval ?? 86400))
				return { ...res, action: 'hold', reason: sprintf('%s switched %d min ago', rid, (now - ts) / 60) };
		}
	}

	return { ...res, action: 'switch', reason: sprintf('gain %.2f (%.0f%%)', gain, rel * 100) };
}

return { weight, util_of, radio_cost, own_penalty, plan, plan_key, decide };
