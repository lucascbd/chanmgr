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
	let radios = {};

	for (let name, r in st) {
		if (!r.up || r.disabled)
			continue;

		let ifaces = [];

		for (let i in r.interfaces ?? []) {
			if (!i.ifname)
				continue;

			let d = parse.dev_info(iw('dev ' + shq(i.ifname) + ' info'));

			push(ifaces, { ifname: i.ifname, mode: i.config?.mode ?? d.type, addr: d.addr, info: d });
		}

		let main = filter(ifaces, (i) => i.mode == 'ap')[0] ?? filter(ifaces, (i) => i.mode == 'mesh')[0];

		if (!main || main.info.freq == null)
			continue;

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

	return { hostname: trim(fs.readfile('/proc/sys/kernel/hostname') ?? ''), radios };
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

function current_freq(ifname) {
	return parse.dev_info(iw('dev ' + shq(ifname) + ' info')).freq;
}

// Wait until the radio runs on freq. Returns true on success.
function verify(radio, freq, timeout) {
	let r = info().radios[radio];

	if (!r)
		return false;

	for (let t = 0; t < (timeout ?? 15); t++) {
		if (current_freq(r.ifname) == freq)
			return true;

		sleep(1000);
	}

	return false;
}

function persist(radio, channel) {
	let cur = uci.cursor();

	if (cur.get('wireless', radio, 'channel') == '' + channel)
		return;

	// commit only: no "wifi reload", the radio already runs on the new channel
	cur.set('wireless', radio, 'channel', '' + channel);
	cur.commit('wireless');
}

// Switch a radio via CSA.
//   args: { radio, channel, width, bcn_count, nowait, reload_fallback }
function switch_channel(args) {
	let r = info().radios[args.radio];

	if (!r)
		return { ok: false, error: 'unknown or inactive radio: ' + args.radio };

	let s = chan.spec(r.band, +args.channel, +(args.width || r.width));
	let bcn = +(args.bcn_count || 10);
	let errors = [];
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

	if (!ok && args.reload_fallback) {
		persist(args.radio, s.channel);
		system('wifi reload >/dev/null 2>&1');
		ok = verify(args.radio, s.freq, 120);
		push(errors, 'used wifi reload fallback');

		return { ok, errors, freq: s.freq };
	}

	if (ok)
		persist(args.radio, s.channel);

	return { ok, errors, freq: s.freq };
}

// Confirm a switch issued with nowait and persist it.
function confirm(args) {
	let r = info().radios[args.radio];

	if (!r)
		return { ok: false, error: 'unknown or inactive radio: ' + args.radio };

	let freq = chan.chan2freq(r.band, +args.channel);
	let ok = verify(args.radio, freq, +(args.timeout || 15));

	if (ok)
		persist(args.radio, +args.channel);

	return { ok };
}

return { info, survey, scan, switch_channel, confirm, verify };
