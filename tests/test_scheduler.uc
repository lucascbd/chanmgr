'use strict';

let fs = require('fs');
let uci = require('uci');
let ctl = require('chanmgr.controller');

return function(t) {
	let cfg = { eval_times: [ '02:30', '04:30', 'bad', '25:00' ] };
	let now = time(), lt = localtime(now);
	let midnight = now - lt.hour * 3600 - lt.min * 60 - lt.sec;
	let at = (h, m, s) => midnight + h * 3600 + m * 60 + (s ?? 0);

	t.eq(ctl.due_slot(cfg, at(2, 29), 0), null, 'scheduler: nothing before 02:30');
	t.eq(ctl.due_slot(cfg, at(2, 30), 0)?.name, '02:30', 'scheduler: due at 02:30');
	t.eq(ctl.due_slot(cfg, at(2, 33, 40), 0)?.name, '02:30', 'scheduler: still due after a slow sample (minute missed)');
	t.eq(ctl.due_slot(cfg, at(2, 35), at(2, 31)), null, 'scheduler: not again once evaluated');
	t.eq(ctl.due_slot(cfg, at(3, 31), 0), null, 'scheduler: slot expires after an hour');
	t.eq(ctl.due_slot(cfg, at(4, 30), at(2, 31))?.name, '04:30', 'scheduler: second slot');
	t.eq(ctl.due_slot(cfg, at(2, 40), at(2, 10))?.name, '02:30', 'scheduler: earlier manual evaluation does not cancel the slot');

	t.eq(ctl.next_slot(cfg, at(1, 0)), at(2, 30), 'scheduler: next is 02:30');
	t.eq(ctl.next_slot(cfg, at(3, 0)), at(4, 30), 'scheduler: next is 04:30');
	t.eq(ctl.next_slot(cfg, at(5, 0)), at(2, 30) + 86400, 'scheduler: next is tomorrow 02:30');
	t.eq(ctl.next_slot({ eval_times: [] }, at(5, 0)), null, 'scheduler: no slots');

	// one real round of the service loop (stub agent): must not crash, must
	// write the heartbeat the status page reads, and must run a due slot
	let run = getenv('CHANMGR_RUN_DIR');
	let hm = (ts) => sprintf('%02d:%02d', localtime(ts).hour, localtime(ts).min);

	uci.data.chanmgr = {
		main: { '.type': 'chanmgr', enabled: '1', eval_times: hm(time() - 60), scan_gap: '0', apply_gap: '0' },
		local: { '.type': 'node' }
	};
	fs.unlink(run + '/state.json');

	let ctx = ctl.daemon_tick({ last_sample: 0, failed: {} });
	let hb = json(fs.readfile(run + '/daemon.json') ?? 'null');

	t.ok(hb?.pid > 0 && hb?.ts > 0, 'scheduler tick: heartbeat written');
	t.ok(ctl.status().last_eval > 0, 'scheduler tick: due slot evaluated');
	t.ok(ctl.status().scheduler.running, 'scheduler tick: reported as running (pid alive)');

	let before = ctl.status().last_eval;
	ctl.daemon_tick(ctx);
	t.eq(ctl.status().last_eval, before, 'scheduler tick: slot not run twice');
};
