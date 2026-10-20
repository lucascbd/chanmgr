'use strict';

let chan = require('chanmgr.chan');
let score = require('chanmgr.score');
let uci = require('uci');
let agent = require('chanmgr.agent');   // stub
let ctl = require('chanmgr.controller');

function util(map_ch) {
	let u = {};

	for (let ch, v in map_ch)
		u['' + chan.chan2freq('5g', +ch)] = v;

	return u;
}

return function(t) {
	let free = util({ '149': 0, '153': 0, '157': 0, '161': 0 });

	t.near(score.capacity(chan.spec('5g', 149, 20), free), 1, 'capacity: free 20 MHz = 1');
	t.near(score.capacity(chan.spec('5g', 149, 40), free), 2, 'capacity: free 40 MHz = 2');
	t.near(score.capacity(chan.spec('5g', 149, 80), free), 4, 'capacity: free 80 MHz = 4');

	let half = util({ '149': 0.5, '153': 0.5, '157': 0.5, '161': 0.5 });
	t.near(score.capacity(chan.spec('5g', 149, 80), half), 0.5 + 0.25 + 2 * 0.0625, 'capacity: half busy 80 MHz');

	// 80 MHz only pays off when the extra 40 MHz is free
	let busy2nd = util({ '149': 0.1, '153': 0.1, '157': 1, '161': 1 });
	t.near(score.capacity(chan.spec('5g', 149, 80), busy2nd), score.capacity(chan.spec('5g', 149, 40), busy2nd), 'capacity: busy secondary 40 adds nothing');

	// a busy primary hurts more than a busy secondary
	let p_busy = util({ '149': 0.6, '153': 0 }), s_busy = util({ '149': 0, '153': 0.6 });
	t.ok(score.capacity(chan.spec('5g', 149, 40), p_busy) < score.capacity(chan.spec('5g', 149, 40), s_busy), 'capacity: primary weighs more');

	t.eq(score.capacity(chan.spec('5g', 149, 80), util({ '149': 0 })), null, 'capacity: missing data -> null');

	// history: cumulative counters give per-evaluation deltas, resets are taken as is
	let st = { chanstats: {} }, now = 1000000;

	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 100, busy: 50, tx: 0 } ], 3, now);
	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 300, busy: 70, tx: 0 } ], 3, now + 3600);
	ctl.record_chanstats(st, 'a/r1', [ { freq: 5745, active: 100, busy: 90, tx: 10 } ], 3, now + 7200);
	t.eq(map(st.chanstats['a/r1']['5745'].samples, (x) => x[1]), [ 0.5, 0.1, 0.8 ], 'history: deltas, reset, own tx excluded');

	let sum = ctl.chanstats_summary(st.chanstats['a/r1'], 3, now + 7200);
	t.near(sum.util['5745'], (0.5 + 0.1 + 0.8) / 3.0, 'history: mean');
	t.eq([ sum.count['5745'], sum.first['5745'] ], [ 3, now ], 'history: count and oldest');

	ctl.record_chanstats(st, 'a/r1', [], 3, now + 5 * 86400);
	t.eq(length(st.chanstats['a/r1']['5745'].samples), 0, 'history: old samples dropped');

	// end to end: an evaluation stores the width analysis (analysis only)
	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', mode: 'apply', scan_gap: '0', apply_gap: '0', history_days: '3', width_analysis: '1' },
		local: { '.type': 'node' }
	};
	require('fs').unlink(getenv('CHANMGR_RUN_DIR') + '/state.json');

	agent.dev.radios.radio1.channel = 36;
	agent.dev.radios.radio1.width = 80;
	agent.dev.neighbors.radio1 = [];
	agent.dev.survey = { radio1: map([ 36, 40, 44, 48, 149, 153, 157, 161 ], (c) => ({
		freq: chan.chan2freq('5g', c), active: 100, busy: (c >= 149) ? 5 : (c == 36 ? 60 : 20), tx: 0
	})) };

	let calls = length(agent.calls);
	ctl.evaluate({ apply: false });

	let s = ctl.status();
	let w = s.radios['local/radio1'].widths;

	t.ok(length(w) >= 4, 'width analysis: options per radio');
	t.eq([ w[0].channel, w[0].width ], [ 149, 80 ], 'width analysis: free 149-161 at 80 MHz ranks first');
	t.ok(length(filter(w, (x) => x.current)) == 1, 'width analysis: current option marked');

	let u = s.plans['5g'].widths[0];
	t.eq([ u.best.channel, u.best.width, u.current.channel, u.current.width ], [ 149, 80, 36, 80 ], 'width analysis: unit best vs current');
	t.ok(u.gain > 0.3, 'width analysis: gain computed');
	t.eq(u.ready, false, 'width analysis: not ready before 3 days of data');
	t.eq(length(filter(slice(agent.calls, calls), (c) => index(c, 'switch') == 0)), 0, 'width analysis: nothing switched');
	t.eq(s.chanstats, null, 'status: raw history not sent to LuCI');

	// off (the default): no history kept, no analysis shown
	delete uci.data.chanmgr.main.width_analysis;
	ctl.evaluate({ apply: false });
	s = ctl.status();
	t.eq([ s.radios['local/radio1'].widths, s.plans['5g'].widths ], [ null, null ], 'width analysis off: nothing computed');
	t.eq(length(keys(json(require('fs').readfile(getenv('CHANMGR_RUN_DIR') + '/state.json')).chanstats)), 0, 'width analysis off: history cleared');

	agent.dev.survey = null;
};
