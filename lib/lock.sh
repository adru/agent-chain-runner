#!/usr/bin/env bash
# Counting lock built from mkdir, which is atomic. Used by the runner to cap concurrent runs and by
# steps to cap heavy work (test suites, builds) that must not run twice at once on a small machine.
#
#   lock.sh take <id> [name]     take a free slot of <name> (default "test"); waits up to CHAIN_LOCK_WAIT seconds
#   lock.sh release <id> [name]  release the slot this id holds for <name>
#   lock.sh release-all <id>     release every slot this id holds (the runner calls this when it stops)
#
#   env: CHAIN_LOCKS (folder)  CHAIN_LOCK_SLOTS (slots per name, default 2)
#        CHAIN_LOCK_WAIT (seconds, default 1800; 0 = try once)  CHAIN_LOCK_POLL (seconds, default 5)
# Exit codes: 0 done, 1 no slot free in time, 2 usage.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
if [ -z "${CHAIN_LOCKS:-}" ]; then LOCKS=${TMPDIR:-/tmp}/agent-chain-locks-$(id -u); else LOCKS=$CHAIN_LOCKS; fi

CMD=${1:-}; ID=${2:-}; NAME=${3:-test}
SLOTS=${CHAIN_LOCK_SLOTS:-2}; WAIT=${CHAIN_LOCK_WAIT:-1800}; POLL=${CHAIN_LOCK_POLL:-5}
[ -n "$ID" ] || { echo "usage: lock.sh take|release|release-all <id> [name]"; exit 2; }
mkdir -p "$LOCKS"

try_take() {
  local n
  for n in $(seq "$SLOTS"); do
    if mkdir "$LOCKS/$NAME.$n" 2>/dev/null; then
      echo "$ID $$ $(date +%H:%M:%S)" > "$LOCKS/$NAME.$n/owner"
      echo "took $NAME.$n"; return 0
    fi
  done
  return 1
}

case "$CMD" in
  take)
    tries=$((WAIT / POLL))
    for i in $(seq 0 "$tries"); do
      try_take && exit 0
      [ "$i" -lt "$tries" ] && sleep "$POLL"
    done
    echo "no $NAME slot free after ${WAIT}s: $(cat "$LOCKS"/"$NAME".*/owner 2>/dev/null | tr '\n' ';')"
    exit 1 ;;
  release)
    for d in "$LOCKS/$NAME".*; do
      [ -f "$d/owner" ] && [ "$(cut -d' ' -f1 "$d/owner")" = "$ID" ] && { rm -rf "$d"; echo "released ${d##*/}"; exit 0; }
    done
    echo "$ID holds no $NAME slot" ;;
  release-all)
    for d in "$LOCKS"/*.*; do
      [ -f "$d/owner" ] && [ "$(cut -d' ' -f1 "$d/owner")" = "$ID" ] && rm -rf "$d"
    done ;;
  *) echo "usage: lock.sh take|release|release-all <id> [name]"; exit 2 ;;
esac
