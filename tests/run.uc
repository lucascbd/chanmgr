// Test runner: ucode -L tests/stubs -L files/usr/share/ucode tests/run.uc
'use strict';

let fs = require('fs');
let base = match(sourcepath(), /^(.*)\/[^\/]+$/)[1];
let failed = 0, passed = 0, current = '';

let t = {
	dir: base,
	fixture: (name) => fs.readfile(base + '/fixtures/' + name),
	ok: (cond, name) => {
		if (cond)
			passed++;
		else {
			failed++;
			warn(sprintf('FAIL [%s] %s\n', current, name));
		}
	},
	eq: (got, want, name) => {
		let g = sprintf('%J', got), w = sprintf('%J', want);

		if (g == w)
			passed++;
		else {
			failed++;
			warn(sprintf('FAIL [%s] %s\n  got:  %s\n  want: %s\n', current, name, g, w));
		}
	}
};

t.near = (got, want, name) => t.ok(type(got) in [ 'int', 'double' ] && got - want < 1e-6 && want - got < 1e-6, sprintf('%s (got %J, want %J)', name, got, want));

for (let f in sort(fs.glob(base + '/test_*.uc'))) {
	current = match(f, /([^\/]+)\.uc$/)[1];

	try {
		loadfile(f)()(t);
	}
	catch (e) {
		failed++;
		warn(sprintf('ERROR [%s] %s\n%s\n', current, e.message, e.stacktrace?.[0]?.context ?? ''));
	}
}

print(sprintf('%d passed, %d failed\n', passed, failed));
exit(failed ? 1 : 0);
