// Test stub: in-memory UCI. Tests fill "data" as { config: { section: { ".type", ... } } }.
let data = {};

function cursor() {
	return {
		get_all: (c, s) => data[c]?.[s],
		get: (c, s, o) => (o == null) ? data[c]?.[s]?.['.type'] : data[c]?.[s]?.[o],
		set: (c, s, o, v) => { data[c][s][o] = v; },
		commit: () => true,
		add: (c, type) => {
			let sid = sprintf('cfg%06x', length(keys(data[c] ?? {})) + 0x100);

			data[c] ??= {};
			data[c][sid] = { '.type': type };

			return sid;
		},
		foreach: (c, t, cb) => {
			for (let name, s in data[c] ?? {})
				if (s['.type'] == t)
					cb({ '.name': name, ...s });
		}
	};
}

return { cursor, data };
