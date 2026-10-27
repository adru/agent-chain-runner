#!/usr/bin/env bash
# Chain runner: a long task continues in fresh headless sessions, unattended, one step at a time.
# It uses no model tokens itself. See ../README.md for the design and ../STEP.md for what a step is told.
#
#   usage: run.sh <run-id>          (normally started as `chain run <id>`)
#   needs: <CHAIN_HOME>/runs/<id>/RUN.md and HANDOFF.md (`chain init <id>` writes them)
#   RUN.md lines read by the runner:  "Base: <branch>"  "Max steps: <n>"  "Plan: <absolute path>|none" (optional)
#   env:   CHAIN_CLAUDE_CMD    the agent command (default "claude"); a fake script works for tests
#          CHAIN_CLAUDE_ARGS   extra arguments (default "--permission-mode acceptEdits --output-format stream-json --verbose")
#          CHAIN_MODEL (sonnet)  CHAIN_MAX_TURNS (80)  CHAIN_MAX_STEPS (RUN.md, else 20)
#          CHAIN_STEP_TIMEOUT (seconds a step may run, default 3600)
#          CHAIN_MAX_RUNS (runs at once, default 3)
#          CHAIN_SETUP_CMD    run once in a new worktree (for example "npm ci")
#          CHAIN_ON_STOP      command run with the report path when the run stops (a notifier, for instance)
#          CHAIN_SUGGEST=0    no end-of-run suggestions
#          CHAIN_LIMIT_WAIT   seconds to wait after a usage limit (default 1200)  CHAIN_MAX_LIMIT_WAITS (default 12)
#          CHAIN_REPO  CHAIN_HOME  CHAIN_LOCKS  CHAIN_SANDBOX=0 (see lib/guard.mjs)
#   writes under <CHAIN_HOME>/runs/<id>/: progress.log (one line per step and a final "run <id> stopped: ..."),
#          runner.log, steps/NN.jsonl (each step's transcript), HANDOFF.md, orchestrator.md, friction.md, report.md
#
# This script runs OUTSIDE the step sandbox and is the only part with git write access beyond the run branch.
# It never pushes and never merges: the run branch stays for the owner to review.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
ID=${1:?run-id}
chain_valid_id "$ID" || exit 2
chain_resolve || exit 2

RUN_DIR=$CHAIN_HOME/runs/$ID                   # what the orchestrator writes and reads
WT=$CHAIN_HOME/worktrees/run-$ID
BRANCH=run/$ID
STATE=$WT/.chain-run                           # what the step reads and writes (inside its own tree)
MODEL=${CHAIN_MODEL:-sonnet}
TURNS=${CHAIN_MAX_TURNS:-80}
MAX_RUNS=${CHAIN_MAX_RUNS:-3}
STEP_TIMEOUT=${CHAIN_STEP_TIMEOUT:-3600}
LIMIT_WAIT=${CHAIN_LIMIT_WAIT:-1200}
MAX_LIMIT_WAITS=${CHAIN_MAX_LIMIT_WAITS:-12}
read -ra CMD <<< "${CHAIN_CLAUDE_CMD:-claude}"
read -ra ARGS <<< "${CHAIN_CLAUDE_ARGS:---permission-mode acceptEdits --output-format stream-json --verbose}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/runner.log"; }
progress() { echo "$*" >> "$RUN_DIR/progress.log"; log "$*"; }

[ -f "$RUN_DIR/RUN.md" ] && [ -f "$RUN_DIR/HANDOFF.md" ] || { echo "missing $RUN_DIR/RUN.md or HANDOFF.md (run: chain init $ID)"; exit 2; }
command -v "${CMD[0]}" > /dev/null 2>&1 || { echo "agent command not found: ${CMD[0]} (set CHAIN_CLAUDE_CMD)"; exit 2; }
command -v node > /dev/null 2>&1 || { echo "node is required"; exit 2; }

