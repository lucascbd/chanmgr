// SPDX-License-Identifier: GPL-2.0-only
// Controller: collects measurements from all nodes, plans channels jointly
// per band and applies the plan one radio at a time.

'use strict';

let fs = require('fs');
let uci = require('uci');
let chan = require('chanmgr.chan');
let score = require('chanmgr.score');
let agent = require('chanmgr.agent');
let remote = require('chanmgr.remote');

const RUN_DIR = getenv('CHANMGR_RUN_DIR') ?? '/tmp/chanmgr';
const STATE_FILE = RUN_DIR + '/state.json';
const LOCK_DIR = RUN_DIR + '/lock';
const HISTORY_MAX = 50;

function log(prio, fmt, ...args) {
	let msg = sprintf(fmt, ...args);

	system([ 'logger', '-t', 'chanmgr', '-p', 'daemon.' + prio, msg ]);

	if (getenv('CHANMGR_VERBOSE'))
		warn(msg, '\n');
}

function list(v) {
	if (v == null)
		return [];

	return (type(v) == 'array') ? v : split(trim(v), /[ \t,]+/);
}

function config() {
	let c = uci.cursor();
	let m = c.get_all('chanmgr', 'main') ?? {};
	let n = (v, d) => (v != null && v != '') ? +v : d;

	let cfg = {
		enabled: m.enabled == '1',
		mode: (m.mode == 'apply') ? 'apply' : 'recommend',
		eval_times: list(m.eval_times ?? '02:30 04:30'),
		sample_interval: n(m.sample_interval, 300),
		scan_gap: n(m.scan_gap, 120),
		apply_gap: n(m.apply_gap, 30),
		min_gain_rel: n(m.min_gain_rel, 25),
		min_gain_abs: n(m.min_gain_abs, 0.5),
		confirm: n(m.confirm, 2),
		min_switch_interval: n(m.min_switch_interval, 86400),
		allow_dfs: m.allow_dfs == '1',
		util_weight: n(m.util_weight, 2),
		own_weight: n(m.own_weight, 2),
		ref_rssi: n(m.ref_rssi, -70),
		bcn_count: n(m.bcn_count, 10),
		reload_fallback: m.reload_fallback == '1',
		channels_2g: map(list(m.channels_2g ?? '1 6 11'), (x) => +x),
		max_combos: n(m.max_combos, 50000),
		nodes: [],
		groups: []
	};

	c.foreach('chanmgr', 'node', (s) => {
		if (s.enabled == '0')
			return;

		push(cfg.nodes, {
			name: s['.name'],
			type: s.host ? 'remote' : 'local',
			host: s.host,
			port: s.port,
			https: s.https == '1',
			insecure: s.insecure == '1',
			username: s.username,
			password: s.password,
			timeout: n(s.timeout, 30),
			exclude: list(s.exclude),
			lock: list(s.lock)
		});
	});

	c.foreach('chanmgr', 'group', (s) => {
		push(cfg.groups, { name: s['.name'], members: list(s.member) });
	});

	return cfg;
}

/* --- state & locking ---------------------------------------------------- */

function load_state() {
	let s;

	try {
		s = json(fs.readfile(STATE_FILE) ?? '{}');
	}
	catch (e) {
		s = {};
	}

	s.nodes ??= {};
	s.radios ??= {};
	s.plans ??= {};
	s.util ??= {};
	s.last_switch ??= {};
	s.history ??= [];

	return s;
}

function save_state(s) {
	fs.mkdir(RUN_DIR, 0700);
	s.updated = time();
	fs.writefile(STATE_FILE + '.tmp', sprintf('%J', s));
	fs.rename(STATE_FILE + '.tmp', STATE_FILE);
}

function lock(what) {
	fs.mkdir(RUN_DIR, 0700);

	for (let attempt = 0; attempt < 2; attempt++) {
		if (fs.mkdir(LOCK_DIR)) {
			fs.writefile(LOCK_DIR + '/owner', sprintf('%s %s', fs.readlink('/proc/self'), what));

			return true;
		}

		let pid = split(fs.readfile(LOCK_DIR + '/owner') ?? '', ' ')[0];

		// stale lock of a process that died
		if (!pid || !fs.stat('/proc/' + pid)) {
			fs.unlink(LOCK_DIR + '/owner');
			fs.rmdir(LOCK_DIR);
		}
		else
			return false;
	}

	return false;
}

function unlock() {
	fs.unlink(LOCK_DIR + '/owner');
	fs.rmdir(LOCK_DIR);
}

function running() {
	let owner = fs.readfile(LOCK_DIR + '/owner');

	if (!owner)
		return null;

	let parts = split(trim(owner), ' ');

	return fs.stat('/proc/' + parts[0]) ? parts[1] : null;
}

