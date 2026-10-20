'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';

const callGetLogin = rpc.declare({
	object: 'chanmgr',
	method: 'get_login',
	expect: { }
});

const callSetLogin = rpc.declare({
	object: 'chanmgr',
	method: 'set_login',
	params: [ 'username', 'password' ],
	expect: { }
});

const NAME_RE = /^[A-Za-z0-9_]+$/;

// Sections added in LuCI are anonymous and store their name in "name";
// hand-written named sections (e.g. 'local') fall back to the section id.
function nameOption(s, title, description) {
	const o = s.option(form.Value, 'name', title, description);

	o.rmempty = false;
	// cfgvalue() is also the setter LuCI uses while loading: pass every argument on
	o.cfgvalue = function(section_id, set_value) {
		return this.super('cfgvalue', arguments) ?? (/^(cfg|new)[0-9a-f]{6}$/.test(section_id) ? null : section_id);
	};
	o.validate = (section_id, value) => NAME_RE.test(value ?? '') ? true : _('Use only letters, digits and underscores');

	return o;
}

// Sections only shown when this device is the router (controller).
function routerOnly(s) {
	const render = s.render;

	s.render = function(...args) {
		return Promise.resolve(render.apply(this, args)).then((node) => E('div', { 'class': 'chanmgr-router-only' }, node));
	};

	return s;
}

function showRole(root, role) {
	root.querySelectorAll('.chanmgr-router-only').forEach((el) => el.style.display = (role == 'ap') ? 'none' : '');
}

function validateTimes(section_id, value) {
	if (value == null || value == '')
		return true;

	for (const t of value.trim().split(/\s+/))
		if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(t))
			return _('Expecting space-separated times in HH:MM format');

	return true;
}

