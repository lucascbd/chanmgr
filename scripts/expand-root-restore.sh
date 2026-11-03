#!/bin/sh
# expand-root-restore.sh - grow the OpenWrt x86 root to the whole disk, then
# reinstall a package list.
#
# The x86 images (ext4 and squashfs) ship a small root partition, and every
# sysupgrade/reflash writes that small partition table back. Run this right after
# restoring:
#
#   sh expand-root-restore.sh [packages.txt]
#
# It works in stages and remembers nothing: each run looks at the disk and does
# the next step that is still missing, so just run the same command again after
# the reboot.
#
#   1st run: installs parted, grows the root partition to 100 % and reboots
#   2nd run: grows the filesystem (online, no reboot) and installs the packages
#
# The package list is one name per line (# comments allowed). Without an
# argument it uses /etc/backup/installed_packages.txt (written by
# "sysupgrade -k"), or else ./packages.txt. Packages already installed are
# skipped, packages missing from the feeds are reported at the end.
#
# Options:
#   -y   do not ask for confirmation before changing the partition table
#   -n   resize only, do not install packages

set -u

ARGS="$*"
YES=0
INSTALL=1
while getopts yn opt; do
	case "$opt" in
	y) YES=1 ;;
	n) INSTALL=0 ;;
	*) echo "usage: $0 [-y] [-n] [packages.txt]" >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
LIST="${1:-}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

# ---------------------------------------------------------------- package manager

if command -v apk >/dev/null 2>&1; then
	PM=apk
elif command -v opkg >/dev/null 2>&1; then
	PM=opkg
else
	die "neither apk nor opkg found"
fi

PM_UPDATED=0
pm_update() {
	[ "$PM_UPDATED" = 1 ] && return 0
	log "updating package index ($PM)"
	if [ "$PM" = apk ]; then apk update; else opkg update; fi || die "package index update failed (no internet?)"
	PM_UPDATED=1
}

pm_install() {
	if [ "$PM" = apk ]; then apk add "$@"; else opkg install "$@"; fi
}

installed_list() {
	if [ "$PM" = apk ]; then
		sed -n 's/^P://p' /lib/apk/db/installed
	else
		opkg list-installed | cut -d' ' -f1
	fi
}

need_tools() {
	missing=""
	for pair in "$@"; do
		cmd="${pair%%:*}"
		pkg="${pair#*:}"
		command -v "$cmd" >/dev/null 2>&1 || missing="$missing $pkg"
	done
	[ -n "$missing" ] || return 0
	pm_update
	log "installing tools:$missing"
	# shellcheck disable=SC2086
	pm_install $missing || die "could not install:$missing"
}

# ---------------------------------------------------------------- find the root

# The device behind /dev/root: on ext4 images it is mounted at /, on squashfs
# images at /rom. /proc/self/mountinfo: field 3 is major:minor, the source is
# the 2nd field after the "-" separator.
MAJMIN="$(awk '{
	for (i = 7; i <= NF; i++) if ($i == "-") { src = $(i + 2); break }
	if (src == "/dev/root") { print $3; exit }
}' /proc/self/mountinfo)"
[ -n "$MAJMIN" ] || die "could not find /dev/root in /proc/self/mountinfo"

PART_SYS="$(readlink -f "/sys/dev/block/$MAJMIN")"
[ -e "$PART_SYS/partition" ] || die "/dev/root ($MAJMIN) is not a partition"
DISK_SYS="${PART_SYS%/*}"
DISK="$(basename "$DISK_SYS")"
PART="$(basename "$PART_SYS")"
PARTNUM="$(cat "$PART_SYS/partition")"

# Squashfs images keep the writable data in a loop device (offset into the same
# partition) mounted at /overlay.
OVERLAY_DEV="$(awk '$2 == "/overlay" { print $1; exit }' /proc/mounts)"
OVERLAY_FS="$(awk '$2 == "/overlay" { print $3; exit }' /proc/mounts)"
case "$OVERLAY_DEV" in
/dev/loop*) TYPE=squashfs ;;
*) TYPE=ext4 ;;
esac

DISK_SECT="$(cat "$DISK_SYS/size")"
P_START="$(cat "$PART_SYS/start")"
P_SIZE="$(cat "$PART_SYS/size")"
P_END=$((P_START + P_SIZE))
FREE_MB=$(((DISK_SECT - P_END) / 2048))

