'use strict';
'require view';
'require form';

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

function validateTimes(section_id, value) {
	if (value == null || value == '')
		return true;

	for (const t of value.trim().split(/\s+/))
		if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(t))
			return _('Expecting space-separated times in HH:MM format');

	return true;
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('chanmgr', _('Channel Manager'),
			_('Periodically scans the Wi-Fi channels of the configured nodes and moves their radios to the least congested channels. Start in "recommend only" mode and check the plans on the status page before enabling automatic switching.'));

		s = m.section(form.NamedSection, 'main', 'chanmgr');
		s.tab('general', _('General'));
		s.tab('decision', _('Decision'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable scheduler'),
			_('Samples channel utilization and runs the scheduled evaluations. Manual evaluations work without it.'));

		o = s.taboption('general', form.ListValue, 'mode', _('Mode'));
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
			_('Radios that also carry an 802.11s mesh interface. A channel switch announcement on such a radio is not supported by every driver and can leave the radio down.'));
		o.value('reload', _('Restart the radio (clients reconnect)'));
		o.value('csa', _('Channel switch announcement (experimental)'));
		o.default = 'reload';

		o = s.taboption('advanced', form.Flag, 'reload_fallback', _('Reload Wi-Fi if CSA fails'),
			_('Falls back to "wifi reload", which disconnects all clients of the node.'));

		s = m.section(form.GridSection, 'node', _('Nodes'),
			_('Devices whose radios are managed. A node without host is this device. Remote nodes need the chanmgr package and an rpcd login with the "chanmgr-agent" ACL.'));
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

		s = m.section(form.TableSection, 'group', _('Channel groups'),
			_('Radios that must always share a channel, such as the members of an 802.11s mesh. They are moved together. A radio with a mesh interface that is not in a group is never moved.'));
		s.addremove = true;
		s.anonymous = true;
		s.addbtntitle = _('Add group');

		o = nameOption(s, _('Name'));
		o.placeholder = 'mesh5g';

		o = s.option(form.DynamicList, 'member', _('Members'), _('node/radio, e.g. ap1/radio1'));
		o.validate = (section_id, value) => (!value || /^[A-Za-z0-9_]+\/[A-Za-z0-9_]+$/.test(value)) ? true : _('Expecting node/radio');

		return m.render();
	}
});
