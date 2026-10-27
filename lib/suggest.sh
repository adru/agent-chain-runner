#!/usr/bin/env bash
# End-of-run suggestions: one headless session reads the run's friction log (what the steps and the
# runner recorded as costly: refused commands, rediscovered facts, missing helpers) and proposes
# project rules, helpers or changes to the step contract that would have saved it.
# Proposals only: nothing is written. Never fails the run.
#   usage: suggest.sh <friction.md>      prints markdown, always exits 0
#   env:   CHAIN_CLAUDE_CMD (default "claude")  CHAIN_SUGGEST=0 (off)  CHAIN_SUGGEST_MODEL (sonnet)
#          CHAIN_SUGGEST_TIMEOUT (seconds, default 180)
set -uo pipefail
FRICTION=${1:-}
read -ra CMD <<< "${CHAIN_CLAUDE_CMD:-claude}"

[ "${CHAIN_SUGGEST:-1}" = 0 ] && { echo "- skipped: CHAIN_SUGGEST=0"; exit 0; }
[ -s "$FRICTION" ] || { echo "- no friction recorded"; exit 0; }
command -v "${CMD[0]}" > /dev/null 2>&1 || { echo "- skipped: ${CMD[0]} not found"; exit 0; }

PROMPT="You review the friction log of an unattended coding run. Each step ran headless in a sandbox in a git
worktree and appended one line per costly event. Propose at most 5 changes that would have saved the most
calls next time. Each is one of: a project rule (a line for the project's agent instructions), a helper
script, or a change to the step contract (STEP.md).

Only propose what the log shows happened, at least once, with its cost. Skip one-offs that will not recur.

Answer in markdown only, no preamble. One bullet each:
- **<kind>** \`<path>\`: <the exact line or one-sentence content>. Evidence: <which log lines, how many calls>.
If nothing qualifies, answer exactly: - nothing worth a rule or helper

Friction log:
$(head -c 20000 "$FRICTION")"

DIR=$(mktemp -d) || { echo "- skipped: no temp dir"; exit 0; }
trap 'rm -rf "$DIR"' EXIT
(cd "$DIR" && timeout "${CHAIN_SUGGEST_TIMEOUT:-180}" "${CMD[@]}" -p "$PROMPT" --model "${CHAIN_SUGGEST_MODEL:-sonnet}" \
   --max-turns 1 --output-format text < /dev/null > "$DIR/out" 2> "$DIR/err")
RC=$?
if [ "$RC" = 0 ] && [ -s "$DIR/out" ]; then cat "$DIR/out"
else echo "- failed: exit $RC: $(head -c 200 "$DIR/err" | tr '\n' ' ')"; fi
exit 0
