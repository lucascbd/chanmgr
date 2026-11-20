'use strict';

let nl = require('chanmgr.nl');

// stand-in for the nl80211 module: replies per command and interface
function fake(replies) {
	let c = { NLM_F_DUMP: 0x300, NL80211_CMD_GET_SURVEY: 50, NL80211_CMD_GET_STATION: 17, NL80211_CMD_GET_INTERFACE: 5 };
	let name = {};

	for (let k, v in c)
		name['' + v] = k;

	return {
		const: c,
		request: (cmd, flags, args) => replies[name['' + cmd]]?.[args.dev]
	};
}

return function(t) {
	t.eq(nl.survey('phy1-ap0'), null, 'nl: unavailable without the module (iw is used)');

	nl.use(fake({
		NL80211_CMD_GET_SURVEY: { 'phy1-ap0': [
			{ survey_info: { frequency: 5180, noise: -92, in_use: true, time: 1000, busy: 300, time_rx: 200, time_tx: 50 } },
			{ survey_info: { frequency: 5200, noise: -95, time: 80, time_busy: 20 } },   // older field names
			{ survey_info: {} }
		] },
		NL80211_CMD_GET_STATION: {
			'phy1-ap0': [ { mac: 'AA:BB:CC:00:00:01', sta_info: { rx_duration: 1500 } }, { mac: 'aa:bb:cc:00:00:02', sta_info: {} } ],
			'phy1-mesh0': [ { mac: '02:00:00:00:00:09', sta_info: { plink_state: 4 } }, { mac: '02:00:00:00:00:0a', sta_info: { plink_state: 1 } } ]
		},
		NL80211_CMD_GET_INTERFACE: {
			'phy1-ap0': { ifname: 'phy1-ap0', iftype: 3, mac: '02:00:00:00:00:01', wiphy: 1, wiphy_freq: 5745, channel_width: 3, center_freq1: 5775 },
			'phy1-mesh0': { ifname: 'phy1-mesh0', iftype: 7, wiphy: 1 }
		}
	}));

	t.eq(nl.survey('phy1-ap0'), [
		{ freq: 5180, in_use: true, noise: -92, active: 1000, busy: 300, rx: 200, tx: 50 },
		{ freq: 5200, in_use: false, noise: -95, active: 80, busy: 20, rx: null, tx: null }
	], 'nl: survey');
	t.eq(nl.station_rx('phy1-ap0'), { 'aa:bb:cc:00:00:01': 1500 }, 'nl: receive airtime per client');
	t.eq(nl.mesh_peers('phy1-mesh0'), 1, 'nl: established mesh peers');
	t.eq(nl.dev_info('phy1-ap0'), { ifname: 'phy1-ap0', addr: '02:00:00:00:00:01', type: 'AP', wiphy: 1, freq: 5745, channel: 149, width: 80, center1: 5775 }, 'nl: interface on 149/80');
	t.eq(nl.dev_info('phy1-mesh0'), { ifname: 'phy1-mesh0', addr: null, type: 'mesh point', wiphy: 1 }, 'nl: interface without channel');
	t.eq([ nl.survey('nope'), nl.dev_info('nope') ], [ null, null ], 'nl: failed request -> null (iw fallback)');

	nl.use(null);
};
