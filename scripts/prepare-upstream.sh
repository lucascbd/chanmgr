#!/bin/sh
# Prepare the two submission commits, one in a clone of your fork of
# openwrt/packages and one in a clone of your fork of openwrt/luci:
#
#   scripts/prepare-upstream.sh <version> <packages-clone> <luci-clone>
#
# Needs: the tag v<version> pushed to GitHub, git user.name (your full name)
# and user.email set, curl or wget, sha256sum, and gettext (msguniq) for
# LuCI's translation template. Commits are signed off (-s) by you; nothing
# is pushed.
set -e

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <version> <packages-clone> <luci-clone>"

version=$1
pkgs=$(cd "$2" && pwd) || die "no such directory: $2"
luci=$(cd "$3" && pwd) || die "no such directory: $3"
repo=$(cd "$(dirname "$0")/.." && pwd)
url=${CHANMGR_TARBALL_URL:-https://codeload.github.com/lucascbd/chanmgr/tar.gz/v$version}

[ -f "$pkgs/net/Makefile" ] || [ -d "$pkgs/net" ] || die "$pkgs does not look like openwrt/packages"
[ -x "$luci/build/i18n-sync.sh" ] || die "$luci does not look like openwrt/luci"

name=$(git config user.name) || die "git user.name is not set"
email=$(git config user.email) || die "git user.email is not set"
case "$name" in *" "*) ;; *) die "git user.name must be your full name (Signed-off-by), not \"$name\"" ;; esac
case "$email" in *noreply*) die "use a real e-mail address, OpenWrt does not accept noreply addresses" ;; esac

grep -q "^PKG_VERSION:=$version\$" "$repo/chanmgr/Makefile" ||
	die "chanmgr/Makefile is not at version $version: set it, commit, tag v$version and push"

command -v msguniq >/dev/null || die "msguniq missing (install gettext)"

# --- source tarball and its hash ---------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
if command -v curl >/dev/null; then
	curl -fsSL -o "$tmp/src.tar.gz" "$url"
else
	wget -q -O "$tmp/src.tar.gz" "$url"
fi || die "download failed: is the tag v$version pushed?"

hash=$(sha256sum "$tmp/src.tar.gz" | cut -d' ' -f1)
echo "PKG_HASH: $hash"

# A new branch from the default branch, or, when the branch exists (pull
# request already open), the same branch rebuilt from its base: one commit,
# to push with --force.
branch() {
	local dir=$1 name=$2 main

	main=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD) || main=origin/master
	if git -C "$dir" rev-parse -q --verify "refs/heads/$name" >/dev/null; then
		git -C "$dir" checkout -q -B "$name" "$(git -C "$dir" merge-base "$main" "$name")"
	else
		git -C "$dir" checkout -q -b "$name" "$main"
	fi
}

# --- openwrt/packages: net/chanmgr ------------------------------------------
branch "$pkgs" chanmgr
rm -rf "$pkgs/net/chanmgr"
mkdir -p "$pkgs/net/chanmgr/files"

# drop the header comment meant for this repository
sed -e '/^# Copy of chanmgr\/Makefile/,/^# (Named Makefile.upstream/d' \
	-e "s|^PKG_VERSION:=.*|PKG_VERSION:=$version|" \
	-e "s|^PKG_HASH:=.*|PKG_HASH:=$hash|" \
	-e "s|^PKG_MAINTAINER:=.*|PKG_MAINTAINER:=$name <$email>|" \
	"$repo/openwrt/net/chanmgr/Makefile.upstream" > "$pkgs/net/chanmgr/Makefile"
cp "$repo/openwrt/net/chanmgr/test.sh" "$pkgs/net/chanmgr/test.sh"
cp "$repo/files/etc/config/chanmgr" "$pkgs/net/chanmgr/files/chanmgr.config"
cp "$repo/files/etc/init.d/chanmgr" "$pkgs/net/chanmgr/files/chanmgr.init"
cp "$repo/files/lib/upgrade/keep.d/chanmgr" "$pkgs/net/chanmgr/files/chanmgr.keep"

git -C "$pkgs" add net/chanmgr
git -C "$pkgs" commit -q -s -F - <<EOF
chanmgr: add new package

Periodic Wi-Fi channel manager. Measures the busy time of the channel
in use all day (survey counters) and of the other channels during
scheduled scans, and moves radios to the channels with the most
estimated capacity, planning several access points together so they
also avoid each other. Recommend-only by default; when applying it
uses channel switch announcements, and a guarded restart with automatic
rollback for radios that carry 802.11s mesh links.
EOF

# --- openwrt/luci: applications/luci-app-chanmgr ------------------------------
branch "$luci" luci-app-chanmgr
rm -rf "$luci/applications/luci-app-chanmgr"
cp -r "$repo/luci-app-chanmgr" "$luci/applications/luci-app-chanmgr"

# inside openwrt/luci the app includes ../../luci.mk directly
sed -i -e '/^# inside openwrt\/luci: /,/^# the luci feed of the build tree$/d' \
	-e 's|^include \$(firstword .*luci\.mk)$|include ../../luci.mk|' \
	-e '/^# In access point mode the router reaches/,/^# (uhttpd-mod-ubus), which the usual/d' \
	-e "s|^PKG_MAINTAINER:=.*|PKG_MAINTAINER:=$name <$email>|" \
	"$luci/applications/luci-app-chanmgr/Makefile"

(cd "$luci" && ./build/i18n-sync.sh applications/luci-app-chanmgr >/dev/null)

git -C "$luci" add applications/luci-app-chanmgr
git -C "$luci" commit -q -s -F - <<EOF
luci-app-chanmgr: add new application

LuCI support for chanmgr, the periodic Wi-Fi channel manager: status
page with the plan per band, the channel options with their estimated
capacity and the change history, and configuration of the router
(controller) or access point role.
EOF

cat <<EOF

Done. Review the commits:
  git -C "$pkgs" show --stat HEAD
  git -C "$luci" show --stat HEAD

Then push the branches to your forks (add --force when the pull request
is already open) and open the pull requests:
  1. chanmgr          -> openwrt/packages (master)
  2. luci-app-chanmgr -> openwrt/luci (master), once 1. is merged
EOF
