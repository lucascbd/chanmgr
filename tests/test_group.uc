'use strict';

let ctl = require('chanmgr.controller');

// fake nodes: radios move on 'switch'; "stuck" radios ignore the switch
function nodes(stuck) {
	let chan = { 'a/radio1': 36, 'b/radio1': 36 }, calls = [];
	let h = (node) => ({
		call: (method, args) => {
			let rid = node + '/' + args.radio;

			push(calls, sprintf('%s %s %d', method, rid, args.channel));

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
	t.eq(n.calls, [ 'switch a/radio1 149', 'switch b/radio1 149', 'confirm a/radio1 149', 'confirm b/radio1 149' ], 'group: announce all, then confirm');
	t.eq(length(st.history), 2, 'group: history');

	n = nodes({ 'b/radio1': true });
	st = { history: [] };

	t.ok(!ctl.switch_group(cfg, st, n.handles, u), 'group: failure reported');
	t.eq(n.chan, { 'a/radio1': 36, 'b/radio1': 36 }, 'group: rolled back to 36, members together');
	t.eq(map(st.history, (h) => [ h.rid, h.to, h.ok ]), [
		[ 'b/radio1', 36, true ], [ 'a/radio1', 36, true ],
		[ 'b/radio1', 149, false ], [ 'a/radio1', 149, true ]
	], 'group: history shows failure and rollback');
};
