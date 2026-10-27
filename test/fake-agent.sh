#!/usr/bin/env bash
# A stand-in for the `claude` CLI, used by the self-test (CHAIN_CLAUDE_CMD="bash test/fake-agent.sh").
# It reads the same prompt a real step gets, does one small unit of work in its working directory
# (the run worktree), commits it, rewrites HANDOFF.md, and prints a stream-json result line.
#
#   FAKE_TOTAL   steps the whole job needs (default 3): the step that reaches it says "STATUS: done"
#   FAKE_MODE    normal (default) | stuck (changes nothing) | blocked (asks a question) | fail (exit 1, is_error)
set -uo pipefail
PROMPT=""
while [ $# -gt 0 ]; do [ "$1" = "-p" ] && { shift; PROMPT=$1; }; shift; done

# the suggestion step is also run through this command: answer it like a model would
case "$PROMPT" in "You review the friction log"*) echo "- **rule** \`AGENTS.md\`: stub suggestion. Evidence: fake."; exit 0 ;; esac

path() { printf '%s\n' "$PROMPT" | sed -n "s/^$1: //p" | head -1; }
HANDOFF=$(path HANDOFF.md); ORCH=$(path ORCHESTRATOR); FRIC=$(path FRICTION)
STATE=$(dirname "$HANDOFF")
MODE=${FAKE_MODE:-normal}; TOTAL=${FAKE_TOTAL:-3}

result() { printf '{"type":"result","subtype":"%s","is_error":%s,"num_turns":3,"result":"%s"}\n' "$1" "$2" "$3"; }

N=$(sed -n 's/^Steps done: //p' "$HANDOFF" | head -1); N=${N:-0}
case "$MODE" in
  stuck) result success false "looked around, found nothing to do"; exit 0 ;;
  fail) result error_during_execution true "the model crashed"; exit 1 ;;
esac

N=$((N + 1))
git status --short > "$STATE/status-at-start.txt"        # proves a step can inspect its tree
if [ "$MODE" = blocked ]; then
  printf '# Handoff\n\nSteps done: %s\nNeed a decision on naming.\n\nSUMMARY: asked about naming\nSTATUS: blocked: should the file be called out.txt or work.txt?\n' "$((N - 1))" > "$HANDOFF"
  echo "- step $N: one refused call, 3 calls; a note about the allowed form" >> "$FRIC"
  result success false "blocked on a question"; exit 0
fi

echo "unit $N" >> work.txt
git add work.txt
printf 'feat: unit %s of the job\n\nAppends one line to work.txt.\n' "$N" > "$STATE/msg.txt"
git commit -q -F "$STATE/msg.txt"
SHA=$(git rev-parse --short HEAD)
[ "$N" = 1 ] && echo "- step 01: guessed the test command, 4 calls; put it in RUN.md Checks" >> "$FRIC"
[ "$N" = 2 ] && echo "- run the formatter once after unit 2" >> "$ORCH"

STATUS="next"; [ "$N" -ge "$TOTAL" ] && STATUS="done"
printf '# Handoff\n\nSteps done: %s\nLast commit: %s\n\nSUMMARY: unit %s appended to work.txt (%s)\nSTATUS: %s\n' \
  "$N" "$SHA" "$N" "$SHA" "$STATUS" > "$HANDOFF"
result success false "Committed unit $N ($SHA)."
