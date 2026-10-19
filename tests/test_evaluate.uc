'use strict';

let uci = require('uci');
let agent = require('chanmgr.agent');   // stub
let ctl = require('chanmgr.controller');

function reset_state() {
	let fs = require('fs');

	fs.unlink(getenv('CHANMGR_RUN_DIR') + '/state.json');
}

return function(t) {
	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', mode: 'recommend', scan_gap: '0', apply_gap: '0', confirm: '2' },
		local: { '.type': 'node' }
	};

	reset_state();

	// recommend mode: never switches
	let r = ctl.evaluate();

	t.ok(r.ok, 'evaluate ok');
	t.eq([ r.plans['2g'].action, r.plans['5g'].action ], [ 'wait', 'wait' ], 'first run waits for confirmation');

	r = ctl.evaluate();
	t.eq([ r.plans['2g'].action, r.plans['5g'].action ], [ 'recommend', 'recommend' ], 'second run recommends');
	t.eq(length(filter(agent.calls, (c) => index(c, 'switch') == 0)), 0, 'recommend mode does not switch');

	let st = ctl.status();
	t.eq(sort(keys(st.radios)), [ 'local/radio0', 'local/radio1' ], 'status: radios');
	t.eq(st.radios['local/radio0'].neighbors[0].ssid, 'loud', 'status: neighbors');
	t.ok(length(st.radios['local/radio1'].costs) == 2, 'status: cost table (36/80, 149/80)');
	t.ok(st.radios['local/radio0'].util > 0, 'status: sampled utilization');

	// apply one band only
	r = ctl.apply('2g');
	t.eq([ agent.dev.radios.radio0.channel, agent.dev.radios.radio1.channel ], [ 6, 36 ], 'apply 2g: 5g untouched');

	// manual apply of the rest
	r = ctl.apply();
	t.ok(r.ok, 'apply ok');
	t.eq([ agent.dev.radios.radio0.channel, agent.dev.radios.radio1.channel ], [ 6, 149 ], 'apply: switched both radios');
	t.ok(index(agent.calls, 'switch radio1 149/80') >= 0, 'apply: 5g switched with width');

	st = ctl.status();
	t.eq(length(st.history), 2, 'history: 2 switches');
	t.ok(st.last_switch['local/radio1'] > 0, 'last_switch recorded');

	// apply mode: neighbor moves onto our new channel, but we just switched
	uci.data.chanmgr.main.mode = 'apply';
	agent.dev.neighbors.radio1 = [ { bssid: 'aa:11:22:33:44:02', freq: 5745, signal: -45, primary: 149, sec_offset: 'above', vht_width: 1, seg1: 155 } ];

	ctl.evaluate();
	r = ctl.evaluate();
	t.eq(r.plans['5g'].action, 'hold', 'apply mode: min interval holds the switch');
	t.eq(agent.dev.radios.radio1.channel, 149, 'apply mode: still on 149');

	// failure stops and is recorded
	uci.data.chanmgr.main.min_switch_interval = '0';
	agent.dev.fail_switch = true;
	r = ctl.evaluate();
	t.eq(r.plans['5g'].action, 'failed', 'failed switch recorded');
	t.eq(ctl.status().history[0].ok, false, 'history: failure');
	agent.dev.fail_switch = false;

	r = ctl.evaluate();
	t.eq([ r.plans['5g'].action, agent.dev.radios.radio1.channel ], [ 'applied', 36 ], 'apply mode: switches back when confirmed');
};
