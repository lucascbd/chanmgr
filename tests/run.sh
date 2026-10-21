#!/bin/sh
# Runs the unit tests with a host ucode build. tests/stubs replaces the
# ubus, uci and agent modules, so nothing touches the real system.
#   UCODE=/path/to/ucode UCODE_LIB=/path/to/ucode/build ./tests/run.sh
dir=$(cd "$(dirname "$0")" && pwd)
set -- -L "$dir/stubs" -L "$dir/../files/usr/share/ucode"
[ -n "$UCODE_LIB" ] && set -- "$@" -L "$UCODE_LIB"
PATH="$dir/bin:$PATH"
CHANMGR_RUN_DIR=$(mktemp -d)
CHANMGR_PENDING_DIR=$CHANMGR_RUN_DIR
CHANMGR_PERSIST_DIR=$CHANMGR_RUN_DIR/persist
CHANMGR_GUARD_TICK=50
export CHANMGR_RUN_DIR CHANMGR_PENDING_DIR CHANMGR_PERSIST_DIR CHANMGR_GUARD_TICK
"${UCODE:-ucode}" "$@" "$dir/run.uc"
rc=$?
rm -rf "$CHANMGR_RUN_DIR"
exit $rc
