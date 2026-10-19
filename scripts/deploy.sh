#!/bin/sh
# Copy chanmgr (and optionally the LuCI app) to a device for testing,
# without building packages.
#   scripts/deploy.sh root@192.168.1.1 [--luci]
set -e

[ -n "$1" ] || { echo "usage: $0 user@host [--luci]" >&2; exit 1; }

host=$1
dir=$(cd "$(dirname "$0")/.." && pwd)

# everything but the config, which is only installed when missing
tar -C "$dir/files" --exclude=./etc/config/chanmgr -cf - . | ssh "$host" 'tar -C / -xf -'
ssh "$host" '[ -f /etc/config/chanmgr ] || cat > /etc/config/chanmgr' < "$dir/files/etc/config/chanmgr"

if [ "$2" = "--luci" ]; then
	tar -C "$dir/luci-app-chanmgr/htdocs" -cf - . | ssh "$host" 'tar -C /www -xf -'
	tar -C "$dir/luci-app-chanmgr/root" -cf - . | ssh "$host" 'tar -C / -xf -'
fi

ssh "$host" '
	chmod 755 /usr/sbin/chanmgr /etc/init.d/chanmgr
	for m in fs ubus uci; do
		[ -e /usr/lib/ucode/$m.so ] || echo "missing ucode-mod-$m" >&2
	done
	[ -e /usr/lib/rpcd/ucode.so ] || echo "missing rpcd-mod-ucode" >&2
	command -v iw >/dev/null || echo "missing iw" >&2
	/etc/init.d/rpcd restart
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
	/etc/init.d/chanmgr enable
	/etc/init.d/chanmgr restart
'
echo "deployed to $host"
