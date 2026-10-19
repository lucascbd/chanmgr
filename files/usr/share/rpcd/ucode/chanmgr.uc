// SPDX-License-Identifier: GPL-2.0-only
// ubus object "chanmgr": controller methods for LuCI and agent_* methods
// called by remote controllers.

'use strict';

let fs = require('fs');
let agent = require('chanmgr.agent');
let ctl = require('chanmgr.controller');

// long operations run detached; LuCI polls "status"
function background(cmd) {
	system('/usr/sbin/chanmgr ' + cmd + ' >/dev/null 2>&1 &');

	return { started: true };
}

function wrap(fn) {
	return (req) => {
		try {
			return fn(req.args ?? {});
		}
		catch (e) {
			return { error: e.message };
		}
	};
}

function logread() {
	let p = fs.popen('logread -e chanmgr 2>/dev/null | tail -n 60', 'r');
	let out = p ? p.read('all') : '';

	p?.close();

	return filter(split(out ?? '', '\n'), (l) => length(l));
}

return {
	chanmgr: {
		status: { call: wrap(() => ({ ...ctl.status(), log: logread() })) },
		evaluate: { args: { apply: false }, call: wrap((a) => background(a.apply ? 'evaluate --apply --no-gap' : 'evaluate --dry-run --no-gap')) },
		apply: { args: { band: '' }, call: wrap((a) => background(match(a.band ?? '', /^(2g|5g)$/) ? 'apply ' + a.band : 'apply')) },
		discover: { call: wrap(() => ctl.discover()) },

		agent_info: { call: wrap(() => agent.info()) },
		agent_survey: { call: wrap(() => agent.survey()) },
		agent_scan: { args: { radio: '' }, call: wrap((a) => agent.scan(a.radio)) },
		agent_switch: {
			args: { radio: '', channel: 0, width: 0, bcn_count: 0, nowait: false, reload_fallback: false, method: '' },
			call: wrap((a) => agent.switch_channel(a))
		},
		agent_confirm: { args: { radio: '', channel: 0, timeout: 0 }, call: wrap((a) => agent.confirm(a)) }
	}
};
