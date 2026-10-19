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

const callApply = rpc.declare({
	object: 'chanmgr',
	method: 'apply'
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
		return callStatus();
	},

	renderSummary(st) {
		const rows = [
			[ _('Last evaluation'), fmtTime(st.last_eval) ],
			[ _('Last utilization sample'), fmtTime(st.last_sample) ],
			[ _('Running'), st.running ? E('em', { 'class': 'spinning' }, st.running) : _('idle') ]
		];

		if (st.last_error)
			rows.push([ _('Last error'), E('span', { 'style': 'color:red' }, st.last_error) ]);

		for (const name in st.nodes ?? {}) {
			const n = st.nodes[name];

			rows.push([
				_('Node %s').format(name),
				n.ok ? '%s – %s'.format(n.hostname || '?', Object.keys(n.radios ?? {}).join(', ') || _('no radios'))
					: E('span', { 'style': 'color:red' }, n.error)
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
					_('Total cost: current %s, best %s (gain %s / %s). Evaluated %s.').format(
						fmtNum(p.current_cost), fmtNum(p.best_cost), fmtNum(p.gain), fmtPct(p.rel), fmtTime(p.ts))
				]),
				table([ _('Radios'), _('Current channel'), _('Planned channel'), _('Locked') ], rows, _('No radios'))
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
				E('h4', _('Best channels')),
				table([ _('Channel'), _('Width'), _('Cost'), _('Neighbors'), _('Utilization'), _('Own APs') ], costs, _('No data')),
				E('details', [
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
		dom.content(root, [
			this.renderSummary(st),
			...this.renderPlans(st),
			...this.renderRadios(st),
			this.renderHistory(st),
			this.renderLog(st)
		]);
	},

	handleEvaluate(ev) {
		return callEvaluate(false).then(() => {
			ui.addNotification(null, E('p', _('Evaluation started. Scanning briefly interrupts Wi-Fi clients; results appear here when done.')), 'info');
		});
	},

	handleApply(ev) {
		if (!confirm(_('Switch the radios to the planned channels now? Clients will follow the channel switch announcement; some may reconnect.')))
			return;

		return callApply().then(() => {
			ui.addNotification(null, E('p', _('Applying the plan, one radio at a time.')), 'info');
		});
	},

	render(st) {
		const root = E('div');

		this.update(root, st);

		poll.add(() => callStatus().then((s) => this.update(root, s)), 10);

		return E([], [
			E('h2', _('Channel Manager')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Measures channel congestion on the configured access points and moves their radios to the least congested channels, coordinating your own access points with each other.')),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleEvaluate') }, _('Evaluate now')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleApply') }, _('Apply plan now'))
			]),
			root
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
