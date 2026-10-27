#!/usr/bin/env bash
# One-line-per-step view of a run. Prints each line the runner adds to progress.log
# ("step 03/16: <summary> [next]") and ends on the run's stop line, or when the runner process is gone.
# Made for a log-following tool or a plain terminal: one stdout line per step, and a natural end,
# so a dead runner is never silence.
#   usage: watch.sh <run-id>
#   env:   CHAIN_HOME  CHAIN_WATCH_POLL (seconds, default 5)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
ID=${1:?run-id}
if [ -z "${CHAIN_HOME:-}" ]; then chain_resolve || exit 2; fi
RUN_DIR=$CHAIN_HOME/runs/$ID
F=$RUN_DIR/progress.log
POLL=${CHAIN_WATCH_POLL:-5}
mkdir -p "$RUN_DIR"; touch "$F"

runner_alive() {
  local pid; pid=$(cat "$RUN_DIR/lock/pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}

# A run that already stopped has nothing to follow: show how it ended.
if grep -q "^run $ID stopped:" "$F" && ! runner_alive; then grep "^run $ID stopped:" "$F" | tail -1; exit 0; fi

SEEN=$(wc -l < "$F")
# The runner writes its two "how to watch" lines first, often before this starts: replay the latest pair.
grep "^run $ID watch: " "$F" | tail -2
while :; do
  NOW=$(wc -l < "$F")
  if [ "$NOW" -gt "$SEEN" ]; then
    NEW=$(sed -n "$((SEEN + 1)),${NOW}p" "$F"); SEEN=$NOW
    printf '%s\n' "$NEW"
    printf '%s\n' "$NEW" | grep -q "^run $ID stopped:" && exit 0
  elif ! runner_alive; then
    sleep "$POLL"; [ "$(wc -l < "$F")" -gt "$SEEN" ] && continue   # the runner's last line may be in flight
    echo "run $ID: runner exited without a stop line (see $RUN_DIR/runner.log)"; exit 0
  fi
  sleep "$POLL"
done
