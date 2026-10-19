'use strict';

let ctl = require('chanmgr.controller');

// fake nodes: radios move on 'switch'; "stuck" radios ignore the switch
function nodes(stuck) {
	let chan = { 'a/radio1': 36, 'b/radio1': 36 }, calls = [];
	let h = (node) => ({
		call: (method, args) => {
			let rid = node + '/' + args.radio;

			push(calls, sprintf('%s %s %d%s', method, rid, args.channel, args.method ? ' ' + args.method : ''));

			if (method == 'switch' && !stuck[rid])
				chan[rid] = args.channel;

			return { data: { ok: (method == 'switch') ? true : chan[rid] == args.channel } };
		}
	});

	return { handles: { a: h('a'), b: h('b') }, chan, calls };
}

return function(t) {
	let cfg = { bcn_count: 10 };
	let u = { id: 'group:mesh', radios: [ 'a/radio1', 'b/radio1' ], current: { channel: 36, width: 40 }, best: { channel: 149, width: 40 } };

	let n = nodes({}), st = { history: [] };

	t.ok(ctl.switch_group(cfg, st, n.handles, u), 'group: both switched');
	t.eq(n.chan, { 'a/radio1': 149, 'b/radio1': 149 }, 'group: both on 149');
	t.eq(n.calls, [ 'switch a/radio1 149 csa', 'switch b/radio1 149 csa', 'confirm a/radio1 149', 'confirm b/radio1 149' ], 'group: announce all, then confirm');
	t.eq(length(st.history), 2, 'group: history');

	n = nodes({ 'b/radio1': true });
	st = { history: [] };

	t.ok(!ctl.switch_group(cfg, st, n.handles, u), 'group: failure reported');
	t.eq(n.chan, { 'a/radio1': 36, 'b/radio1': 36 }, 'group: rolled back to 36, members together');
	t.eq(map(st.history, (h) => [ h.rid, h.to, h.ok ]), [
		[ 'b/radio1', 36, true ], [ 'a/radio1', 36, true ],
		[ 'b/radio1', 149, false ], [ 'a/radio1', 149, true ]
	], 'group: history shows failure and rollback');
	t.eq(filter(n.calls, (c) => index(c, 'switch') == 0 && index(c, ' 36 ') > 0), [ 'switch a/radio1 36 reload', 'switch b/radio1 36 reload' ], 'group: rollback restarts the radios');

	// radios with a mesh interface are restarted, not CSA-switched
	let mesh = (agent) => ({ history: [], nodes: {
		a: { agent, radios: { radio1: { has_mesh: true } } },
		b: { agent, radios: { radio1: { has_mesh: true } } }
	} });

	n = nodes({});
	st = mesh(2);
	t.ok(ctl.switch_group(cfg, st, n.handles, u), 'mesh group: switched');
	t.eq(slice(n.calls, 0, 2), [ 'switch a/radio1 149 reload', 'switch b/radio1 149 reload' ], 'mesh group: restart method');

	n = nodes({});
	st = mesh(2);
	ctl.switch_group({ ...cfg, mesh_method: 'csa' }, st, n.handles, u);
	t.eq(n.calls[0], 'switch a/radio1 149 csa', 'mesh group: csa when configured');

	n = nodes({});
	st = mesh(1);
	t.ok(!ctl.switch_group(cfg, st, n.handles, u), 'mesh group: old agent refused');
	t.eq(n.calls, [], 'mesh group: old agent never touched');
	t.ok(index(st.history[0].msg, 'update chanmgr on a') == 0, 'mesh group: asks to update');
};
