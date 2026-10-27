#!/usr/bin/env bash
# End-to-end self-test. Runs real chains against throwaway git repos with a fake agent
# (test/fake-agent.sh) in place of the claude CLI. No model is called, no network is used.
#   usage: bash test/selftest.sh        prints "Tests: N total, F failed", exits non-zero on a failure
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CHAIN="$ROOT/bin/chain"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not found in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$3] should not be in [$2]" ;; *) ok ;; esac; }

export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=t@example.com
export CHAIN_CLAUDE_CMD="bash $HERE/fake-agent.sh"
export CHAIN_LOCKS="$T/locks" CHAIN_SUGGEST=0 CHAIN_STEP_TIMEOUT=60 CHAIN_WATCH_POLL=1 CHAIN_SANDBOX=0
unset CHAIN_HOME CHAIN_REPO

# A fresh repo with one commit on main; sets R (repo) and cd's into it.
new_repo() {
  R="$T/$1"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q -b main . && echo "hello" > README && git add README && git commit -q -m "initial"
}

# ---------------------------------------------------------------- 1. a three-step chain, followed live
echo "== chain of 3 steps, run in the background and followed with watch"
new_repo happy
export CHAIN_SUGGEST=1
$CHAIN init happy-run --max-steps 6 > "$T/init.out"
has "init says what it created" "$(cat "$T/init.out")" "created"
check "init writes RUN.md" "$(test -f .chain/runs/happy-run/RUN.md && echo yes)" "yes"
check "init writes HANDOFF.md" "$(test -f .chain/runs/happy-run/HANDOFF.md && echo yes)" "yes"
check "init refuses to overwrite" "$($CHAIN init happy-run > /dev/null 2>&1; echo $?)" "2"
check "init rejects a bad id" "$($CHAIN init Bad_ID > /dev/null 2>&1; echo $?)" "2"

FAKE_TOTAL=3 $CHAIN run happy-run --bg > "$T/bg.out"
timeout 90 $CHAIN watch happy-run > "$T/watch.out"; WRC=$?
check "watch exits 0 on the stop line" "$WRC" "0"
W=$(cat "$T/watch.out")
has "watch shows step 1" "$W" "step 01/6: unit 1 appended"
has "watch shows step 3 with status" "$W" "step 03/6: unit 3 appended"
has "watch ends on the stop line" "$(tail -1 "$T/watch.out")" "run happy-run stopped: done"
export CHAIN_SUGGEST=0

check "three commits on the run branch" "$(git log --oneline main..run/happy-run | wc -l | tr -d ' ')" "3"
check "commit subjects come from the message file" "$(git log --format=%s main..run/happy-run | sort -u)" "feat: unit 1 of the job
feat: unit 2 of the job
feat: unit 3 of the job"
check "the branch holds the work" "$(git show run/happy-run:work.txt | tr '\n' ',')" "unit 1,unit 2,unit 3,"
check "main is untouched" "$(git rev-parse main:README)$(git ls-tree --name-only main | tr '\n' ' ')" "$(git rev-parse main:README)README "
check "main working tree stays clean (state is ignored)" "$(git status --short)" ""
check "worktree removed after done" "$(test -d .chain/worktrees/run-happy-run && echo present || echo gone)" "gone"
check "branch kept" "$(git rev-parse --verify -q refs/heads/run/happy-run > /dev/null && echo kept)" "kept"
check "no remote exists" "$(git remote | wc -l | tr -d ' ')" "0"
check "three step transcripts" "$(ls .chain/runs/happy-run/steps/*.jsonl | wc -l | tr -d ' ')" "3"
check "handoff copied back" "$(tail -1 .chain/runs/happy-run/HANDOFF.md)" "STATUS: done"

REPORT=$($CHAIN report happy-run)
has "report title carries the stop reason" "$REPORT" "# Run happy-run: done"
has "report lists the commits" "$REPORT" "feat: unit 3 of the job"
has "report lists changed files" "$REPORT" "- work.txt"
has "report carries the orchestrator task" "$REPORT" "- run the formatter once after unit 2"
has "report counts friction lines" "$REPORT" "from 1 friction lines"
has "report carries suggestions" "$REPORT" "stub suggestion"

# ---------------------------------------------------------------- 2. the step limit
echo "== step limit"
new_repo limit
$CHAIN init limit-run --max-steps 2 > /dev/null
FAKE_TOTAL=99 $CHAIN run limit-run > /dev/null 2>&1
has "stops at the limit" "$(head -1 .chain/runs/limit-run/report.md)" "max steps (2)"
check "two commits, no more" "$(git log --oneline main..run/limit-run | wc -l | tr -d ' ')" "2"
check "worktree kept when not done" "$(test -d .chain/worktrees/run-limit-run && echo present)" "present"