return view.extend({
	load() {
		return Promise.all([ uci.load('chanmgr'), callGetLogin().catch(() => ({})) ]);
	},

	render([ , login ]) {
		let m, s, o;

		m = new form.Map('chanmgr', _('Channel Manager'),
			_('Periodically scans the Wi-Fi channels of your access points and moves their radios to the least congested channels. One device, the router, plans for all of them; the access points only measure and switch when the router asks.'));

		s = m.section(form.NamedSection, 'main', 'chanmgr', _('Device role'));

		o = s.option(form.ListValue, 'role', _('Mode'),
			_('Router: plans and switches the channels of all access points. Access point: only measures and switches when the router asks.'));
		o.value('router', _('Router'));
		o.value('ap', _('Access point'));
		o.default = 'router';
		o.onchange = (ev, section_id, value) => showRole(document, value);

		o = s.option(form.DummyValue, '_login_state', _('Login for the router'));
		o.depends('role', 'ap');
		o.cfgvalue = () => login?.configured
			? _('"%s" is configured. Use it, with its password, when adding this access point as a node on the router.').format(login.username)
			: _('Not configured yet: choose a user name and a password below and save.');

		o = s.option(form.Value, 'agent_user', _('User name'),
			_('Login the router uses to reach this access point. It can only measure and switch the Wi-Fi channels.'));
		o.depends('role', 'ap');
		o.placeholder = 'chanmgr';
		o.datatype = 'and(minlength(1),maxlength(32))';
		o.validate = (section_id, value) => (!value || /^[A-Za-z0-9_.-]+$/.test(value)) && value != 'root'
			? true : _('Use letters, digits, ".", "_" or "-" (not root)');

		o = s.option(form.Value, 'agent_password', _('Password'),
			_('At least 8 characters. Leave empty to keep the current password.'));
		o.depends('role', 'ap');
		o.password = true;
		o.datatype = 'minlength(8)';
		// never stored in /etc/config/chanmgr: hashed into the rpcd login instead
		o.cfgvalue = () => null;
		o.remove = () => null;
		o.write = function(section_id, value) {
			const user = this.section.formvalue(section_id, 'agent_user') || 'chanmgr';

			return callSetLogin(user, value).then((r) => {
				if (r?.ok)
					ui.addNotification(null, E('p', _('Login "%s" saved. Use it for this access point on the router.').format(user)), 'info');
				else
					ui.addNotification(null, E('p', _('Could not save the login: %s').format(r?.error ?? '?')), 'danger');
			});
		};

		s = routerOnly(m.section(form.NamedSection, 'main', 'chanmgr', _('Router settings')));
		s.tab('general', _('General'));
		s.tab('decision', _('Decision'));
		s.tab('width', _('Channel width'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable scheduler'),
			_('Samples channel utilization and runs the scheduled evaluations. Manual evaluations work without it.'));

		o = s.taboption('general', form.ListValue, 'mode', _('When a better channel is found'));
		o.value('recommend', _('Recommend only'));
		o.value('apply', _('Apply automatically'));
		o.default = 'recommend';

		o = s.taboption('general', form.Value, 'eval_times', _('Evaluation times'),
			_('Space-separated local times (HH:MM). Scanning takes the radios off-channel for a moment, so prefer quiet hours.'));
		o.placeholder = '02:30 04:30';
		o.validate = validateTimes;

		o = s.taboption('general', form.Value, 'sample_interval', _('Sampling interval'),
			_('Seconds between passive utilization samples of the current channels.'));
		o.datatype = 'range(60,3600)';
		o.placeholder = '300';

		o = s.taboption('general', form.Value, 'scan_gap', _('Pause between nodes'),
			_('Seconds between the scans of two nodes, so they are never off-channel at the same time.'));
		o.datatype = 'range(0,1800)';
		o.placeholder = '120';

		o = s.taboption('decision', form.Value, 'min_gain_rel', _('Minimum relative gain (%)'),
			_('Only switch if the total cost drops by at least this percentage.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '25';

		o = s.taboption('decision', form.Value, 'min_gain_abs', _('Minimum absolute gain'));
		o.datatype = 'ufloat';
		o.placeholder = '0.5';

		o = s.taboption('decision', form.Value, 'confirm', _('Confirmations'),
			_('Number of consecutive evaluations that must propose the same plan.'));
		o.datatype = 'range(1,10)';
		o.placeholder = '2';

		o = s.taboption('decision', form.Value, 'min_switch_interval', _('Minimum interval between switches'),
			_('Seconds a radio must stay on a channel before it can be moved again.'));
		o.datatype = 'uinteger';
		o.placeholder = '86400';

		o = s.taboption('decision', form.Flag, 'allow_dfs', _('Allow DFS channels'),
			_('Channels 52–144 need a silent channel availability check (1 to 10 minutes) and must be left when radar is detected.'));

		o = s.taboption('decision', form.DynamicList, 'channels_2g', _('2.4 GHz channels'),
			_('Candidate channels in the 2.4 GHz band. Only non-overlapping channels are recommended.'));
		o.datatype = 'range(1,14)';
		o.placeholder = '1';

		o = s.taboption('width', form.Flag, 'width_analysis', _('Choose the channel width too'),
			_('The 5 GHz plan then picks channel and width together, by how much your devices could transmit, measured on each channel over several days. A width change is only proposed with enough days of data, at least 30% more capacity and three evaluations in a row asking for it; it is applied like any other change, so only in "Apply automatically" mode or with the apply button.'));
		o.default = o.disabled;

		o = s.taboption('width', form.MultiValue, 'widths_5g', _('5 GHz widths to compare'),
			_('The width configured on the radio is always included.'));
		o.value('20', '20 MHz');
		o.value('40', '40 MHz');
		o.value('80', '80 MHz');
		o.value('160', '160 MHz');
		o.default = '40 80';
		o.depends('width_analysis', '1');

		o = s.taboption('width', form.Value, 'history_days', _('Days of measurements'),
			_('How many days of scans an estimate needs before it is considered reliable.'));
		o.datatype = 'range(1,30)';
		o.placeholder = '3';
		o.depends('width_analysis', '1');

		o = s.taboption('advanced', form.Value, 'util_weight', _('Utilization weight'),
			_('Cost added by a fully busy channel, compared to a neighbor received at the reference level.'));
		o.datatype = 'ufloat';
		o.placeholder = '2';

		o = s.taboption('advanced', form.Value, 'own_weight', _('Own AP weight'),
			_('Multiplier for the interference between your own access points.'));
		o.datatype = 'ufloat';
		o.placeholder = '2';

		o = s.taboption('advanced', form.Value, 'ref_rssi', _('Reference signal (dBm)'),
			_('A neighbor received at this level costs 1.0; every +10 dB multiplies the cost by 10.'));
		o.datatype = 'range(-100,-20)';
		o.placeholder = '-70';

		o = s.taboption('advanced', form.Value, 'apply_gap', _('Pause between switches'),
			_('Seconds between switching two radios.'));
		o.datatype = 'range(0,600)';
		o.placeholder = '30';

		o = s.taboption('advanced', form.Value, 'bcn_count', _('CSA beacon count'),
			_('Beacons announcing the channel switch before it happens.'));
		o.datatype = 'range(1,255)';
		o.placeholder = '10';

		o = s.taboption('advanced', form.ListValue, 'mesh_method', _('Switching radios with mesh'),
			_('Radios that also carry an 802.11s mesh interface. With the guarded restart every node switches on its own and goes back to the old channel by itself if its radio or its mesh peers do not come back, or if this controller cannot confirm the switch. A channel switch announcement on such a radio is not supported by every driver and can leave the radio down.'));
		o.value('reload', _('Guarded restart (recommended)'));
		o.value('csa', _('Channel switch announcement (experimental)'));
		o.default = 'reload';

		o = s.taboption('advanced', form.Value, 'guard_mesh_timeout', _('Mesh recovery timeout'),
			_('Seconds a node waits for its mesh peers on the new channel before it returns to the old one on its own.'));
		o.datatype = 'range(20,600)';
		o.placeholder = '90';
		o.depends('mesh_method', 'reload');

		o = s.taboption('advanced', form.Value, 'guard_confirm_timeout', _('Confirmation timeout'),
			_('Seconds a node waits for this controller to confirm the switch (only possible when every node of the group is reachable on the new channel) before it returns to the old one on its own.'));
		o.datatype = 'range(30,1800)';
		o.placeholder = '240';
		o.depends('mesh_method', 'reload');

		o = s.taboption('advanced', form.Flag, 'reload_fallback', _('Reload Wi-Fi if CSA fails'),
			_('Falls back to "wifi reload", which disconnects all clients of the node.'));

		s = routerOnly(m.section(form.GridSection, 'node', _('Nodes'),
			_('Devices whose radios are managed. A node without host is this device. On each access point, install chanmgr, set its mode to "Access point" and create its login there.')));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add node');
		s.modaltitle = (section_id) => _('Node') + ' » ' + (m.data.get('chanmgr', section_id, 'name') ?? section_id);

		o = nameOption(s, _('Name'), _('Short identifier used in groups, e.g. ap1.'));
		o.placeholder = 'ap1';

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = o.enabled;
		o.editable = true;

		o = s.option(form.Value, 'host', _('Host'), _('Leave empty for this device.'));
		o.datatype = 'host';
		o.placeholder = _('this device');

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.modalonly = true;

		o = s.option(form.Flag, 'https', _('Use HTTPS'));
		o.modalonly = true;

		o = s.option(form.Flag, 'insecure', _('Skip certificate check'));
		o.depends('https', '1');
		o.modalonly = true;

		o = s.option(form.Value, 'username', _('Username'));
		o.placeholder = 'chanmgr';
		o.depends({ host: /.+/ });

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;
		o.modalonly = true;
		o.depends({ host: /.+/ });

		o = s.option(form.Value, 'timeout', _('Timeout (s)'));
		o.datatype = 'range(5,300)';
		o.placeholder = '30';
		o.modalonly = true;

		o = s.option(form.DynamicList, 'lock', _('Locked radios'),
			_('Radios (e.g. radio0) that are measured and avoided by the others but never moved.'));
		o.modalonly = true;

		o = s.option(form.DynamicList, 'exclude', _('Excluded radios'),
			_('Radios that are ignored completely.'));
		o.modalonly = true;

		s = routerOnly(m.section(form.TableSection, 'group', _('Channel groups'),
			_('Radios that must always share a channel, such as the members of an 802.11s mesh. They are moved together. A radio with a mesh interface that is not in a group is never moved.')));
		s.addremove = true;
		s.anonymous = true;
		s.addbtntitle = _('Add group');

		o = nameOption(s, _('Name'));
		o.placeholder = 'mesh5g';

		o = s.option(form.DynamicList, 'member', _('Members'), _('node/radio, e.g. ap1/radio1'));
		o.validate = (section_id, value) => (!value || /^[A-Za-z0-9_]+\/[A-Za-z0-9_]+$/.test(value)) ? true : _('Expecting node/radio');

		return m.render().then((node) => {
			showRole(node, uci.get('chanmgr', 'main', 'role') ?? 'router');

			return node;
		});
	}
});
