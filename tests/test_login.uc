'use strict';

let uci = require('uci');
let login = require('chanmgr.login');

return function(t) {
	uci.data.rpcd = {
		cfg01: { '.type': 'login', username: 'root', password: '$p$root', read: [ '*' ], write: [ '*' ] }
	};

	t.eq(login.get(), { configured: false }, 'login: none yet');
	t.eq(login.set('root', 'longpassword').ok, false, 'login: root refused');
	t.eq(login.set('chanmgr', 'short').ok, false, 'login: short password refused');
	t.eq(login.set('bad name', 'longpassword').ok, false, 'login: invalid name refused');
	t.eq(uci.data.rpcd.cfg01.read, [ '*' ], 'login: root untouched');

	let r = login.set('chanmgr', 'longpassword');
	t.eq(r, { ok: true, username: 'chanmgr' }, 'login: created');

	let sid = filter(keys(uci.data.rpcd), (k) => uci.data.rpcd[k].username == 'chanmgr')[0];
	let s = uci.data.rpcd[sid];

	t.eq([ s.read, s.write, s.chanmgr ], [ [ 'chanmgr-agent' ], [ 'chanmgr-agent' ], '1' ], 'login: only the agent ACL');
	t.ok(index(s.password, '$1$') == 0, 'login: password hashed');
	t.eq(login.get(), { configured: true, username: 'chanmgr' }, 'login: reported');

	// renaming reuses the same login instead of adding another
	login.set('apagent', 'otherpassword');
	t.eq(length(filter(values(uci.data.rpcd), (x) => x.chanmgr == '1')), 1, 'login: one chanmgr login');
	t.eq(login.get().username, 'apagent', 'login: renamed');

	// a login made by hand following the README is recognised
	uci.data.rpcd = { cfg09: { '.type': 'login', username: 'chanmgr', password: 'x', read: [ 'chanmgr-agent' ], write: [ 'chanmgr-agent' ] } };
	t.eq(login.get(), { configured: true, username: 'chanmgr' }, 'login: manual login recognised');

	// a login used for something else is never taken over
	uci.data.rpcd = { cfg10: { '.type': 'login', username: 'admin', password: 'x', read: [ '*' ], write: [ '*' ] } };
	t.eq(login.set('admin', 'longpassword').ok, false, 'login: foreign login refused');
};
