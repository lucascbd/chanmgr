'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require ui';

const callStatus = rpc.declare({
	object: 'chanmgr',
	method: 'status',
	expect: { }
});

const callEvaluate = rpc.declare({
	object: 'chanmgr',
	method: 'evaluate',
	params: [ 'apply' ]
});

const callLocal = rpc.declare({
	object: 'chanmgr',
	method: 'local_status',
	expect: { }
});

const callApply = rpc.declare({
	object: 'chanmgr',
	method: 'apply',
	params: [ 'band' ]
});

const ACTIONS = {
	keep: _('Keep current channels'),
	wait: _('Waiting for confirmation'),
	hold: _('On hold'),
	switch: _('Switching'),
	recommend: _('Change recommended'),
	applied: _('Applied'),
	failed: _('Failed')
};

const BANDS = { '2g': '2.4 GHz', '5g': '5 GHz' };

const GUARD = {
	none: '-',
	starting: _('starting'),
	switching: _('switching'),
	waiting_mesh: _('waiting for the mesh'),
	waiting_confirm: _('waiting for the router'),
	confirmed: _('confirmed, watching the mesh'),
	rolling_back: _('going back'),
	done: _('switched'),
	rolled_back: _('went back'),
	failed: _('failed')
};

// spacing that does not depend on the theme
const ROW = 'display:flex;flex-wrap:wrap;gap:.5em;margin:.5em 0 1.5em 0';

function fmtCap(v) {
	return (v != null) ? '%.2f'.format(v) : '-';
}

function fmtGain(v) {
	return (v != null) ? '%s%.0f%%'.format(v >= 0 ? '+' : '', v * 100) : '-';
}

function fmtData(o, days) {
	if (!o)
		return '-';

	// same 6 h of grace as the controller
	return (o.days >= days - 0.25)
		? _('%d samples, ready').format(o.samples)
		: _('%d samples, %.1f of %d days').format(o.samples, o.days, days);
}

function warnText(text) {
	return E('span', { 'style': 'color:#c00' }, text);
}

function fmtTime(ts) {
	return ts ? new Date(ts * 1000).toLocaleString() : '-';
}

function fmtChan(s) {
	return s ? '%d (%d MHz)'.format(s.channel, s.width) : '-';
}

function fmtNum(v) {
	return (v != null) ? '%.2f'.format(v) : '-';
}

function fmtPct(v) {
	return (v != null) ? '%.0f%%'.format(v * 100) : '-';
}

function table(headers, rows, empty) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, h))),
		...(rows.length ? rows.map((r) => E('tr', { 'class': 'tr' }, r.map((c) => E('td', { 'class': 'td' }, c))))
			: [ E('tr', { 'class': 'tr placeholder' }, E('td', { 'class': 'td', 'colspan': headers.length }, E('em', empty))) ])
	]);
}

