// Test stub: in-memory UCI. Tests fill "data" as { config: { section: { ".type", ... } } }.
let data = {};

function cursor() {
	return {
		get_all: (c, s) => data[c]?.[s],
		get: (c, s, o) => (o == null) ? data[c]?.[s]?.['.type'] : data[c]?.[s]?.[o],
		set: (c, s, o, v) => { data[c][s][o] = v; },
		commit: () => true,
		foreach: (c, t, cb) => {
			for (let name, s in data[c] ?? {})
				if (s['.type'] == t)
					cb({ '.name': name, ...s });
		}
	};
}

return { cursor, data };
