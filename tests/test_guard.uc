'use strict';

// Guarded switch on the device, with the real agent and fake iw/wifi.
let fs = require('fs');
let ubus = require('ubus');
let uci = require('uci');
let guard = require('chanmgr.guard');

return function(t) {
	let agent = loadfile(t.dir + '/../files/usr/share/ucode/chanmgr/agent.uc')();
	let run = getenv('CHANMGR_RUN_DIR');
	let set = (name, v) => fs.writefile(run + '/' + name, '' + v);
	let get = (name) => trim(fs.readfile(run + '/' + name) ?? '');
	let reset = (next) => {
		set('freq', 5180);
		set('peers', 1);
		set('next', next);
		fs.unlink(run + '/peers_ttl');
		fs.unlink(run + '/iw.log');
		uci.data.wireless.radio1.channel = '36';
	};
	let go = (extra) => guard.run({ radio: 'radio1', channel: 149, width: 20, delay: 0, up_timeout: 1,
		mesh_timeout: 1, confirm_timeout: 0, watch: 0, mesh_lost: 1, ...(extra ?? {}) });

	guard.use_agent(agent);

	uci.data.wireless = { radio1: { '.type': 'wifi-device', band: '5g', htmode: 'HE20', channel: '36' } };
	ubus.objects['network.wireless'] = {
		status: () => (get('freq') == 'down') ? { radio1: { up: false } } : {
			radio1: { up: true, config: { band: '5g', htmode: 'HE20', channel: uci.data.wireless.radio1.channel },
				interfaces: [ { ifname: 'phy1-ap0', config: { mode: 'ap' } }, { ifname: 'phy1-mesh0', config: { mode: 'mesh' } } ] }
		}
	};

	// healthy switch
	reset('5745 1\n');
	t.eq(agent.mesh_peers([ 'phy1-mesh0' ]), 1, 'guard: mesh peers counted');
	let st = go();
	t.eq([ st.state, st.from, st.to, st.peers_before ], [ 'done', 36, 149, 1 ], 'guard: healthy switch done');
	t.eq([ get('freq'), uci.data.wireless.radio1.channel ], [ '5745', '149' ], 'guard: on 149, persisted');
	t.ok(!fs.stat(run + '/chanmgr.pending.radio1'), 'guard: pending marker removed');
	t.eq(guard.status('radio1').state, 'done', 'guard: status file');

	// radio does not come up on the new channel
	reset('down\n5180 1\n');
	st = go();
	t.eq([ st.state, get('freq'), uci.data.wireless.radio1.channel ], [ 'rolled_back', '5180', '36' ], 'guard: radio down -> back on 36');
	t.ok(index(st.msg, 'did not come up') >= 0, 'guard: reason recorded');

	// radio up but mesh peers never return
	reset('5745 0\n5180 1\n');
	st = go();
	t.eq([ st.state, get('freq'), uci.data.wireless.radio1.channel ], [ 'rolled_back', '5180', '36' ], 'guard: no mesh -> back on 36');
	t.ok(index(st.msg, 'mesh peers did not come back') >= 0, 'guard: mesh reason');

	// no confirmation from the controller
	reset('5745 1\n5180 1\n');
	st = go({ confirm_timeout: 1 });
	t.eq([ st.state, get('freq') ], [ 'rolled_back', '5180' ], 'guard: unconfirmed -> back');
	t.ok(index(st.msg, 'no confirmation') >= 0, 'guard: confirmation reason');

	// confirmed, then the mesh disappears (the peer went back): follow it
	reset('5745 1\n5180 1\n');
	set('peers_ttl', 3);
	st = go({ watch: 5 });
	t.eq([ st.state, get('freq'), uci.data.wireless.radio1.channel ], [ 'rolled_back', '5180', '36' ], 'guard: mesh lost after confirm -> back');
	t.ok(index(st.msg, 'mesh lost after the switch') >= 0, 'guard: watch reason');

	// a radio without mesh peers does not wait for them
	reset('5745 0\n');
	set('peers', 0);
	st = go();
	t.eq([ st.state, st.peers_before ], [ 'done', 0 ], 'guard: no peers before -> no mesh wait');

	// power loss mid-switch: recover at boot
	reset('5180 1\n');
	uci.data.wireless.radio1.channel = '149';
	fs.writefile(run + '/chanmgr.pending.radio1', '{ "radio": "radio1", "channel": 36 }');
	let rec = guard.recover();
	t.eq([ length(rec), uci.data.wireless.radio1.channel ], [ 1, '36' ], 'guard: recover restores the old channel');
	t.ok(!fs.stat(run + '/chanmgr.pending.radio1'), 'guard: recover removes the marker');

	t.eq(guard.start({ radio: 'radio1;reboot', channel: 149 }).ok, false, 'guard: radio name validated');

	guard.use_agent(require('chanmgr.agent'));
};
