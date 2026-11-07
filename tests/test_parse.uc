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

	let sta = parse.station_rx('Station aa:bb:cc:dd:ee:01 (on phy1-ap0)\n\tinactive time:\t10 ms\n\trx duration:\t123456 us\n\ttx duration:\t50 us\nStation aa:bb:cc:dd:ee:02 (on phy1-ap0)\n\trx duration:\t7 us\n');
	t.eq(sta, { 'aa:bb:cc:dd:ee:01': 123456, 'aa:bb:cc:dd:ee:02': 7 }, 'station rx airtime');

	// hardware channel widths per band
	let caps = (b2, b5) => '\tBand 1:\n\t\tCapabilities: 0x9ef\n' + b2 + '\t\tFrequencies:\n\t\t\t* 2412.0 MHz [1] (20.0 dBm)\n' +
		'\tBand 2:\n\t\tCapabilities: 0x9ef\n\t\t\tHT20/HT40\n\t\tVHT Capabilities (0x339071b2):\n' + b5 +
		'\t\tFrequencies:\n\t\t\t* 5180.0 MHz [36] (23.0 dBm)\n\tSupported commands:\n\t\t * new_interface\n';

	t.eq(parse.phy_widths(caps('\t\t\tHT20/HT40\n', '\t\t\tSupported Channel Width: neither 160 nor 80+80\n\t\t\t\tHE40/HE80/5GHz\n')),
		{ '2g': 40, '5g': 80 }, 'phy widths: up to 80 MHz (AX1800 class)');
	t.eq(parse.phy_widths(caps('', '\t\t\t\tHE40/HE80/5GHz\n\t\t\t\tHE160/5GHz\n')),
		{ '2g': 20, '5g': 160 }, 'phy widths: HE160');
	t.eq(parse.phy_widths(caps('', '\t\t\tSupported Channel Width: 160 MHz, 80+80 MHz\n')), { '2g': 20, '5g': 160 }, 'phy widths: VHT160');
	t.eq(parse.phy_widths(t.fixture('phy_5g.txt')), { '5g': 20 }, 'phy widths: no capability lines');
};
