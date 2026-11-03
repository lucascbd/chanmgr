#!/bin/sh
# openwrt-setup.sh - novo x86: usa o disco inteiro e instala os pacotes.
#
#   sh openwrt-setup.sh
#
# 1. aumenta a particao do root ate o fim do disco e reinicia
# 2. depois do reboot continua sozinho: aumenta o sistema de arquivos e
#    instala os pacotes abaixo. Acompanhe com: tail -f /root/openwrt-setup.log

PACKAGES="
	adguardhome apk-mbedtls attendedsysupgrade-common banip base-files bcp38
	bind-dig bind-libs blkid bnx2-firmware busybox ca-bundle cgi-io cloudflared
	collectd collectd-mod-cpu collectd-mod-exec collectd-mod-interface
	collectd-mod-iwinfo collectd-mod-load collectd-mod-memory
	collectd-mod-network collectd-mod-rrdtool collectd-mod-sqm
	collectd-mod-thermal curl ddns-scripts ddns-scripts-cloudflare
	ddns-scripts-services dnsmasq drill dropbear e2fsprogs ethtool firewall4
	fstools fwtool gawk getrandom gre grub2 grub2-bios-setup grub2-efi
	i915-firmware-dmc intel-microcode ip-full iptables-mod-ipopt iptables-nft
	irqbalance iw jansson4 jshn jsonfilter kernel kmod-acpi-video
	kmod-amazon-ena kmod-amd-xgbe kmod-backlight kmod-bnx2 kmod-button-hotplug
	kmod-crypto-crc32c kmod-crypto-hash kmod-crypto-kpp
	kmod-crypto-lib-chacha20 kmod-crypto-lib-chacha20poly1305
	kmod-crypto-lib-curve25519 kmod-crypto-lib-poly1305 kmod-crypto-sha256
	kmod-dma-buf kmod-drm kmod-drm-buddy kmod-drm-display-helper kmod-drm-exec
	kmod-drm-i915 kmod-drm-kms-helper kmod-drm-suballoc-helper kmod-drm-ttm
	kmod-drm-ttm-helper kmod-dwmac-intel kmod-e1000 kmod-e1000e kmod-fb
	kmod-fb-cfb-copyarea kmod-fb-cfb-fillrect kmod-fb-cfb-imgblt
	kmod-fb-sys-fops kmod-fb-sys-ram kmod-forcedeth kmod-fs-vfat kmod-gre
	kmod-gre6 kmod-hwmon-core kmod-i2c-algo-bit kmod-i2c-core kmod-ifb kmod-igb
	kmod-igc kmod-input-core kmod-ip6-tunnel kmod-ipt-core kmod-ipt-ipopt
	kmod-iptunnel kmod-iptunnel6 kmod-ixgbe kmod-lib-crc-ccitt kmod-lib-crc32c
	kmod-libphy kmod-mdio kmod-mdio-devres kmod-mii kmod-nf-conntrack
	kmod-nf-conntrack-netlink kmod-nf-conntrack6 kmod-nf-flow kmod-nf-ipt
	kmod-nf-log kmod-nf-log6 kmod-nf-nat kmod-nf-reject kmod-nf-reject6
	kmod-nfnetlink kmod-nft-compat kmod-nft-core kmod-nft-fib kmod-nft-nat
	kmod-nft-offload kmod-nls-base kmod-nls-cp437 kmod-nls-iso8859-1
	kmod-nls-utf8 kmod-pcs-xpcs kmod-phy-realtek kmod-phylink kmod-ppp
	kmod-pppoe kmod-pppox kmod-pps kmod-ptp kmod-r8169 kmod-sched-cake
	kmod-sched-core kmod-slhc kmod-stmmac-core kmod-tg3 kmod-udptunnel4
	kmod-udptunnel6 kmod-usb-common kmod-usb-core kmod-usb-net
	kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm
	kmod-usb-net-rtl8152 kmod-wireguard libatomic1 libblkid1
	libblobmsg-json20260213 libbpf1 libc libcap libcomerr0 libcurl4 libe2p2
	libelf1 libevent2-7 libexpat libext2fs2 libf2fs6 libgcc1 libiptext-nft0
	libiptext0 libiptext6-0 libiwinfo-data libiwinfo20230701 libjson-c5
	libjson-script20260213 libldns libltdl7 liblua5.1.5 liblucihttp-lua
	liblucihttp-ucode liblucihttp0 libmbedtls21 libmnl0 libmount1 libncurses6
	libnftnl11 libnghttp2-14 libnl-tiny1 libopenssl-conf libopenssl3 libparted
	libpcap1 libpthread libqrencode libreadline8 librrd1 librt libsmartcols1
	libss2 libubox20260213 libubus-lua libubus20251202 libuci20250120
	libuclient20201210 libucode20230711 libudebug libunbound liburcu
	libustream-mbedtls20201210 libuuid1 libuv1 libwebsockets-full libxtables12
	logd losetup lsblk lua luci luci-app-adguardhome
	luci-app-attendedsysupgrade luci-app-banip luci-app-bcp38
	luci-app-cloudflared luci-app-ddns luci-app-firewall luci-app-irqbalance
	luci-app-nlbwmon luci-app-package-manager luci-app-pbr luci-app-sqm
	luci-app-statistics luci-app-ttyd luci-app-unbound luci-app-watchcat
	luci-base luci-lib-base luci-lib-chartjs luci-lib-ip luci-lib-json
	luci-lib-jsonc luci-lib-nixio luci-lib-uqr luci-light luci-lua-runtime
	luci-mod-admin-full luci-mod-network luci-mod-rpc luci-mod-status
	luci-mod-system luci-proto-gre luci-proto-ipv6 luci-proto-ppp
	luci-proto-wireguard luci-ssl luci-theme-bootstrap luci-theme-footstrap
	luci-theme-material luci-theme-openwrt luci-theme-openwrt-2020 mkf2fs mtd
	nano netifd nftables-json nlbwmon odhcp6c odhcpd openssl-util
	openwrt-keyring owut parted partx-utils pbr ppp ppp-mod-pppoe procd
	procd-seccomp procd-ujail px5g-mbedtls qrencode r8152-firmware
	r8169-firmware resize2fs resolveip rpcd rpcd-mod-file rpcd-mod-iwinfo
	rpcd-mod-luci rpcd-mod-rpcsys rpcd-mod-rrdns rpcd-mod-ucode rrdtool1
	sqm-scripts sshpass swap-utils tc-tiny tcpdump terminfo ttyd ubox ubus
	ubusd uci uclient-fetch ucode ucode-mod-fs ucode-mod-html ucode-mod-log
	ucode-mod-lua ucode-mod-math ucode-mod-ubus ucode-mod-uci ucode-mod-uclient
	ucode-mod-uloop uhttpd uhttpd-mod-ubus unbound-anchor unbound-checkconf
	unbound-control unbound-control-setup unbound-daemon unbound-host
	urandom-seed urngd usign watchcat wireguard-tools xtables-nft zlib
