// SPDX-License-Identifier: GPL-2.0-only
// Minimal ubus-over-HTTP (JSON-RPC) client for remote agents.

'use strict';

let fs = require('fs');

const NULL_SID = '00000000000000000000000000000000';

function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function post(url, body, opts) {
	// the login request carries the password: keep it in a private directory
	fs.mkdir('/tmp/chanmgr', 0700);

	let tmp = sprintf('/tmp/chanmgr/rpc.%d.%d', time(), rand());

	fs.writefile(tmp, sprintf('%J', body));

	let cmd = sprintf('uclient-fetch -q -T %d -O - --post-file=%s %s%s 2>/dev/null',
		opts.timeout ?? 30, shq(tmp), opts.insecure ? '--no-check-certificate ' : '', shq(url));

	let p = fs.popen(cmd, 'r');
	let out = p ? p.read('all') : null;

	p?.close();
	fs.unlink(tmp);

	return out ? json(out) : null;
}

// node: { host, port, https, insecure, username, password, timeout }
function client(node) {
	let proto = node.https ? 'https' : 'http';
	let url = sprintf('%s://%s%s/ubus', proto, node.host, node.port ? ':' + node.port : '');
	let sid = null, id = 0;

	let rpc = (s, obj, method, args, timeout) => {
		let res;

		try {
			res = post(url, {
				jsonrpc: '2.0', id: ++id, method: 'call',
				params: [ s, obj, method, args ?? {} ]
			}, { timeout: timeout ?? node.timeout, insecure: node.insecure });
		}
		catch (e) {
			return { error: 'invalid response from ' + node.host };
		}

		if (!res)
			return { error: 'no response from ' + node.host };

		if (res.error)
			return { error: res.error.message ?? 'rpc error' };

		if (res.result?.[0] != 0)
			return { error: sprintf('ubus status %d (%s.%s)', res.result?.[0], obj, method) };

		return { data: res.result[1] ?? {} };
	};

	let login = () => {
		let r = rpc(NULL_SID, 'session', 'login', {
			username: node.username ?? 'chanmgr',
			password: node.password ?? '',
			timeout: 900
		}, 15);

		if (r.error)
			return r.error;

		sid = r.data.ubus_rpc_session;

		return sid ? null : 'login failed';
	};

	return {
		call: (obj, method, args, timeout) => {
			if (!sid) {
				let err = login();

				if (err)
					return { error: err };
			}

			let r = rpc(sid, obj, method, args, timeout);

			// session expired: log in again once
			if (r.error && index(r.error, 'ubus status 6') == 0) {
				sid = null;

				let err = login();

				return err ? { error: err } : rpc(sid, obj, method, args, timeout);
			}

			return r;
		}
	};
}

return { client };
