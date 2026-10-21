'use strict';

let uci = require('uci');
let agent = require('chanmgr.agent');   // stub
let ctl = require('chanmgr.controller');
let chan = require('chanmgr.chan');

function reset_state() {
	let fs = require('fs');

	fs.unlink(getenv('CHANMGR_RUN_DIR') + '/state.json');
	fs.unlink(getenv('CHANMGR_PERSIST_DIR') + '/state.json');
}

return function(t) {
	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', mode: 'recommend', scan_gap: '0', apply_gap: '0', confirm: '2', history_days: '0' },
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
	t.ok(length(st.radios['local/radio1'].options) == 2, 'status: options table (36/80, 149/80)');
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
	t.eq([ st.history[0].from_width, st.history[0].width ], [ 80, 80 ], 'history: previous and new width');
	t.eq(st.scheduler.heartbeat, null, 'status: no heartbeat timestamp (would force redraws)');
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

	// our own clients' receive airtime is not counted as congestion
	let survey = (active, busy, rx_us) => ({ data: { radios: { radio1: {
		freq: 5745, survey: [ { freq: 5745, in_use: true, active, busy, tx: 0 } ], stations: { 'aa:bb:cc:dd:ee:01': rx_us }
	} } } });
	let replies = [ survey(1000, 100, 0), survey(2000, 600, 300000) ];
	let st2 = { util: {} };

	for (let i = 0; i < 2; i++)
		ctl.sample_into(st2, { nodes: [ { name: 'x', h: { call: () => replies[i] } } ] });

	t.near(st2.util['x/radio1'].value, (500 - 300) / 1000.0, 'sampling: own clients rx excluded');

	// history survives a reboot: /tmp is empty, the copy in /etc is used
	let fs = require('fs'), run = getenv('CHANMGR_RUN_DIR'), keep = getenv('CHANMGR_PERSIST_DIR');

	uci.data.chanmgr = { main: { '.type': 'chanmgr', mode: 'recommend', scan_gap: '0' }, local: { '.type': 'node' } };
	ctl.evaluate({ apply: false });

	let before = ctl.status();
	t.ok(fs.stat(keep + '/state.json'), 'persist: copy written after an evaluation');
	t.eq(json(fs.readfile(keep + '/state.json')).util, null, 'persist: utilization counters not kept');

	fs.unlink(run + '/state.json');   // reboot
	let after = ctl.status();
	t.eq([ length(after.history), after.last_eval ], [ length(before.history), before.last_eval ], 'persist: history back after reboot');

	let mtime = fs.stat(keep + '/state.json').mtime;
	ctl.sample();
	t.eq(fs.stat(keep + '/state.json').mtime, mtime, 'persist: samples do not write the flash');

	// "Clear history": history, measurements and plans go, the 24 h hold stays
	after = ctl.status();
	let held = after.last_switch;
	t.ok(length(after.history) > 0, 'clear: there is history to clear');
	t.eq(ctl.clear_history(), { ok: true }, 'clear: done');

	let cleared = ctl.status(), saved = json(fs.readfile(keep + '/state.json'));
	t.eq([ cleared.history, cleared.plans, cleared.radios ], [ [], {}, {} ], 'clear: history and plans gone');
	t.eq([ saved.history, saved.chanstats ], [ [], {} ], 'clear: persistent copy cleared too');
	t.eq(cleared.last_switch, held, 'clear: 24 h hold kept');

	// with the default 3 days, a fresh start proposes a plan but switches
	// nothing automatically until the measurements cover those days
	uci.data.chanmgr.main.mode = 'apply';
	agent.dev.neighbors.radio1 = [ { bssid: 'aa:11:22:33:44:02', freq: chan.chan2freq('5g', agent.dev.radios.radio1.channel), signal: -45, primary: agent.dev.radios.radio1.channel, vht_width: 0 } ];
	fs.unlink(run + '/state.json');
	fs.unlink(keep + '/state.json');

	let calls0 = length(agent.calls);

	ctl.evaluate();
	let fresh = ctl.evaluate();

	t.ok(fresh.plans['5g'].key != '', 'measurements: a better channel is proposed');
	t.eq(fresh.plans['5g'].action, 'wait', 'measurements: no automatic change without days of data');
	t.ok(index(fresh.plans['5g'].reason, 'collecting measurements') == 0, 'measurements: says so (' + fresh.plans['5g'].reason + ')');
	t.eq(length(filter(slice(agent.calls, calls0), (c) => index(c, 'switch') == 0)), 0, 'measurements: nothing switched');
};
