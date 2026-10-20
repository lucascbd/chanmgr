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
	ctl.switch_group({ ...cfg, mesh_method: 'csa' }, st, n.handles, u);
	t.eq(n.calls[0], 'switch a/radio1 149 csa', 'mesh group: csa when configured');

	n = nodes({});
	st = mesh(1);
	t.ok(!ctl.switch_group(cfg, st, n.handles, u), 'mesh group: old agent refused');
	t.eq(n.calls, [], 'mesh group: old agent never touched');
	t.ok(index(st.history[0].msg, 'update chanmgr on a') == 0, 'mesh group: asks to update');

	// guarded switch of mesh radios (agents decide on their own; the
	// controller confirms only when all members are healthy)
	let guarded = (scripts) => {
		let calls = [], idx = {}, confirmed = {}, aborted = {};
		let h = (node) => ({
			call: (method, args) => {
				let rid = node + '/' + args.radio;

				push(calls, method + ' ' + rid);

				if (method == 'guard_start')
					return { data: { ok: true } };

				if (method == 'guard_confirm')
					confirmed[rid] = true;

				if (method == 'guard_abort')
					aborted[rid] = true;

				if (method != 'guard_status')
					return { data: {} };

				let seq = scripts[rid], i = min(idx[rid] ?? 0, length(seq) - 1);

				idx[rid] = (idx[rid] ?? 0) + 1;

				let s = seq[i];

				if (s == 'X')
					return { error: 'no response' };

				if (s == 'waiting_confirm' && confirmed[rid])
					s = 'confirmed';

				if (aborted[rid] && s != 'done' && s != 'failed')
					s = 'rolled_back';

				return { data: { state: s } };
			}
		});

		return { handles: { a: h('a'), b: h('b') }, calls, confirmed, aborted };
	};
	let gcfg = { guard_mesh_timeout: 1, guard_confirm_timeout: 2 };

	// b is unreachable while the mesh moves, then both are healthy
	let g = guarded({
		'a/radio1': [ 'switching', 'waiting_mesh', 'waiting_confirm' ],
		'b/radio1': [ 'X', 'X', 'waiting_mesh', 'waiting_confirm' ]
	});
	st = mesh(3);
	t.ok(ctl.switch_group(gcfg, st, g.handles, u), 'guarded: both confirmed');
	t.eq([ g.confirmed['a/radio1'], g.confirmed['b/radio1'] ], [ true, true ], 'guarded: confirm sent to both');
	t.ok(index(join(',', g.calls), 'guard_confirm a/radio1') > index(join(',', g.calls), 'guard_status b/radio1'), 'guarded: confirm only after b answered');
	t.eq(map(st.history, (x) => [ x.rid, x.ok ]), [ [ 'b/radio1', true ], [ 'a/radio1', true ] ], 'guarded: history');

	// a is healthy, b rolls back: a must be aborted, never confirmed
	g = guarded({
		'a/radio1': [ 'switching', 'waiting_confirm' ],
		'b/radio1': [ 'switching', 'rolling_back', 'rolled_back' ]
	});
	st = mesh(3);
	t.ok(!ctl.switch_group(gcfg, st, g.handles, u), 'guarded: member failure reported');
	t.ok(!g.confirmed['a/radio1'], 'guarded: healthy member not confirmed');
	t.ok(g.aborted['a/radio1'], 'guarded: healthy member sent back');

	// agents that cannot guard are refused
	g = guarded({});
	st = mesh(2);
	t.ok(!ctl.switch_group(gcfg, st, g.handles, u), 'guarded: old agent refused');
	t.eq(g.calls, [], 'guarded: old agent untouched');

	// a width change needs agent level 4
	g = guarded({});
	st = { history: [], nodes: {
		a: { agent: 3, radios: { radio1: { has_mesh: true, width: 40 } } },
		b: { agent: 3, radios: { radio1: { has_mesh: true, width: 40 } } }
	} };
	t.ok(!ctl.switch_group(gcfg, st, g.handles, { ...u, best: { channel: 149, width: 80 } }), 'width change: old agent refused');
	t.ok(index(st.history[0].msg, 'cannot change the channel width') > 0, 'width change: says why');
	t.eq(g.calls, [], 'width change: old agent untouched');
};