# ---------------------------------------------------------------- 3. blocked, then resumed with an answer
echo "== blocked question, then resume"
new_repo blocked
$CHAIN init blocked-run > /dev/null
FAKE_MODE=blocked $CHAIN run blocked-run > /dev/null 2>&1
has "stops on the question" "$(head -1 .chain/runs/blocked-run/report.md)" "blocked: should the file be called out.txt or work.txt?"
printf '# Handoff\n\nAnswer: work.txt.\n\nSUMMARY: owner answered\nSTATUS: next\n' > .chain/runs/blocked-run/HANDOFF.md
FAKE_TOTAL=1 $CHAIN run blocked-run > /dev/null 2>&1
check "resume finishes the job" "$(head -1 .chain/runs/blocked-run/report.md)" "# Run blocked-run: done"
check "resume reused the same branch" "$(git log --oneline main..run/blocked-run | wc -l | tr -d ' ')" "1"
has "friction from the fake step reached the log" "$(cat .chain/runs/blocked-run/friction.md)" "a note about the allowed form"

# ---------------------------------------------------------------- 4. a step that does nothing
echo "== stuck step"
new_repo stuck
$CHAIN init stuck-run > /dev/null
FAKE_MODE=stuck $CHAIN run stuck-run > /dev/null 2>&1
has "stuck is detected" "$(head -1 .chain/runs/stuck-run/report.md)" "stuck: step 01 made no commit"

# ---------------------------------------------------------------- 5. two failed steps
echo "== two errors in a row"
new_repo fail
$CHAIN init fail-run > /dev/null
FAKE_MODE=fail $CHAIN run fail-run > /dev/null 2>&1
has "two errors stop the run" "$(head -1 .chain/runs/fail-run/report.md)" "two step errors in a row"

# ---------------------------------------------------------------- 6. one runner per run id
echo "== locks"
new_repo locked
$CHAIN init locked-run > /dev/null
mkdir -p .chain/runs/locked-run/lock; echo $$ > .chain/runs/locked-run/lock/pid
$CHAIN run locked-run > "$T/locked.out" 2>&1; LRC=$?
check "second runner is refused" "$LRC" "3"
has "refusal says why" "$(cat "$T/locked.out")" "already running"
echo 999999 > .chain/runs/locked-run/lock/pid
FAKE_TOTAL=1 $CHAIN run locked-run > /dev/null 2>&1
check "a stale lock (dead pid) does not block" "$(head -1 .chain/runs/locked-run/report.md)" "# Run locked-run: done"

export CHAIN_LOCK_SLOTS=1 CHAIN_LOCK_WAIT=0
check "lock take" "$(bash "$ROOT/lib/lock.sh" take a1 test)" "took test.1"
bash "$ROOT/lib/lock.sh" take b2 test > /dev/null; check "lock refuses when full" "$?" "1"
check "release only by the owner" "$(bash "$ROOT/lib/lock.sh" release b2 test)" "b2 holds no test slot"
check "lock release" "$(bash "$ROOT/lib/lock.sh" release a1 test)" "released test.1"
check "lock take again" "$(bash "$ROOT/lib/lock.sh" take b2 test)" "took test.1"
bash "$ROOT/lib/lock.sh" release-all b2
check "release-all frees the slot" "$(bash "$ROOT/lib/lock.sh" take c3 test)" "took test.1"
bash "$ROOT/lib/lock.sh" release-all c3
unset CHAIN_LOCK_SLOTS CHAIN_LOCK_WAIT

# ---------------------------------------------------------------- 7. suggestions through the agent command
echo "== suggestions"
printf -- '- step 01: lost 4 calls on the test command\n' > "$T/friction.md"
check "suggest relays the agent's answer" "$(CHAIN_SUGGEST=1 bash "$ROOT/lib/suggest.sh" "$T/friction.md")" "- **rule** \`AGENTS.md\`: stub suggestion. Evidence: fake."
check "suggest off" "$(CHAIN_SUGGEST=0 bash "$ROOT/lib/suggest.sh" "$T/friction.md")" "- skipped: CHAIN_SUGGEST=0"
: > "$T/empty.md"
check "suggest with no friction" "$(CHAIN_SUGGEST=1 bash "$ROOT/lib/suggest.sh" "$T/empty.md")" "- no friction recorded"

# ---------------------------------------------------------------- 8. guard settings with the sandbox on
echo "== guard"
new_repo guard
git branch run/other
OUT="$T/settings.json"
CHAIN_SANDBOX=1 node "$ROOT/lib/guard.mjs" "$R/.git" mine "$OUT" > /dev/null
S=$(cat "$OUT")
has "denies push" "$S" "Bash(git push:*)"
has "denies other branches" "$S" "/.git/refs/heads/run/other"
has "denies main" "$S" "/.git/refs/heads/main"
hasnt "own branch stays writable" "$S" "refs/heads/run/mine"

# ---------------------------------------------------------------- 9. node unit tests
echo "== node helper tests"
NT=$(cd "$ROOT" && node --test test/helpers.test.mjs 2>&1); NRC=$?
check "node --test passes" "$NRC" "0"
[ "$NRC" != 0 ] && echo "$NT" | tail -30

echo
echo "Tests: $((PASS + FAIL)) total, $FAIL failed"
[ "$FAIL" = 0 ]
