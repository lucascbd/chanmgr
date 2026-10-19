'use strict';

// The real agent (tests/stubs shadows it for the controller tests), driven
// through fake iw/wifi commands and a stubbed ubus/uci.
let fs = require('fs');
let ubus = require('ubus');
let uci = require('uci');

return function(t) {
	let agent = loadfile(t.dir + '/../files/usr/share/ucode/chanmgr/agent.uc')();
	let run = getenv('CHANMGR_RUN_DIR');
	let set = (name, v) => fs.writefile(run + '/' + name, '' + v);
	let get = (name) => trim(fs.readfile(run + '/' + name) ?? '');
	let reset = (freq) => {
		set('freq', freq);
		set('next', freq);
		fs.unlink(run + '/iw.log');
		uci.data.wireless.radio1.channel = 'auto';
	};

	uci.data.wireless = { radio1: { '.type': 'wifi-device', band: '5g', htmode: 'HE20', channel: 'auto' } };
	ubus.objects['network.wireless'] = {
		status: () => (get('freq') == 'down') ? { radio1: { up: false } } : {
			radio1: { up: true, config: { band: '5g', htmode: 'HE20', channel: uci.data.wireless.radio1.channel },
				interfaces: [ { ifname: 'phy1-ap0', config: { mode: 'ap' } }, { ifname: 'phy1-mesh0', config: { mode: 'mesh' } } ] }
		}
	};

	let csa_works = true;

	ubus.objects['hostapd.phy1-ap0'] = {
		switch_chan: (a) => {
			// a failed multi-interface CSA leaves the radio down
			set('freq', csa_works ? a.freq : 'down');

			return {};
		}
	};

	// info
	reset(5180);
	let i = agent.info().radios.radio1;
	t.eq([ i.channel, i.has_mesh, i.ifname, length(i.channels) ], [ 36, true, 'phy1-ap0', 2 ], 'agent: info');

	// CSA works: switched and persisted
	reset(5180);
	let r = agent.switch_channel({ radio: 'radio1', channel: 149, width: 20, bcn_count: 1 });
	t.eq([ r.ok, get('freq'), uci.data.wireless.radio1.channel ], [ true, '5745', '149' ], 'agent csa: switched + persisted');
	t.ok(index(get('iw.log'), 'switch freq 5745 20 5745') >= 0, 'agent csa: mesh interface switched too');

	// CSA leaves the radio down: restarted on its configured channel, not persisted
	reset(5180);
	csa_works = false;
	r = agent.switch_channel({ radio: 'radio1', channel: 149, width: 20, bcn_count: 1 });
	t.eq([ r.ok, get('freq'), uci.data.wireless.radio1.channel ], [ false, '5180', 'auto' ], 'agent csa failure: radio restarted on old channel');
	t.ok(index(get('iw.log'), 'wifi down radio1') >= 0 && index(get('iw.log'), 'wifi up radio1') >= 0, 'agent csa failure: radio restarted');
	csa_works = true;

	// restart method: persist, wifi reload, verify
	reset(5180);
	set('next', 5745);
	r = agent.switch_channel({ radio: 'radio1', channel: 149, width: 20, method: 'reload' });
	t.eq([ r.ok, get('freq'), uci.data.wireless.radio1.channel ], [ true, '5745', '149' ], 'agent reload: switched + persisted');
	t.ok(index(get('iw.log'), 'switch freq') < 0, 'agent reload: no CSA');

	// restart method works even while the radio is down (rollback)
	reset('down');
	set('next', 5180);
	r = agent.switch_channel({ radio: 'radio1', channel: 36, width: 20, method: 'reload', nowait: true });
	t.ok(r.ok, 'agent reload while down: accepted');
	t.eq(agent.confirm({ radio: 'radio1', channel: 36, timeout: 2 }).ok, true, 'agent reload while down: confirmed');
	t.eq(uci.data.wireless.radio1.channel, '36', 'agent reload while down: persisted');

	t.eq(agent.switch_channel({ radio: 'radio9', channel: 36 }).ok, false, 'agent: unknown radio refused');

	// a radio that is down is reported, not silently dropped
	reset('down');
	let inf = agent.info();
	t.eq([ inf.radios.radio1, inf.down.radio1 ], [ null, 'radio is down' ], 'agent: down radio reported');
};
