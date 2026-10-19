'use strict';

let chan = require('chanmgr.chan');

return function(t) {
	t.eq(chan.chan2freq('2g', 1), 2412, '2g ch1 freq');
	t.eq(chan.chan2freq('2g', 14), 2484, '2g ch14 freq');
	t.eq(chan.chan2freq('5g', 36), 5180, '5g ch36 freq');
	t.eq(chan.freq2chan(5745), 149, 'freq2chan 5745');
	t.eq(chan.freq2chan(2437), 6, 'freq2chan 2437');
	t.eq(chan.freq2band(5180), '5g', 'band 5180');

	t.eq(chan.htmode_width('HE80'), 80, 'HE80 width');
	t.eq(chan.htmode_width('VHT160'), 160, 'VHT160 width');
	t.eq(chan.htmode_width('HT40+'), 40, 'HT40+ width');
	t.eq(chan.htmode_width('NOHT'), 20, 'NOHT width');
	t.eq(chan.htmode_flags('HE80', '5g'), { ht: true, vht: true, he: true, eht: false }, 'HE80 flags');
	t.eq(chan.htmode_flags('HE20', '2g'), { ht: true, vht: false, he: true, eht: false }, 'HE20 2g flags');

	let s = chan.spec('5g', 44, 80);
	t.eq([ s.center, s.cfreq, s.sec ], [ 42, 5210, -1 ], '44/80 center + offset');
	t.eq(chan.subchannels(s), [ 36, 40, 44, 48 ], '44/80 subchannels');

	s = chan.spec('5g', 149, 80);
	t.eq([ s.center, s.cfreq, s.sec ], [ 155, 5775, 1 ], '149/80 center');

	s = chan.spec('5g', 100, 160);
	t.eq(chan.subchannels(s), [ 100, 104, 108, 112, 116, 120, 124, 128 ], '100/160 subchannels');

	s = chan.spec('5g', 157, 40);
	t.eq([ s.center, s.sec ], [ 159, 1 ], '157/40');

	s = chan.spec('5g', 161, 40);
	t.eq([ s.center, s.sec ], [ 159, -1 ], '161/40');

	t.eq(chan.spec('5g', 144, 160).width, 20, 'no 160 block for 144 -> 20');
	t.eq(chan.spec('2g', 6, 80).width, 40, '2g capped at 40');

	// overlap
	t.near(chan.overlap(chan.spec('2g', 1, 20), chan.spec('2g', 6, 20)), 0, '2g 1 vs 6 no overlap');
	t.near(chan.overlap(chan.spec('2g', 1, 20), chan.spec('2g', 11, 20)), 0, '2g 1 vs 11 none');
	t.near(chan.overlap(chan.spec('2g', 1, 20), chan.spec('2g', 3, 20)), 12.0 / 22, '2g 1 vs 3');
	t.near(chan.overlap(chan.spec('5g', 36, 80), chan.spec('5g', 44, 20)), 1, '20 inside 80');
	t.near(chan.overlap(chan.spec('5g', 36, 80), chan.spec('5g', 52, 80)), 0, 'adjacent 80s');
	t.near(chan.overlap(chan.spec('5g', 36, 40), chan.spec('5g', 36, 80)), 1, '40 inside 80');

	// candidates
	let phy = require('chanmgr.parse').phy_channels(t.fixture('phy_5g.txt'));
	let allowed = chan.allowed_map(phy, '5g');

	t.ok(allowed['52'].dfs, '52 is DFS');
	t.ok(!allowed['36'].dfs, '36 not DFS');
	t.ok(!allowed['169'], '169 disabled');

	let keys = (l) => map(l, (x) => chan.key(x));

	t.eq(keys(chan.candidates('5g', 80, allowed, {}, null)), [ '36/80', '149/80' ], '80 MHz, no DFS');
	t.eq(keys(chan.candidates('5g', 80, allowed, { allow_dfs: true }, null)), [ '36/80', '52/80', '100/80', '149/80' ], '80 MHz with DFS');
	t.eq(keys(chan.candidates('5g', 80, allowed, {}, 153)), [ '36/80', '153/80' ], 'keeps preferred primary');
	t.eq(keys(chan.candidates('5g', 40, allowed, {}, null)), [ '36/40', '44/40', '149/40', '157/40' ], '40 MHz');
	t.eq(length(chan.candidates('5g', 20, allowed, {}, null)), 9, '20 MHz count (36-48, 149-165)');

	let a2 = chan.allowed_map(map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 ], (c) => ({ channel: c, freq: chan.chan2freq('2g', c) })), '2g');
	t.eq(keys(chan.candidates('2g', 40, a2, {}, null)), [ '1/20', '6/20', '11/20' ], '2g default 1/6/11');
	t.eq(keys(chan.candidates('2g', 20, a2, { channels_2g: [ 1, 5, 9, 13 ] }, null)), [ '1/20', '5/20', '9/20', '13/20' ], '2g custom list');

	// switch args
	t.eq(chan.switch_args(chan.spec('5g', 149, 80), 'HE80', 10), {
		freq: 5745, center_freq1: 5775, bandwidth: 80, sec_channel_offset: 1, bcn_count: 10,
		ht: true, vht: true, he: true, eht: false
	}, 'switch_chan args 149/80');
};