MAX_STEPS=${CHAIN_MAX_STEPS:-$(sed -n 's/^Max steps: *\([0-9]\+\).*/\1/p' "$RUN_DIR/RUN.md" | head -1)}; MAX_STEPS=${MAX_STEPS:-20}
BASE=$(sed -n 's/^Base: *\([^ ]\+\).*/\1/p' "$RUN_DIR/RUN.md" | head -1)
BASE=${BASE:-$(git -C "$REPO" branch --show-current)}
git -C "$REPO" rev-parse --verify -q "$BASE^{commit}" > /dev/null || { echo "RUN.md Base: '$BASE' is not a branch or commit"; exit 2; }
# A plan outside the repo is named up front, so a step never wastes calls searching for it.
PLAN=$(sed -n 's/^Plan: *\([^ ]\+\).*/\1/p' "$RUN_DIR/RUN.md" | head -1)
case "${PLAN:-none}" in
  none) ;;
  /*) [ -f "$PLAN" ] || { echo "RUN.md Plan: $PLAN does not exist"; exit 2; } ;;
  *) echo "RUN.md 'Plan:' must be an absolute path or 'none'"; exit 2 ;;
esac

# ---- locks: this run once (a pid file, so a crash leaves no stuck lock), and at most MAX_RUNS runs at a time
if [ -d "$RUN_DIR/lock" ]; then
  if kill -0 "$(cat "$RUN_DIR/lock/pid" 2>/dev/null)" 2>/dev/null; then echo "run $ID is already running"; exit 3; fi
  rm -rf "$RUN_DIR/lock"
fi
mkdir "$RUN_DIR/lock" 2>/dev/null || { echo "run $ID is already running"; exit 3; }
echo $$ > "$RUN_DIR/lock/pid"
cleanup() { CHAIN_LOCKS=$LOCKS bash "$HERE/lock.sh" release-all "$ID" > /dev/null 2>&1; rm -rf "$RUN_DIR/lock"; }
trap cleanup EXIT
if ! CHAIN_LOCKS=$LOCKS CHAIN_LOCK_SLOTS=$MAX_RUNS CHAIN_LOCK_WAIT=0 bash "$HERE/lock.sh" take "$ID" run > /dev/null; then
  echo "all $MAX_RUNS run slots are taken"; exit 3
fi
touch "$RUN_DIR/progress.log"
progress "run $ID watch: chain watch $ID   (one line per step)"
progress "run $ID watch: node $HERE/live.mjs $ID   (each step's messages and commands, live)"

# ---- setup, once per run (a blocked run keeps its tree and resumes here without redoing it)
chain_ignore "/.chain/" "/.chain-run/"
if [ ! -d "$WT" ]; then
  progress "run $ID setting up: worktree on $BRANCH off $BASE"
  mkdir -p "$CHAIN_HOME/worktrees"
  if git -C "$REPO" rev-parse --verify -q "refs/heads/$BRANCH" > /dev/null; then
    git -C "$REPO" worktree add -q "$WT" "$BRANCH" || { log "worktree add failed"; exit 4; }
  else
    git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE" || { log "worktree add failed"; exit 4; }
  fi
  if [ -n "${CHAIN_SETUP_CMD:-}" ]; then
    (cd "$WT" && bash -c "$CHAIN_SETUP_CMD") > "$RUN_DIR/setup.log" 2>&1 || { log "setup command failed, see setup.log"; exit 4; }
  fi
  log "setup done"
fi
[ "$(git -C "$WT" branch --show-current)" = "$BRANCH" ] || { log "worktree is not on $BRANCH"; exit 4; }
mkdir -p "$STATE" "$RUN_DIR/steps"
rm -rf "$STATE/bin"; cp -r "$HERE" "$STATE/bin"        # the branch may not carry the runner
cp "$RUN_DIR/RUN.md" "$STATE/RUN.md"
cp "$RUN_DIR/HANDOFF.md" "$STATE/HANDOFF.md"           # the orchestrator's copy wins at (re)start: an answer to "blocked" lives there
for f in orchestrator.md friction.md; do               # same for the two logs (the orchestrator ticks tasks off)
  if [ -f "$RUN_DIR/$f" ]; then cp "$RUN_DIR/$f" "$STATE/$f"; else touch "$STATE/$f"; fi
done
progress "run $ID started: base $BASE, max steps $MAX_STEPS, model $MODEL"

field() { printf '%s' "$SUM" | node "$HERE/step-summary.mjs" --get "$1"; }
STEP_TEMPLATE=$(<"$HERE/../STEP.md")
STEP_TEXT=${STEP_TEMPLATE//\{\{BIN\}\}/$STATE/bin}; STEP_TEXT=${STEP_TEXT//\{\{ID\}\}/$ID}

WEEKLY_START=""; WEEKLY=""; STATUS=""; STOP=""; ERRORS=0; LIMIT_WAITS=0
STEP=$(find "$RUN_DIR/steps" -name '*.jsonl' | wc -l)
while :; do
  [ "$STEP" -ge "$MAX_STEPS" ] && { STOP="max steps ($MAX_STEPS)"; break; }
  N=$(printf '%02d' $((STEP + 1)))
  bash "$HERE/pack-loose.sh" "$COMMON" >> "$RUN_DIR/runner.log" 2>&1 || { STOP="could not pack loose objects"; break; }
  node "$HERE/guard.mjs" "$COMMON" "$ID" "$STATE/settings.json" >> "$RUN_DIR/runner.log" 2>&1 || { STOP="guard.mjs failed"; break; }
  HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD); HANDOFF_BEFORE=$(md5sum < "$STATE/HANDOFF.md")
  CHECK=""; awk -v w="${WEEKLY:-0}" 'BEGIN{exit !(w>=0.95)}' && CHECK=$'\nCHECKPOINT MODE: weekly usage is at or above 95%.'
  PROMPT="RUN.md: $STATE/RUN.md
HANDOFF.md: $STATE/HANDOFF.md
BIN: $STATE/bin
ORCHESTRATOR: $STATE/orchestrator.md
FRICTION: $STATE/friction.md
Run branch: $BRANCH (worktree $WT)$CHECK

$STEP_TEXT"
  log "step $N start (model $MODEL, weekly ${WEEKLY:-?})"
  (cd "$WT" && timeout "$STEP_TIMEOUT" "${CMD[@]}" -p "$PROMPT" "${ARGS[@]}" --settings "$STATE/settings.json" \
     --model "$MODEL" --max-turns "$TURNS" < /dev/null \
     > "$RUN_DIR/steps/$N.jsonl" 2> "$RUN_DIR/steps/$N.stderr")
  EXIT=$?
  SUM=$(node "$HERE/step-summary.mjs" "$RUN_DIR/steps/$N.jsonl")
  WEEKLY=$(field weekly); [ -z "$WEEKLY_START" ] && WEEKLY_START=$WEEKLY

  LIMIT=$(field limit_status)
  if [ -n "$LIMIT" ] && [ "$LIMIT" != "allowed" ]; then
    LIMIT_WAITS=$((LIMIT_WAITS + 1))
    [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ] && { STOP="usage limit still hit after $MAX_LIMIT_WAITS waits"; rm -f "$RUN_DIR/steps/$N.jsonl"; break; }
    RESET=$(field resets_at); NOW=$(date +%s); WAIT=$LIMIT_WAIT
    [[ $RESET =~ ^[0-9]+$ ]] && [ $((RESET - NOW)) -gt 0 ] && [ $((RESET - NOW)) -lt "$WAIT" ] && WAIT=$((RESET - NOW + 30))
    progress "step $N/$MAX_STEPS: hit the $(field limit_type) limit; waiting ${WAIT}s, then retrying"
    rm -f "$RUN_DIR/steps/$N.jsonl"; sleep "$WAIT"; continue
  fi
  STEP=$((STEP + 1))
  printf '%s' "$SUM" | node "$HERE/step-summary.mjs" --refused "$N" >> "$STATE/friction.md"
  for f in HANDOFF.md orchestrator.md friction.md; do cp "$STATE/$f" "$RUN_DIR/$f"; done
  STATUS=$(grep -E '^STATUS: ' "$STATE/HANDOFF.md" | tail -1 | sed 's/^STATUS: //')
  SUMMARY=$(grep -E '^SUMMARY: ' "$STATE/HANDOFF.md" | tail -1 | sed 's/^SUMMARY: //')
  # a handoff the step did not rewrite still carries the previous step's SUMMARY, which would lie
  [ "$(md5sum < "$STATE/HANDOFF.md")" = "$HANDOFF_BEFORE" ] && SUMMARY=""
  [ -z "$SUMMARY" ] && SUMMARY=$(field result_head)
  log "step $N end: exit $EXIT, $(field tool_calls) tool calls, $(field tool_errors) errors, status '${STATUS:-none}'"
  progress "step $N/$MAX_STEPS: ${SUMMARY:-(no summary)} [${STATUS:-no status}]"

  if [ "$EXIT" != 0 ] || [ "$(field is_error)" = "true" ]; then
    # one failed step is retried (the next step reads the git state and the handoff); two in a row stop the run
    ERRORS=$((ERRORS + 1)); [ $ERRORS -ge 2 ] && { STOP="two step errors in a row (last: $(field subtype))"; break; }
    continue
  else ERRORS=0; fi
  if [ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE" ] && [ "$(md5sum < "$STATE/HANDOFF.md")" = "$HANDOFF_BEFORE" ]; then
    STOP="stuck: step $N made no commit and did not change the handoff"; break
  fi
  case "$STATUS" in
    next) continue ;;
    done) STOP="done"; break ;;
    blocked:*) STOP="$STATUS"; break ;;
    *) STOP="no valid STATUS line at the end of HANDOFF.md"; break ;;
  esac
done

# Anything else a step wrote under its state folder (notes, outputs): the worktree is removed on "done".
mkdir -p "$RUN_DIR/run-state"
find "$STATE" -mindepth 1 -maxdepth 1 ! -name bin ! -name settings.json -exec cp -r {} "$RUN_DIR/run-state/" \; 2>/dev/null

# ---- report: the only thing the orchestrator needs to read
{
  echo "# Run $ID: $STOP"
  echo
  echo "- Branch: \`$BRANCH\` off \`$BASE\`; steps ended at $STEP of $MAX_STEPS"
  echo "- Weekly usage: start ${WEEKLY_START:-?}, end ${WEEKLY:-?}"
  echo "- Last handoff status: ${STATUS:-none}"
  echo
  echo "## Commits on the branch"
  git -C "$REPO" log --oneline "$BASE..$BRANCH" | sed 's/^/- /'
  echo
  echo "## Files changed on the branch (read before merging)"
  git -C "$REPO" diff --name-only "$BASE...$BRANCH" | sed 's/^/- /'
  echo
  echo "## Orchestrator tasks (work a step could not do itself)"
  grep -E '^- ' "$STATE/orchestrator.md" || echo "- none"
  echo
  echo "## Suggested rules and helpers (from $(grep -c '^- ' "$STATE/friction.md") friction lines in friction.md)"
  bash "$HERE/suggest.sh" "$STATE/friction.md" 2>&1   # never fails the run
} > "$RUN_DIR/report.md"
progress "run $ID stopped: $STOP"
if [ -n "${CHAIN_ON_STOP:-}" ]; then
  log "on-stop: $(bash -c "$CHAIN_ON_STOP" _ "$RUN_DIR/report.md" 2>&1 | head -1)"   # never fails the run
fi
if [ "$STOP" = "done" ]; then
  git -C "$REPO" worktree remove --force "$WT" && log "worktree removed; branch $BRANCH kept"
fi
