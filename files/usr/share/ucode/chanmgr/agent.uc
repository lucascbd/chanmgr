// SPDX-License-Identifier: GPL-2.0-only
// Agent: measures and switches the radios of the local device.
// Used directly by the controller for the local node and exposed to remote
// controllers through the rpcd plugin (chanmgr agent_* methods).
//
// Does not call rpcd-provided ubus objects (iwinfo, uci, ...): this module
// also runs inside rpcd, where that would deadlock.

'use strict';

let fs = require('fs');
let ubus = require('ubus');
let uci = require('uci');
let chan = require('chanmgr.chan');
let parse = require('chanmgr.parse');

let conn;

function bus() {
	conn ??= ubus.connect();

	return conn;
}

function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function run(cmd) {
	let p = fs.popen(cmd + ' 2>/dev/null', 'r');

	if (!p)
		return null;

	let out = p.read('all');

	p.close();

	return out;
}

function iw(args) {
	return run('iw ' + args);
}

// Radios of this device with their interfaces, current channel and the
// channels the regulatory domain allows.
function info() {
	let st = bus().call('network.wireless', 'status', {}) ?? {};
	let cur = uci.cursor();
	let radios = {}, down = {};

	for (let name, r in st) {
		if (r.disabled)
			continue;

		if (!r.up) {
			down[name] = 'radio is down';
			continue;
		}

		let ifaces = [];

		for (let i in r.interfaces ?? []) {
			if (!i.ifname)
				continue;

			let d = parse.dev_info(iw('dev ' + shq(i.ifname) + ' info'));

			push(ifaces, { ifname: i.ifname, mode: i.config?.mode ?? d.type, addr: d.addr, info: d });
		}

		let main = filter(ifaces, (i) => i.mode == 'ap')[0] ?? filter(ifaces, (i) => i.mode == 'mesh')[0];

		if (!main || main.info.freq == null) {
			down[name] = main ? main.ifname + ' has no channel (not started, or waiting for DFS)' : 'no AP or mesh interface';
			continue;
		}

		let d = main.info;
		let band = r.config?.band ?? cur.get('wireless', name, 'band') ?? chan.freq2band(d.freq);
		let htmode = r.config?.htmode ?? cur.get('wireless', name, 'htmode') ?? 'HT20';
		let channels = parse.phy_channels(iw('phy#' + d.wiphy + ' info'));

		radios[name] = {
			band, htmode,
			ifname: main.ifname,
			mode: main.mode,
			channel: d.channel,
			freq: d.freq,
			width: d.width,
			center: chan.freq2chan(d.center1),
			cfg_channel: '' + (r.config?.channel ?? cur.get('wireless', name, 'channel') ?? 'auto'),
			has_mesh: length(filter(ifaces, (i) => i.mode == 'mesh')) > 0,
			ifaces: map(ifaces, (i) => ({ ifname: i.ifname, mode: i.mode, addr: i.addr })),
			bssids: filter(map(ifaces, (i) => i.addr), (a) => a),
			channels: filter(channels, (c) => chan.freq2band(c.freq) == band)
		};
	}

	// agent: feature level, lets the controller refuse what an old agent cannot do
	return { hostname: trim(fs.readfile('/proc/sys/kernel/hostname') ?? ''), agent: 3, radios, down };
}

// Survey counters of every radio (passive, no off-channel time).
function survey() {
	let res = {};

	for (let name, r in info().radios)
		res[name] = { freq: r.freq, survey: parse.survey(iw('dev ' + shq(r.ifname) + ' survey dump')) };

	return { radios: res };
}

// Off-channel scan of one radio, plus the survey data collected while scanning.
function scan(radio) {
	let r = info().radios[radio];

	if (!r)
		return { error: 'unknown or inactive radio: ' + radio };

	let cmd = 'dev ' + shq(r.ifname) + ' scan' + ((r.mode == 'ap') ? ' ap-force' : '');
	let bss = parse.scan(iw(cmd));

	// "Device or resource busy" while another scan is running: retry once
	if (!length(bss)) {
		sleep(3000);
		bss = parse.scan(iw(cmd));
	}

	if (!length(bss))
		bss = parse.scan(iw('dev ' + shq(r.ifname) + ' scan dump'));

	return {
		radio, freq: r.freq,
		neighbors: bss,
		survey: parse.survey(iw('dev ' + shq(r.ifname) + ' survey dump'))
	};
}

// Number of established 802.11s peers on the given interfaces.
function mesh_peers(ifnames) {
	let n = 0;

	for (let ifname in ifnames)
		n += length(filter(split(iw('dev ' + shq(ifname) + ' station dump') ?? '', '\n'),
			(l) => match(l, /mesh plink:\s+ESTAB/)));

	return n;
}

