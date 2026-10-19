'use strict';

let fs = require('fs');
let remote = require('chanmgr.remote');

function call(port, password) {
	return remote.client({ host: 'ap', port, username: 'chanmgr', password }).call('chanmgr', 'agent_info', {});
}

return function(t) {
	t.eq(call('80/ok', 'ok'), { data: { hostname: 'ap' } }, 'remote: login + call');
	t.eq(call('80/ok', 'bad'), { error: 'login failed: wrong username or password' }, 'remote: wrong password');
	t.ok(index(call('80/html', 'ok').error, 'did not answer JSON') > 0, 'remote: HTML answer explained');
	t.eq(call('80/noobj', 'ok').status, 4, 'remote: missing chanmgr on node');
	t.eq(length(filter(fs.lsdir('/tmp/chanmgr') ?? [], (f) => index(f, 'rpc.') == 0)), 0, 'remote: temp files removed');
};