log "root: /dev/$PART (partition $PARTNUM of /dev/$DISK), image type: $TYPE"
log "disk $((DISK_SECT / 2048)) MiB, partition $((P_SIZE / 2048)) MiB, unused after it: $FREE_MB MiB"

# Never touch the table if another partition comes after the root.
for p in "$DISK_SYS"/"$DISK"*; do
	[ -e "$p/start" ] || continue
	[ "$(cat "$p/start")" -gt "$P_START" ] && die "$(basename "$p") comes after the root partition, will not resize"
done

# ---------------------------------------------------------------- stage 1: partition

# Below 64 MiB left over (GPT backup header, alignment) counts as done.
if [ "$FREE_MB" -ge 64 ]; then
	need_tools parted:parted
	if [ "$YES" != 1 ]; then
		printf 'Grow /dev/%s to the end of /dev/%s and reboot? [y/N] ' "$PART" "$DISK"
		read -r ans
		case "$ans" in y | Y | s | S) ;; *) die "cancelled" ;; esac
	fi
	log "growing partition $PARTNUM to 100 %"
	# -f answers "Fix" to the GPT backup header not being at the end of the disk.
	parted -f -s "/dev/$DISK" resizepart "$PARTNUM" 100% || die "parted failed"
	sync
	log "partition grown. Rebooting - run the same command again afterwards:"
	log "  sh $0 $ARGS"
	sleep 3
	reboot
	exit 0
fi

# ---------------------------------------------------------------- stage 2: filesystem

if [ "$TYPE" = squashfs ]; then
	case "$OVERLAY_FS" in
	ext4) FS_DEV="$OVERLAY_DEV" ;;
	*) die "overlay is $OVERLAY_FS, only ext4 can be grown online. Use the ext4 image, or after this reboot run 'firstboot' to recreate the overlay (erases settings)." ;;
	esac
else
	FS_DEV="/dev/$PART"
fi

need_tools resize2fs:resize2fs
# No -f on purpose: if resize2fs does not see the filesystem as mounted it asks
# for e2fsck and stops, instead of an offline resize of a mounted filesystem.
log "growing filesystem on $FS_DEV (online)"
resize2fs "$FS_DEV" || die "resize2fs failed"
df -h / /overlay 2>/dev/null | awk '!seen[$0]++'

[ "$INSTALL" = 1 ] || { log "done (-n: packages skipped)"; exit 0; }

# ---------------------------------------------------------------- stage 3: packages

if [ -z "$LIST" ]; then
	for f in /etc/backup/installed_packages.txt ./packages.txt /root/packages.txt; do
		[ -s "$f" ] && { LIST="$f"; break; }
	done
fi
[ -n "$LIST" ] && [ -r "$LIST" ] || die "no package list (pass a file: $0 packages.txt)"
log "package list: $LIST"

INST="$(mktemp)"
WANT="$(mktemp)"
trap 'rm -f "$INST" "$WANT"' EXIT
installed_list | sort -u >"$INST"

# First column only; lines marked "rom" by sysupgrade -k are part of the image.
sed 's/#.*//' "$LIST" | awk 'NF && $2 != "rom" { print $1 }' | sort -u | grep -vxF -f "$INST" >"$WANT"

COUNT="$(wc -l <"$WANT")"
if [ "$COUNT" -eq 0 ]; then
	log "all packages are already installed"
	exit 0
fi
log "$COUNT packages to install"

pm_update
# shellcheck disable=SC2046
if pm_install $(cat "$WANT"); then
	log "done"
	exit 0
fi

# One unknown name makes the whole transaction fail: retry one by one.
log "batch install failed, installing one by one"
FAILED=""
while read -r pkg; do
	grep -qxF "$pkg" "$INST" && continue
	pm_install "$pkg" >/dev/null 2>&1 || FAILED="$FAILED $pkg"
	installed_list | sort -u >"$INST"
done <"$WANT"

if [ -n "$FAILED" ]; then
	echo
	echo "Not installed (missing from the feeds or conflicting):"
	for p in $FAILED; do echo "  $p"; done
	exit 1
fi
log "done"
