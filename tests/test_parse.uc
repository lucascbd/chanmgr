'use strict';

let parse = require('chanmgr.parse');
let chan = require('chanmgr.chan');

return function(t) {
	let bss = parse.scan(t.fixture('scan_5g.txt'));

	t.eq(length(bss), 4, 'scan: 4 BSS');
	t.eq([ bss[0].bssid, bss[0].freq, bss[0].signal, bss[0].ssid ], [ '11:22:33:44:55:01', 5180, -52, 'Vizinho101' ], 'scan: first BSS');
	t.eq([ bss[0].primary, bss[0].sec_offset, bss[0].vht_width, bss[0].seg1 ], [ 36, 'above', 1, 42 ], 'scan: HT/VHT fields');
	t.eq(bss[2].ssid, '', 'scan: hidden SSID');

	let specs = map(bss, (b) => chan.key(chan.neighbor_spec(b)));
	t.eq(specs, [ '36/80', '149/20', '40/40', '149/80' ], 'scan: neighbor specs');
	t.eq(chan.neighbor_spec(bss[2]).center, 38, 'scan: 40 below center');

	let sv = parse.survey(t.fixture('survey.txt'));

	t.eq(length(sv), 3, 'survey: 3 entries');
	t.eq(sv[1], { freq: 5745, in_use: true, noise: -95, active: 100000, busy: 30000, rx: 12000, tx: 10000 }, 'survey: in-use entry');
	t.eq(sv[2].active, 0, 'survey: idle channel');

	let d = parse.dev_info(t.fixture('dev_info.txt'));

	t.eq(d, { ifname: 'phy1-ap0', addr: '0a:bb:cc:00:00:10', type: 'AP', wiphy: 1, channel: 149, freq: 5745, width: 80, center1: 5775 }, 'dev info');

	let d20 = parse.dev_info('Interface x\n\tchannel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz\n');
	t.eq([ d20.channel, d20.width, d20.center1 ], [ 6, 20, 2437 ], 'dev info 2g');

	let d0 = parse.dev_info('Interface x\n\tchannel 1 (2412 MHz), width: 20 MHz (no HT), center1: 2412 MHz\n');
	t.eq([ d0.channel, d0.width ], [ 1, 20 ], 'dev info no HT');

	let phy = parse.phy_channels(t.fixture('phy_5g.txt'));

	t.eq(length(phy), 18, 'phy: 18 channels');
	t.eq(phy[4], { freq: 5260, channel: 52, disabled: false, no_ir: true, radar: true }, 'phy: radar channel');
	t.eq(phy[17].disabled, true, 'phy: disabled channel');
};
