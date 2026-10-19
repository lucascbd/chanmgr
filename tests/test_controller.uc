'use strict';

let uci = require('uci');
let chan = require('chanmgr.chan');
let score = require('chanmgr.score');
let parse = require('chanmgr.parse');
let ctl = require('chanmgr.controller');

// controller without radios + two APs (2.4 GHz AP + 5 GHz AP/mesh radio)
function phy2g() {
	return map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 ], (c) => ({ channel: c, freq: chan.chan2freq('2g', c) }));
}

function ap(mac2, mac5, ch2, ch5, phy5) {
	return {
		ok: true,
		radios: {
			radio0: { band: '2g', htmode: 'HE20', channel: ch2, width: 20, center: ch2, bssids: [ mac2 ], channels: phy2g(), has_mesh: false },
			radio1: { band: '5g', htmode: 'HE80', channel: ch5, width: 80, center: chan.spec('5g', ch5, 80).center, bssids: [ mac5 ], channels: phy5, has_mesh: true }
		}
	};
}

return function(t) {
	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', enabled: '1', mode: 'apply', eval_times: [ '03:00' ], channels_2g: [ '1', '6', '11' ], min_gain_rel: '30' },
		local: { '.type': 'node', enabled: '0' },
		ap1: { '.type': 'node', host: '10.0.0.2', username: 'chanmgr', password: 'x', lock: 'radio2' },
		ap2: { '.type': 'node', host: '10.0.0.3', exclude: [ 'radio2' ] },
		mesh: { '.type': 'group', member: [ 'ap1/radio1', 'ap2/radio1' ] }
	};

	let cfg = ctl.config();

	t.eq(map(cfg.nodes, (n) => [ n.name, n.type ]), [ [ 'ap1', 'remote' ], [ 'ap2', 'remote' ] ], 'config: disabled local node skipped');
	t.eq([ cfg.mode, cfg.eval_times, cfg.min_gain_rel, cfg.channels_2g ], [ 'apply', [ '03:00' ], 30, [ 1, 6, 11 ] ], 'config: main options');
	t.eq([ cfg.nodes[0].lock, cfg.nodes[1].exclude ], [ [ 'radio2' ], [ 'radio2' ] ], 'config: lists');
	t.eq(cfg.groups, [ { name: 'mesh', members: [ 'ap1/radio1', 'ap2/radio1' ] } ], 'config: groups');

	// sections added in LuCI are anonymous and carry "name"; duplicates are skipped
	uci.data.chanmgr.cfg0a1b2c = { '.type': 'node', name: 'ap3', host: '10.0.0.4' };
	uci.data.chanmgr.cfg0a1b2d = { '.type': 'node', name: 'ap1', host: '10.0.0.9' };
	uci.data.chanmgr.cfg0a1b2e = { '.type': 'group', name: 'g24', member: [ 'ap1/radio0', 'ap3/radio0' ] };

	let cfg2 = ctl.config();

	t.eq(map(cfg2.nodes, (n) => [ n.name, n.host ]), [ [ 'ap1', '10.0.0.2' ], [ 'ap2', '10.0.0.3' ], [ 'ap3', '10.0.0.4' ] ], 'config: anonymous nodes by name, duplicate skipped');
	t.eq(map(cfg2.groups, (g) => g.name), [ 'mesh', 'g24' ], 'config: anonymous group by name');

	delete uci.data.chanmgr.cfg0a1b2c;
	delete uci.data.chanmgr.cfg0a1b2d;
	delete uci.data.chanmgr.cfg0a1b2e;

	let phy5 = parse.phy_channels(t.fixture('phy_5g.txt'));
	let st = {
		nodes: {
			ap1: ap('0a:00:00:00:01:01', '0a:00:00:00:01:02', 1, 36, phy5),
			ap2: ap('0a:00:00:00:02:01', '0a:00:00:00:02:02', 1, 36, phy5)
		},
		util: { 'ap1/radio0': { freq: 2412, value: 0.4 } }
	};

	let scans = {
		'ap1/radio0': {
			neighbors: [
				{ bssid: '0a:00:00:00:02:01', freq: 2412, signal: -55 },        // ap2 (own)
				{ bssid: '0e:00:00:00:02:01', freq: 2412, signal: -56 },        // ap2 secondary BSSID (own)
				{ bssid: '11:11:11:11:11:11', freq: 2437, signal: -60, ssid: 'n1' },
				{ bssid: '22:22:22:22:22:22', freq: 5180, signal: -40 }         // other band: ignored
			],
			survey: [ { freq: 2412, active: 100, busy: 90, tx: 0 }, { freq: 2462, active: 100, busy: 10, tx: 0 } ]
		},
		'ap2/radio0': { neighbors: [ { bssid: '0a:00:00:00:01:01', freq: 2412, signal: -58 } ], survey: [] },
		'ap1/radio1': { neighbors: [ { bssid: '33:33:33:33:33:33', freq: 5180, signal: -60, primary: 36, sec_offset: 'above', vht_width: 1, seg1: 42 } ], survey: [] },
		'ap2/radio1': { neighbors: [], survey: [] }
	};

	let m = ctl.build_model(cfg, st, scans);

	t.eq(sort(keys(m.radios)), [ 'ap1/radio0', 'ap1/radio1', 'ap2/radio0', 'ap2/radio1' ], 'model: radios');
	t.eq(map(m.radios['ap1/radio0'].neighbors, (n) => n.bssid), [ '11:11:11:11:11:11' ], 'model: own + other band filtered');
	t.eq(m.pairs, [ { a: 'ap1/radio0', b: 'ap2/radio0', signal: -55 } ], 'model: own pair, strongest signal');
	t.near(m.radios['ap1/radio0'].util['2412'], 0.4, 'model: sampled util overrides scan survey');
	t.near(m.radios['ap1/radio0'].util['2462'], 0.1, 'model: scan survey util');

	let b5 = m.bands['5g'];

	t.eq(map(b5.units, (u) => [ u.id, u.radios, u.locked ]), [ [ 'group:mesh', [ 'ap1/radio1', 'ap2/radio1' ], null ] ], 'model: mesh group is one unit');

	let p = score.plan(b5.units, m.radios, m.pairs, cfg);
	t.eq(chan.key(p.best['group:mesh']), '149/80', '5g: group leaves congested block');

	let b2 = m.bands['2g'];
	p = score.plan(b2.units, m.radios, m.pairs, cfg);

	let ch = map(b2.units, (u) => p.best[u.id].channel);
	t.ok(ch[0] != ch[1], '2g: own APs separated');
	t.ok(index(ch, 6) < 0, '2g: avoids neighbor on 6');

	// mesh radio outside a group is locked
	delete uci.data.chanmgr.mesh;
	m = ctl.build_model(ctl.config(), st, scans);
	t.eq(m.bands['5g'].units[0].locked, 'mesh interface outside a group', 'model: lone mesh radio locked');

	// lock list
	uci.data.chanmgr.ap1.lock = [ 'radio0' ];
	m = ctl.build_model(ctl.config(), st, scans);
	t.eq(m.bands['2g'].units[0].locked, 'locked in configuration', 'model: lock option');
};