function current_freq(ifname) {
	return parse.dev_info(iw('dev ' + shq(ifname) + ' info')).freq;
}

// Wait until the radio runs on freq. Returns true on success. The radio may
// be down for a while (restart), so look it up again on every attempt.
function verify(radio, freq, timeout) {
	for (let t = 0; t < (timeout ?? 15); t++) {
		let r = info().radios[radio];

		if (r && current_freq(r.ifname) == freq)
			return true;

		sleep(1000);
	}

	return false;
}

// Restart one radio with its configured settings (also brings back an
// interface that hostapd disabled after a failed channel switch).
function restart(radio) {
	system(sprintf('wifi down %s >/dev/null 2>&1; wifi up %s >/dev/null 2>&1', shq(radio), shq(radio)));
}

function persist(radio, channel) {
	let cur = uci.cursor();

	if (cur.get('wireless', radio, 'channel') == '' + channel)
		return;

	// commit only: no "wifi reload", the radio already runs on the new channel
	cur.set('wireless', radio, 'channel', '' + channel);
	cur.commit('wireless');
}

// Switch a radio.
//   args: { radio, channel, width, bcn_count, nowait, reload_fallback, method }
//   method "csa" (default): channel switch announcement, clients stay connected;
//     on failure the radio is restarted on its configured (old) channel, or on
//     the new one with reload_fallback.
//   method "reload": write the channel to UCI and restart the radio. Clients
//     reconnect, but it works for radios that also carry a mesh interface,
//     where a CSA can leave the radio down.
function switch_channel(args) {
	let cur = uci.cursor();

	if (cur.get('wireless', args.radio) != 'wifi-device')
		return { ok: false, error: 'unknown radio: ' + args.radio };

	let r = info().radios[args.radio];
	let band = r?.band ?? cur.get('wireless', args.radio, 'band');
	let width = +(args.width || r?.width || chan.htmode_width(cur.get('wireless', args.radio, 'htmode')));
	let s = chan.spec(band, +args.channel, width);
	let bcn = +(args.bcn_count || 10);
	let errors = [];

	if (args.method == 'reload' || !r) {
		persist(args.radio, s.channel);
		system('wifi reload >/dev/null 2>&1');

		if (args.nowait)
			return { ok: true, errors, freq: s.freq };

		let ok = verify(args.radio, s.freq, 45);

		return { ok, errors: ok ? [] : [ 'radio not on the new channel after restart' ], freq: s.freq };
	}

	let ap = filter(r.ifaces, (i) => i.mode == 'ap')[0];

	if (ap) {
		// one call switches every BSS of the hostapd interface
		bus().call('hostapd.' + ap.ifname, 'switch_chan', chan.switch_args(s, r.htmode, bcn));

		let err = bus().error();

		if (err)
			push(errors, 'hostapd switch_chan: ' + err);
	}

	for (let i in filter(r.ifaces, (i) => i.mode == 'mesh')) {
		let cmd = sprintf('iw dev %s switch freq %d %d %d beacons %d', shq(i.ifname), s.freq, s.width, s.cfreq, bcn);

		if (system(cmd + ' >/dev/null 2>&1') != 0)
			push(errors, 'mesh CSA failed on ' + i.ifname);
	}

	if (args.nowait)
		return { ok: !length(errors), errors, freq: s.freq };

	let ok = verify(args.radio, s.freq, int(bcn * 0.1024) + 10);

	if (ok) {
		persist(args.radio, s.channel);

		return { ok, errors, freq: s.freq };
	}

	if (args.reload_fallback) {
		persist(args.radio, s.channel);
		system('wifi reload >/dev/null 2>&1');
		ok = verify(args.radio, s.freq, 90);
		push(errors, 'CSA failed, used wifi reload fallback');

		return { ok, errors, freq: s.freq };
	}

	// never leave the radio broken: back to its configured channel
	push(errors, 'CSA failed, radio restarted on its previous channel');
	restart(args.radio);

	return { ok: false, errors, freq: s.freq };
}

// Confirm a switch issued with nowait and persist it.
function confirm(args) {
	let band = info().radios[args.radio]?.band ?? uci.cursor().get('wireless', args.radio, 'band');

	if (!band)
		return { ok: false, error: 'unknown radio: ' + args.radio };

	let freq = chan.chan2freq(band, +args.channel);
	let ok = verify(args.radio, freq, +(args.timeout || 15));

	if (ok)
		persist(args.radio, +args.channel);

	return { ok };
}

return { info, survey, scan, switch_channel, confirm, verify, persist, current_freq, mesh_peers };
