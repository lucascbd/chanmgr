'use strict';

let fs = require('fs');

// "chanmgr version" (the OpenWrt CI looks for it) prints the package version
return function(t) {
	let get = (file, re) => match(fs.readfile(t.dir + '/../' + file) ?? '', re)?.[1];
	let cli = get('files/usr/sbin/chanmgr', /const VERSION = '([^']+)'/);

	t.ok(cli, 'version: set in the CLI');
	t.eq(get('chanmgr/Makefile', /\nPKG_VERSION:=([^\n]+)/), cli, 'version: feed Makefile');
	t.eq(get('openwrt/net/chanmgr/Makefile.upstream', /\nPKG_VERSION:=([^\n]+)/), cli, 'version: upstream Makefile');
};