return view.extend({
	load() {
		return callStatus().then((st) => (st.scheduler?.role == 'ap')
			? callLocal().then((ap) => ({ ap }))
			: st);
	},

	renderScheduler(sc) {
		if (!sc)
			return '-';

		if (!sc.enabled)
			return _('off (enable it under Configuration to evaluate automatically)');

		if (!sc.running)
			return warnText(_('enabled but not running: run "/etc/init.d/chanmgr restart" on this device'));

		return '%s, %s · %s'.format(_('running'),
			sc.next_eval ? _('next evaluation %s').format(fmtTime(sc.next_eval)) : _('no evaluation times set'),
			(sc.mode == 'apply') ? _('applies changes automatically') : _('recommends only'));
	},

	renderAp(ap) {
		const info = ap.info ?? {}, rows = [];
		const changes = ap.changes ?? [];
		const how = { csa: _('switch announcement'), restart: _('radio restart'), guarded: _('guarded restart'), group: _('group switch') };
		const fmtChange = (c) => c ? E([], [
			'%s → %s%s'.format(c.from ?? '?', c.to, c.width ? ' (%d MHz)'.format(c.width) : ''),
			E('div', { 'style': 'font-size:90%' }, [
				fmtTime(c.ts), ' · ', c.ok ? _('ok') : warnText(_('went back or failed')), c.msg ? ' – ' + c.msg : ''
			])
		]) : '-';

		for (const radio of Object.keys(info.radios ?? {}).sort()) {
			const r = info.radios[radio], g = ap.guards?.[radio] ?? {};
			const busy = g.state && g.state != 'none' && !['done', 'rolled_back', 'failed'].includes(g.state);

			rows.push([
				radio, BANDS[r.band] ?? r.band, fmtChan(r),
				(r.ifaces ?? []).map((i) => '%s (%s)'.format(i.ifname, i.mode)).join(', '),
				busy ? E('em', { 'class': 'spinning' }, GUARD[g.state] ?? g.state) : fmtChange(changes.find((c) => c.radio == radio))
			]);
		}

		for (const radio of Object.keys(info.down ?? {}).sort())
			rows.push([ radio, '-', warnText(_('down')), info.down[radio], fmtChange(changes.find((c) => c.radio == radio)) ]);

		const hist = changes.map((c) => [
			fmtTime(c.ts), c.radio, '%s → %s'.format(c.from ?? '?', c.to), c.width ? '%d MHz'.format(c.width) : '-',
			how[c.how] ?? c.how ?? '-', c.ok ? _('ok') : warnText(_('failed')), c.msg || ''
		]);

		return E([], [
			E('h2', _('Channel Manager')),
			E('div', { 'class': 'cbi-map-descr' },
				_('This device is an access point managed by a router running chanmgr. The router decides the channels; this page shows what it changed here.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Overview')),
				table([ _('Item'), _('Value') ], [
					[ _('Host name'), info.hostname ?? '-' ],
					[ _('Login for the router'), ap.login?.configured
						? _('"%s" is configured').format(ap.login.username)
						: warnText(_('not configured: set it under Configuration')) ]
				], '')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Radios')),
				table([ _('Radio'), _('Band'), _('Channel'), _('Interfaces'), _('Last change') ], rows, _('No radios'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Channel changes')),
				table([ _('Time'), _('Radio'), _('Channel'), _('Width'), _('How'), _('Result'), _('Details') ], hist,
					_('No changes since the last reboot'))
			])
		]);
	},

	renderSummary(st) {
		const rows = [
			[ _('Scheduler'), this.renderScheduler(st.scheduler) ],
			[ _('Last evaluation'), fmtTime(st.last_eval) ],
			[ _('Last utilization sample'), fmtTime(st.last_sample) ],
			[ _('Running'), st.running ? E('em', { 'class': 'spinning' }, st.running) : _('idle') ]
		];

		if (st.last_error)
			rows.push([ _('Last error'), warnText(st.last_error) ]);

		for (const name in st.nodes ?? {}) {
			const n = st.nodes[name];

			const down = Object.keys(n.down ?? {}).map((r) => E('div', {}, warnText('%s: %s'.format(r, n.down[r]))));

			rows.push([
				_('Node %s').format(name),
				n.ok ? E([], [ '%s – %s'.format(n.hostname || '?', Object.keys(n.radios ?? {}).join(', ') || _('no radios')), ...down ])
					: warnText(n.error)
			]);
		}

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Overview')),
			table([ _('Item'), _('Value') ], rows, '')
		]);
	},

	renderPlans(st) {
		const out = [];

		for (const band of Object.keys(st.plans ?? {}).sort()) {
			const p = st.plans[band];
			const rows = p.units.map((u) => {
				const changed = u.best && (u.best.channel != u.current?.channel || u.best.width != u.current?.width);

				return [
					u.radios.join(', '),
					fmtChan(u.current),
					changed ? E('strong', fmtChan(u.best)) : fmtChan(u.best),
					u.locked ? E('em', u.locked) : '-'
				];
			});

			out.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Plan for %s').format(BANDS[band] ?? band)),
				E('p', [
					E('strong', ACTIONS[p.action] ?? p.action), ' – ', p.reason, E('br'),
					(p.metric == 'capacity')
						? _('Total capacity: current %s, best %s (gain %s). Channel and width chosen together. Evaluated %s.').format(
							fmtCap(p.current_value), fmtCap(p.best_value), fmtGain(p.rel), fmtTime(p.ts))
						: _('Total cost: current %s, best %s (gain %s / %s). Evaluated %s.').format(
							fmtNum(p.current_cost), fmtNum(p.best_cost), fmtNum(p.gain), fmtPct(p.rel), fmtTime(p.ts))
				]),
				table([ _('Radios'), _('Current channel'), _('Planned channel'), _('Locked') ], rows, _('No radios')),
				(p.metric == 'capacity')
					? E('p', { 'style': 'font-size:90%' }, _('Capacity: how much the devices could transmit, where 1.00 is a completely free 20 MHz channel and a free 80 MHz channel is 4.00. It comes from the busy time measured on each channel over the last days; while there are few measurements, the neighbors heard on the channel stand in for them.'))
					: '',
				(p.key && p.action != 'applied')
					? E('div', { 'style': ROW }, E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'handleApply', band)
					}, _('Apply %s plan now').format(BANDS[band] ?? band)))
					: ''
			]));
		}

		if (!out.length)
			out.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Plan')),
				E('p', E('em', _('No evaluation yet. Press "Evaluate now" or wait for the next scheduled run.')))
			]));

		return out;
	},

	renderRadios(st) {
		const out = [];

		for (const rid of Object.keys(st.radios ?? {}).sort()) {
			const r = st.radios[rid];
			const costs = (r.costs ?? []).map((c) => [
				'%d'.format(c.channel) + (c.current ? ' ' + _('(current)') : '') + (c.best ? ' ' + _('(planned)') : ''),
				'%d MHz'.format(c.width),
				E('strong', fmtNum(c.cost)),
				fmtNum(c.ext),
				fmtPct(c.util),
				fmtNum(c.own)
			]);
			const neigh = (r.neighbors ?? []).map((n) => [
				n.ssid || E('em', _('hidden')), n.bssid, '%d'.format(n.channel), '%d MHz'.format(n.width), '%d dBm'.format(n.signal)
			]);

			out.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', '%s – %s, %s, %s'.format(rid, BANDS[r.band] ?? r.band, fmtChan(r), _('utilization %s').format(fmtPct(r.util)))),
				E('h4', { 'style': 'margin:1em 0 .6em 0' }, _('Best channels')),
				r.options
					? table([ _('Channel'), _('Width'), _('Capacity'), _('Busy'), _('Data') ],
						r.options.map((o) => [
							'%d'.format(o.channel) + (o.current ? ' ' + _('(current)') : '') + (o.best ? ' ' + _('(planned)') : ''),
							'%d MHz'.format(o.width),
							E('strong', fmtCap(o.capacity)),
							fmtPct(o.busy),
							fmtData(o, st.plans?.[r.band]?.history_days ?? 3)
						]), _('No data'))
					: table([ _('Channel'), _('Width'), _('Cost'), _('Neighbors'), _('Utilization'), _('Own APs') ], costs, _('No data')),
				E('details', { 'data-key': rid, 'style': 'margin-bottom:1.5em' }, [
					E('summary', _('Neighbor networks (%d)').format(neigh.length)),
					table([ _('SSID'), _('BSSID'), _('Channel'), _('Width'), _('Signal') ], neigh, _('No neighbors seen'))
				])
			]));
		}

		return out;
	},

	renderHistory(st) {
		const rows = (st.history ?? []).map((h) => [
			fmtTime(h.ts), h.rid, '%s → %s'.format(h.from ?? '?', h.to), h.width ? '%d MHz'.format(h.width) : '-',
			h.ok ? _('ok') : E('span', { 'style': 'color:red' }, _('failed')), h.msg || ''
		]);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Channel changes')),
			table([ _('Time'), _('Radio'), _('Channel'), _('Width'), _('Result'), _('Details') ], rows, _('No changes yet'))
		]);
	},

	renderLog(st) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Log')),
			E('pre', { 'style': 'white-space:pre-wrap;max-height:20em;overflow:auto' },
				(st.log ?? []).length ? st.log.join('\n') : _('No log messages'))
		]);
	},

	update(root, st) {
		// polling: only redraw when something changed, and keep the scroll
		// position and the expanded neighbor lists
		const json = JSON.stringify(st);

		if (json == this.lastState)
			return;

		this.lastState = json;

		const scroll = window.scrollY;
		const open = new Set(Array.from(root.querySelectorAll('details[open]'), (d) => d.dataset.key));

		dom.content(root, [
			this.renderSummary(st),
			...this.renderPlans(st),
			...this.renderRadios(st),
			this.renderHistory(st),
			this.renderLog(st)
		]);

		root.querySelectorAll('details').forEach((d) => d.open = open.has(d.dataset.key));
		window.scrollTo(window.scrollX, scroll);
	},

	handleEvaluate(ev) {
		return callEvaluate(false).then(() => {
			ui.addNotification(null, E('p', _('Evaluation started. Scanning briefly interrupts Wi-Fi clients; results appear here when done.')), 'info');
		});
	},

	handleApply(band, ev) {
		const question = band
			? _('Switch the %s radios to the planned channels now? The other band is not touched. Clients follow the channel switch announcement; some may reconnect.').format(BANDS[band] ?? band)
			: _('Switch the radios to the planned channels now? Clients will follow the channel switch announcement; some may reconnect.');

		if (!confirm(question))
			return;

		return callApply(band || '').then(() => {
			ui.addNotification(null, E('p', _('Applying the plan, one radio at a time.')), 'info');
		});
	},

	render(st) {
		if (st.ap) {
			const root = E('div', {}, this.renderAp(st.ap));

			poll.add(() => callLocal().then((ap) => dom.content(root, this.renderAp(ap))), 10);

			return root;
		}

		const root = E('div');

		this.update(root, st);

		poll.add(() => callStatus().then((s) => this.update(root, s)), 10);

		return E([], [
			E('h2', _('Channel Manager')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Measures channel congestion on the configured access points and moves their radios to the least congested channels, coordinating your own access points with each other.')),
			E('div', { 'style': ROW }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleEvaluate') }, _('Evaluate now')),
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleApply', '') }, _('Apply plan now'))
			]),
			root
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