function add_history(st, entry) {
	unshift(st.history, { ts: time(), ...entry });

	if (length(st.history) > HISTORY_MAX)
		st.history = slice(st.history, 0, HISTORY_MAX);
}

/* --- nodes -------------------------------------------------------------- */

function handle(node) {
	if (node.type == 'local') {
		let fns = {
			info: () => agent.info(),
			survey: () => agent.survey(),
			scan: (a) => agent.scan(a.radio),
			switch: (a) => agent.switch_channel(a),
			confirm: (a) => agent.confirm(a)
		};

		return {
			call: (method, args) => {
				try {
					let d = fns[method](args ?? {});

					return d?.error ? { error: d.error } : { data: d };
				}
				catch (e) {
					return { error: e.message };
				}
			}
		};
	}

	let cl = remote.client(node);

	return {
		call: (method, args, timeout) => {
			let r = cl.call('chanmgr', 'agent_' + method, args, timeout);

			return r.data?.error ? { error: r.data.error } : r;
		}
	};
}

function discover(cfg, st) {
	let res = {};

	for (let node in cfg.nodes) {
		node.h ??= handle(node);

		let r = node.h.call('info');

		res[node.name] = r;
		st.nodes[node.name] = r.error
			? { ok: false, error: r.error, ts: time() }
			: { ok: true, ts: time(), hostname: r.data.hostname, radios: r.data.radios };

		if (r.error)
			log('warn', 'node %s: %s', node.name, r.error);
	}

	// forget nodes removed from the config
	for (let name in keys(st.nodes))
		if (!length(filter(cfg.nodes, (n) => n.name == name)))
			delete st.nodes[name];

	return res;
}

/* --- sampling ----------------------------------------------------------- */

function sample_into(st, cfg) {
	for (let node in cfg.nodes) {
		node.h ??= handle(node);

		let r = node.h.call('survey');

		if (r.error)
			continue;

		for (let radio, d in r.data.radios) {
			let rid = node.name + '/' + radio;
			let e = filter(d.survey, (x) => x.in_use)[0] ?? filter(d.survey, (x) => x.freq == d.freq)[0];

			if (!e || e.active == null || e.busy == null)
				continue;

			let u = st.util[rid];

			if (!u || u.freq != e.freq)
				u = st.util[rid] = { freq: e.freq, acc_active: 0, acc_busy: 0, last: null, since: time() };

			let busy = e.busy - (e.tx ?? 0);

			if (u.last) {
				let da = e.active - u.last.active, db = busy - u.last.busy;

				// counters reset (interface restart) produce negative deltas
				if (da > 0 && db >= 0 && db <= da) {
					u.acc_active += da;
					u.acc_busy += db;
				}
			}

			u.last = { active: e.active, busy };
			u.value = (u.acc_active > 0) ? 1.0 * u.acc_busy / u.acc_active : null;
		}
	}

	st.last_sample = time();
}

function sample() {
	if (!lock('sample'))
		return { error: 'busy' };

	let st = load_state();

	sample_into(st, config());
	save_state(st);
	unlock();

	return { ok: true };
}

/* --- evaluation --------------------------------------------------------- */

// Secondary BSSIDs of a device usually differ from the primary MAC only in
// the first (locally administered bit) and last octet. Only used to tell
// which node a BSSID belongs to, never which radio.
function mac_core(mac) {
	return substr(mac, 3, 11);
}

function util_map(survey) {
	let res = {};

	for (let e in survey ?? [])
		if (e.active > 0 && e.busy != null)
			res['' + e.freq] = min(1, 1.0 * max(0, e.busy - (e.tx ?? 0)) / e.active);

	return res;
}

