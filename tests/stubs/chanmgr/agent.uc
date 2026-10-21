// Test stub of the local agent: a scripted device with one 2.4 GHz and one
// 5 GHz radio. Tests edit "dev" and read "calls".
'use strict';

let chan = require('chanmgr.chan');

let calls = [];
let dev = {
	radios: {
		radio0: { band: '2g', htmode: 'HE20', channel: 1, width: 20, mode: 'ap', bssids: [ '02:00:00:00:00:01' ] },
		radio1: { band: '5g', htmode: 'HE80', channel: 36, width: 80, mode: 'ap', bssids: [ '02:00:00:00:00:02' ] }
	},
	neighbors: {
		radio0: [ { bssid: 'aa:11:22:33:44:01', freq: 2412, signal: -50, ssid: 'loud' } ],
		radio1: [ { bssid: 'aa:11:22:33:44:02', freq: 5180, signal: -55, primary: 36, sec_offset: 'above', vht_width: 1, seg1: 42 } ]
	},
	fail_switch: false
};

function channels(band) {
	let list = (band == '2g') ? [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ] : [ 36, 40, 44, 48, 52, 56, 60, 64, 149, 153, 157, 161 ];

	return map(list, (c) => ({ channel: c, freq: chan.chan2freq(band, c), radar: c >= 52 && c <= 144 }));
}

function info() {
	push(calls, 'info');

	let radios = {};

	for (let name, r in dev.radios) {
		let s = chan.spec(r.band, r.channel, r.width);

		radios[name] = { ...r, freq: s.freq, center: s.center, ifname: name, has_mesh: false, channels: channels(r.band) };
	}

	return { hostname: 'test', radios };
}

function survey() {
	push(calls, 'survey');

	let res = {};

	for (let name, r in dev.radios) {
		let f = chan.chan2freq(r.band, r.channel);

		res[name] = { freq: f, survey: [ { freq: f, in_use: true, active: 1000 * length(calls), busy: 100 * length(calls), tx: 0 } ] };
	}

	return { radios: res };
}

function scan(radio) {
	push(calls, 'scan ' + radio);

	return { radio, neighbors: dev.neighbors[radio], survey: dev.survey?.[radio] ?? [] };
}

function switch_channel(a) {
	push(calls, sprintf('switch %s %d/%d', a.radio, a.channel, a.width));

	if (dev.fail_switch)
		return { ok: false, errors: [ 'simulated failure' ] };

	dev.radios[a.radio].channel = a.channel;

	return { ok: true, errors: [] };
}

function confirm(a) {
	return { ok: dev.radios[a.radio].channel == a.channel };
}

function clear_changes() {
	push(calls, "clear_changes");
}

return { info, survey, scan, switch_channel, confirm, clear_changes, dev, calls };