"

SELF=/root/openwrt-setup.sh
LOG=/root/openwrt-setup.log
HOOK="sh $SELF --continue >>$LOG 2>&1 &"

log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "ERRO: $*"; exit 1; }

# Particao que contem o root (/ na imagem ext4, /rom na squashfs).
MAJMIN=$(awk '{ for (i = 7; i <= NF; i++) if ($i == "-") { src = $(i + 2); break }
	if (src == "/dev/root") { print $3; exit } }' /proc/self/mountinfo)
PART_SYS=$(readlink -f "/sys/dev/block/$MAJMIN")
[ -e "$PART_SYS/partition" ] || die "nao achei a particao do root"
DISK=$(basename "${PART_SYS%/*}")
PART=$(basename "$PART_SYS")
NUM=$(cat "$PART_SYS/partition")

wait_net() {
	i=0
	until apk update >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -ge 30 ] && die "sem internet"
		sleep 10
	done
}

if [ "$1" != --continue ]; then
	# ---- etapa 1: particao
	[ "$(readlink -f "$0")" = "$SELF" ] || cp "$0" "$SELF"
	wait_net
	apk add parted resize2fs losetup || die "falha ao instalar parted/resize2fs"
	log "aumentando /dev/$PART (particao $NUM de /dev/$DISK) ate o fim do disco"
	# -f corrige o GPT de backup que nao esta no fim do disco novo
	parted -f -s "/dev/$DISK" resizepart "$NUM" 100% || die "parted falhou"
	sed -i "\|$SELF|d" /etc/rc.local
	sed -i "/^exit 0/i $HOOK" /etc/rc.local
	grep -qF "$SELF" /etc/rc.local || echo "$HOOK" >>/etc/rc.local
	log "reiniciando. Depois do boot: tail -f $LOG"
	sync; sleep 2; reboot
	exit 0
fi

# ---- etapa 2 (depois do reboot): sistema de arquivos + pacotes
sed -i "\|$SELF|d" /etc/rc.local
sleep 20

OVL_DEV=$(awk '$2 == "/overlay" { print $1; exit }' /proc/mounts)
case "$OVL_DEV" in
/dev/loop*) FS_DEV=$OVL_DEV ;;   # imagem squashfs: dados no loop do /overlay
*) FS_DEV=/dev/$PART ;;          # imagem ext4
esac
log "aumentando o sistema de arquivos em $FS_DEV"
resize2fs "$FS_DEV" || die "resize2fs falhou (overlay f2fs? use a imagem ext4)"
df -h /

wait_net
log "instalando pacotes"
# shellcheck disable=SC2086
if ! apk add $PACKAGES; then
	log "falhou em lote, instalando um por um"
	FAIL=""
	for p in $PACKAGES; do apk add "$p" >/dev/null 2>&1 || FAIL="$FAIL $p"; done
	[ -n "$FAIL" ] && log "nao instalados:$FAIL"
fi
log "pronto. Reinicie para carregar tudo: reboot"