// Build radios, units and pairs per band from discovery + scan results.
function build_model(cfg, st, scans) {
	let radios = {}, own = {}, own_core = {};

	for (let node in cfg.nodes) {
		for (let radio, r in st.nodes[node.name]?.radios ?? {}) {
			let rid = node.name + '/' + radio;

			for (let b in r.bssids) {
				own[b] = node.name;
				own_core[mac_core(b)] = node.name;
			}

			if (r.band != '2g' && r.band != '5g')
				continue;

			if (index(node.exclude, radio) >= 0)
				continue;

			let width = (r.band == '2g') ? 20 : chan.htmode_width(r.htmode);

			radios[rid] = {
				rid, node: node.name, radio, band: r.band, htmode: r.htmode,
				current: chan.spec(r.band, r.channel, (r.band == '2g') ? 20 : r.width, (r.band == '2g') ? null : r.center),
				candidates: chan.candidates(r.band, width, chan.allowed_map(r.channels, r.band), cfg, r.channel),
				has_mesh: r.has_mesh,
				locked: (index(node.lock, radio) >= 0) ? 'locked in configuration' : null,
				neighbors: [],
				util: {},
				scanned: false
			};
		}
	}

	let heard = {};

	for (let rid, sc in scans) {
		let r = radios[rid];

		if (!r)
			continue;

		r.scanned = true;
		r.util = util_map(sc.survey);

		let acc = st.util[rid];

		if (acc?.value != null && acc.freq == r.current.freq)
			r.util['' + acc.freq] = acc.value;

		for (let b in sc.neighbors) {
			if (chan.freq2band(b.freq) != r.band)
				continue;

			let on = own[b.bssid] ?? own_core[mac_core(b.bssid)];

			if (on == r.node)
				continue;

			if (on) {
				// the radio of that node in the same band
				let o = filter(keys(radios), (k) => radios[k].node == on && radios[k].band == r.band)[0];

				if (!o)
					continue;

				let k = join('|', sort([ rid, o ]));

				heard[k] = max(heard[k] ?? -200, b.signal);
				continue;
			}

			push(r.neighbors, { bssid: b.bssid, ssid: b.ssid, signal: b.signal, spec: chan.neighbor_spec(b) });
		}
	}

	let pairs = [];

	for (let k, sig in heard) {
		let ab = split(k, '|');

		push(pairs, { a: ab[0], b: ab[1], signal: sig });
	}

	let group_of = {};

	for (let g in cfg.groups)
		for (let m in g.members)
			group_of[m] = g.name;

	let bands = {};

	for (let rid, r in radios) {
		if (!r.scanned)
			continue;

		let b = bands[r.band] ??= { units: [], byid: {} };
		let g = group_of[rid];
		let id = g ? 'group:' + g : rid;
		let u = b.byid[id];

		if (!u) {
			u = b.byid[id] = { id, radios: [], current: r.current, candidates: r.candidates, locked: null };
			push(b.units, u);
		}
		else {
			let ok = {};

			for (let s in r.candidates)
				ok[chan.key(s)] = true;

			u.candidates = filter(u.candidates, (s) => ok[chan.key(s)]);
		}

		push(u.radios, rid);

		if (r.locked)
			u.locked = r.locked;
		else if (r.has_mesh && !g)
			u.locked ??= 'mesh interface outside a group';
	}

	return { radios, pairs, bands };
}

function spec_json(s) {
	return s ? { channel: s.channel, width: s.width } : null;
}

function record(st, model, band, p, d) {
	let b = model.bands[band];

	st.plans[band] = {
		ts: time(),
		current_cost: p.current_cost,
		best_cost: p.best_cost,
		gain: d.gain, rel: d.rel,
		action: d.action, reason: d.reason,
		key: d.key, streak: d.streak,
		combos: p.combos, exhaustive: p.exhaustive,
		units: map(b.units, (u) => ({
			id: u.id, radios: u.radios, locked: u.locked,
			current: spec_json(u.current),
			best: spec_json(p.best[u.id])
		}))
	};

	for (let u in b.units) {
		for (let rid in u.radios) {
			let r = model.radios[rid];

			st.radios[rid] = {
				node: r.node, radio: r.radio, band, unit: u.id, locked: u.locked,
				channel: r.current.channel, width: r.current.width,
				util: r.util['' + r.current.freq],
				costs: slice(p.table[rid], 0, 8),
				neighbors: slice(sort(map(r.neighbors, (n) => ({
					bssid: n.bssid, ssid: n.ssid, signal: n.signal,
					channel: n.spec.channel, width: n.spec.width
				})), (x, y) => y.signal - x.signal), 0, 40)
			};
		}
	}
}

// Apply the stored plan of a band, one unit at a time. Stops on first failure.
function apply_band(cfg, st, band) {
	let p = st.plans[band];
	let handles = {};
	let changed = 0;

	for (let n in cfg.nodes)
		handles[n.name] = n.h ?? (n.h = handle(n));

	for (let u in p?.units ?? []) {
		if (u.locked || !u.best || (u.best.channel == u.current?.channel && u.best.width == u.current?.width))
			continue;

		if (changed++ > 0)
			sleep(cfg.apply_gap * 1000);

		let group = length(u.radios) > 1;
		let ok = true;

		for (let rid in u.radios) {
			let nr = split(rid, '/');
			let h = handles[nr[0]];
			let r = h ? h.call('switch', {
				radio: nr[1], channel: u.best.channel, width: u.best.width,
				bcn_count: cfg.bcn_count, nowait: group, reload_fallback: cfg.reload_fallback
			}, 180) : { error: 'node not configured' };

			let res = r.error ? { ok: false, errors: [ r.error ] } : r.data;

			if (!group || !res.ok) {
				add_history(st, {
					rid, from: u.current?.channel, to: u.best.channel, width: u.best.width,
					ok: res.ok, msg: join('; ', res.errors ?? [])
				});
			}

			if (!res.ok) {
				log('err', '%s: switch to channel %d failed: %s', rid, u.best.channel, join('; ', res.errors ?? []));
				ok = false;
				break;
			}
		}

		// mesh groups: all members got the CSA, now confirm each of them
		if (ok && group) {
			for (let rid in u.radios) {
				let nr = split(rid, '/');
				let r = handles[nr[0]].call('confirm', { radio: nr[1], channel: u.best.channel, timeout: 20 }, 60);
				let res = r.error ? { ok: false } : r.data;

				add_history(st, {
					rid, from: u.current?.channel, to: u.best.channel, width: u.best.width,
					ok: res.ok, msg: res.ok ? 'group ' + u.id : 'not on new channel after CSA'
				});

				ok = ok && res.ok;
			}
		}

		if (!ok) {
			p.action = 'failed';
			p.reason = 'switch failed, stopped';

			return false;
		}

		for (let rid in u.radios) {
			st.last_switch[rid] = time();
			delete st.util[rid];
			log('notice', '%s: switched channel %d -> %d (%d MHz)', rid, u.current?.channel, u.best.channel, u.best.width);
		}

		u.current = u.best;
	}

	p.action = 'applied';
	p.key = '';
	p.streak = 0;

	return true;
}

