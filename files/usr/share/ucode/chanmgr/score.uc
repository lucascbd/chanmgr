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

// Estimated capacity of a channel option, in units of one free 20 MHz
// channel, from the busy fraction of each 20 MHz subchannel (util: freq ->
// 0..1). A transmission uses a width only when every subchannel of that
// block, built around the primary channel, is free; otherwise it falls back
// to the next narrower width (dynamic bandwidth). Assuming subchannels are
// busy independently:
//   capacity = P(20 free) + P(40 free) + 2 * P(80 free) + 4 * P(160 free)
// Returns null when a subchannel has no data.
function capacity(s, util) {
	let total = 0;

	for (let w = 20; w <= s.width; w *= 2) {
		let b = (w == s.width) ? s : chan.spec(s.band, s.channel, w);
		let p = 1.0;

		if (b.width != w)
			return null;

		for (let c in chan.subchannels(b)) {
			let u = util?.['' + chan.chan2freq(s.band, c)];

			if (u == null)
				return null;

			p *= 1 - u;
		}

		total += (w == 20) ? p : p * w / 40.0;
	}

	return total;
}

// Prior busy fraction of one 20 MHz channel, from the neighbors heard on it
// (signal-weighted, see weight()). Used until enough measurements exist.
function busy_prior(band, ch, neighbors, opts) {
	let s20 = chan.spec(band, ch, 20), w = 0;

	for (let n in neighbors)
		w += chan.overlap(s20, n.spec) * weight(n.signal, opts.ref_rssi);

	return w / (w + (opts.prior_scale ?? 10.0));
}

// Busy fraction per frequency: the measured mean, blended with the prior by
// sample count, so a few days of data outweigh what the neighbors suggest.
//   measured: { freq: { mean, n } }
function busy_estimate(band, channels, neighbors, measured, opts) {
	let res = {}, k = opts.prior_weight ?? 2.0;

	for (let ch in channels) {
		let f = '' + chan.chan2freq(band, ch);
		let p = busy_prior(band, ch, neighbors, opts), m = measured?.[f];

		res[f] = m ? (m.n * m.mean + k * p) / (m.n + k) : p;
	}

	return res;
}

// Own access points that hear each other share airtime where their channels
// overlap: a strong link (>= -60 dBm) halves the overlapping part.
function share_factor(a, b, signal) {
	let strength = min(1, max(0, (signal + 85) / 25.0));

	return 1 - 0.5 * chan.overlap(a, b) * strength;
}

// Joint search maximizing estimated capacity (channel and width together).
//   units:  [ { id, radios, current, candidates } ]   candidates of any width
//   radios: { rid: { busy: { freq: fraction } } }
//   pairs:  [ { a, b, signal } ]
function plan_capacity(units, radios, pairs, opts) {
	let unit_of = {}, cands = [];

	for (let i, u in units) {
		let list = u.locked ? [ u.current ] : u.candidates;

		if (u.current && !length(filter(list, (s) => chan.same(s, u.current))))
			list = [ ...list, u.current ];

		cands[i] = list;

		for (let rid in u.radios)
			unit_of[rid] = i;
	}

	let pp = filter(pairs ?? [], (p) => unit_of[p.a] != null && unit_of[p.b] != null && unit_of[p.a] != unit_of[p.b]);
	let raw = (rid, s) => capacity(s, radios[rid].busy) ?? 0;

	let radio_value = (rid, idx) => {
		let s = cands[unit_of[rid]][idx[unit_of[rid]]], v = raw(rid, s);

		for (let p in pp) {
			let other = (p.a == rid) ? p.b : (p.b == rid) ? p.a : null;

			if (other != null)
				v *= share_factor(s, cands[unit_of[other]][idx[unit_of[other]]], p.signal);
		}

		return v;
	};

	let total = (idx) => {
		let v = 0;

		for (let rid, i in unit_of)
			v += radio_value(rid, idx);

		return v;
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
			let v = total(idx);

			if (v > best + 1e-9) {
				best = v;
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
		for (let round = 0, improved = true; improved && round < 20; round++) {
			improved = false;

			for (let i = 0; i < length(cands); i++) {
				for (let j = 0; j < length(cands[i]); j++) {
					let idx = [ ...best_idx ];

					idx[i] = j;

					let v = total(idx);

					if (v > best + 1e-9) {
						best = v;
						best_idx = idx;
						improved = true;
					}
				}
			}
		}
	}

	// per radio: every option of its unit, the other units at their best
	let table = {};

	for (let i, u in units) {
		for (let rid in u.radios) {
			table[rid] = map(cands[i], (s, j) => {
				let idx = [ ...best_idx ];

				idx[i] = j;

				let pf = cands[i][0] ? radio_value(rid, idx) : 0;
				let f = '' + s.freq;

				return {
					channel: s.channel, width: s.width,
					capacity: pf, raw: raw(rid, s),
					busy: radios[rid].busy[f],
					current: j == cur_idx[i], best: j == best_idx[i]
				};
			});

			table[rid] = sort(table[rid], (a, b) => b.capacity - a.capacity);
		}
	}

	let bestmap = {};

	for (let i, u in units)
		bestmap[u.id] = cands[i][best_idx[i]];

	return {
		metric: 'capacity',
		best: bestmap,
		best_value: best,
		current_value: total(cur_idx),
		table, combos, exhaustive
	};
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
// A width change asks for more: data for the full history window
// (p.ready[unit] from the caller), a larger gain and more confirmations.
function decide(units, p, prev, last_switch, opts, now) {
	let key = plan_key(units, p.best);
	let capm = (p.metric == 'capacity');
	let gain = capm ? p.best_value - p.current_value : p.current_cost - p.best_cost;
	let base = capm ? p.current_value : p.current_cost;
	let rel = (base > 0) ? 1.0 * gain / base : 0;
	let res = { key, gain, rel, streak: 0 };
	let min_abs = capm ? (opts.min_capacity_gain ?? 0.2) : (opts.min_gain_abs ?? 0.5);
	let widen = filter(units, (u) => p.best[u.id] && u.current && p.best[u.id].width != u.current.width);
	let min_rel = length(widen) ? max(opts.min_gain_rel ?? 25, opts.width_min_gain ?? 30) : (opts.min_gain_rel ?? 25);
	let need = length(widen) ? max(opts.confirm ?? 2, opts.width_confirm ?? 3) : (opts.confirm ?? 2);

	if (key == '')
		return { ...res, action: 'keep', reason: 'current channels are already the best' };

	if (gain < min_abs || rel * 100 < min_rel)
		return { ...res, action: 'keep', reason: sprintf('gain too small (%.2f, %.0f%%)', gain, rel * 100) };

	res.streak = (prev?.key == key) ? (prev.streak ?? 0) + 1 : 1;

	for (let u in widen)
		if (!p.ready?.[u.id])
			return { ...res, action: 'wait', reason: sprintf('width change waits for %d days of measurements', opts.history_days ?? 3) };

	if (res.streak < need)
		return { ...res, action: 'wait', reason: sprintf('plan seen %d/%d times', res.streak, need) };

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

return { weight, util_of, radio_cost, own_penalty, plan, plan_key, decide, capacity, busy_prior, busy_estimate, share_factor, plan_capacity };