// Full evaluation: discover, scan every node (staggered), plan, maybe apply.
//   opts: { apply: true|false|null (null = follow configured mode), nogap }
function evaluate(opts) {
	if (!lock('evaluate'))
		return { error: 'another operation is running' };

	let cfg = config(), st = load_state(), now = time();
	let scans = {};

	try {
		discover(cfg, st);
		sample_into(st, cfg);

		let first = true;

		for (let node in cfg.nodes) {
			let n = st.nodes[node.name];

			if (!n?.ok)
				continue;

			if (!first && !opts?.nogap && cfg.scan_gap > 0)
				sleep(cfg.scan_gap * 1000);

			first = false;

			for (let radio, r in n.radios) {
				if (index(node.exclude, radio) >= 0 || (r.band != '2g' && r.band != '5g'))
					continue;

				let res = node.h.call('scan', { radio }, 90);

				if (res.error)
					log('warn', '%s/%s: scan failed: %s', node.name, radio, res.error);
				else
					scans[node.name + '/' + radio] = res.data;
			}
		}

		let model = build_model(cfg, st, scans);

		st.radios = {};

		for (let band, b in model.bands) {
			let p = score.plan(b.units, model.radios, model.pairs, cfg);
			let d = score.decide(b.units, p, st.plans[band], st.last_switch, cfg, now);

			record(st, model, band, p, d);
			log('info', '%s: cost %.2f -> %.2f, %s (%s)', band, p.current_cost, p.best_cost, d.action, d.reason);

			let do_apply = (opts?.apply != null) ? opts.apply : (cfg.mode == 'apply');

			if (d.action == 'switch' && do_apply)
				apply_band(cfg, st, band);
			else if (d.action == 'switch')
				st.plans[band].action = 'recommend';
		}

		for (let band in keys(st.plans))
			if (!model.bands[band])
				delete st.plans[band];

		// exponential window: older samples weigh half at every evaluation
		for (let rid, u in st.util) {
			u.acc_active /= 2.0;
			u.acc_busy /= 2.0;
		}

		st.last_eval = now;
	}
	catch (e) {
		log('err', 'evaluation failed: %s', e.message);
		st.last_error = e.message;
	}

	save_state(st);
	unlock();

	return { ok: !st.last_error, plans: st.plans };
}

// Apply the latest stored plan now, ignoring hysteresis ("Apply now").
function apply() {
	if (!lock('apply'))
		return { error: 'another operation is running' };

	let cfg = config(), st = load_state(), ok = true;

	for (let band, p in st.plans)
		if (p.key != '' && p.action != 'applied')
			ok = apply_band(cfg, st, band) && ok;

	discover(cfg, st);
	save_state(st);
	unlock();

	return { ok };
}

function do_discover() {
	let cfg = config(), st = load_state();
	let res = discover(cfg, st);

	if (lock('discover')) {
		save_state(st);
		unlock();
	}

	return res;
}

function status() {
	let st = load_state();

	st.running = running();
	delete st.util;

	return st;
}

// Long-running service loop (procd).
function daemon() {
	let last_sample = 0, done = {};

	log('info', 'started');

	while (true) {
		let cfg = config(), now = time(), lt = localtime(now);
		let hm = sprintf('%02d:%02d', lt.hour, lt.min);
		let today = sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday);

		if (index(cfg.eval_times, hm) >= 0 && done[hm] != today) {
			done[hm] = today;
			evaluate();
			last_sample = time();
		}
		else if (now - last_sample >= cfg.sample_interval) {
			sample();
			last_sample = now;
		}

		sleep(20000);
	}
}

return { config, evaluate, apply, sample, discover: do_discover, status, daemon, build_model };
