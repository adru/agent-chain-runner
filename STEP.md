# Chain step contract

You are ONE step of an unattended run. Nobody is watching and nobody can answer a question.
The runner gives you five paths in the first lines of your prompt: the run file (`RUN.md`), the handoff
(`HANDOFF.md`), a helper folder (`BIN`), and two append-only logs (`ORCHESTRATOR` and `FRICTION`).
You have no memory of earlier steps. Everything you know comes from those files and from git.

## Start
1. Read `RUN.md` (goal, plan, limits, checks) and `HANDOFF.md` (where the last step stopped). If RUN.md
   names a plan file by absolute path, read it from there; do not search for it.
2. Run `git status --short`. A step cut off by a usage limit, a timeout or a crash leaves uncommitted
   changes behind, and the handoff may be stale or missing the last thing it did. Read the diff, compare
   it with the handoff, then either finish the change and commit it or discard it. Do not start new work
   on top of an unexplained dirty tree.
3. Name code by symbol, never by line number. Write "the retry loop in `fetchAll`", not "line 214". Line
   numbers go stale within days. If an older note gives a line number, treat it as a hint: search for the
   name and confirm the site before you edit it.

## Do one unit
- One unit is one atomic commit's worth of work: one bug, one feature slice, one refactor. Size it so it
  is worth the cost of starting a fresh session, and no bigger than you can finish and check.
- Write the test first where there is code. A test that was not run is not a test: read the pass count
  from the output before you trust it.
- Commit on the run branch only. Never `--no-verify`. Write the commit message to a file first (with your
  file-writing tool, for example `.chain-run/msg.txt`) and run `git commit -F .chain-run/msg.txt`. A long
  message inline in `-m` is part of the command text, and it is easy to get quoting wrong or to trip a
  command filter on a word inside the message.
- Never `git stash`: stashes are shared with every other worktree of the repository, so a stash from a
  step is lost or applied by the wrong session. Never push, never change a remote, never touch another
  branch, never create or remove worktrees. The sandbox refuses these anyway, and each refusal costs a call.
- Stay inside the limits in RUN.md. If the unit needs something outside them, do not stretch the limits:
  see "Never ask" below.

## Running things
- Keep commands plain: one command per call, literal paths, no loops or inline variable tricks. A command
  the permission layer cannot read is refused, and a refusal can block later commands for the rest of the
  step. For anything with several parts, write a small script file and run that.
- Edit with your file tools, not with `sed -i` or shell redirections.
- Heavy work (full test suites, builds) can exhaust a small machine when several sessions run at once.
  Take a slot first with `bash {{BIN}}/lock.sh take {{ID}}` and give it back right after, in its own
  command, with `bash {{BIN}}/lock.sh release {{ID}}`. Run test tools with one worker.
- RUN.md may list `Known red` failures that already exist on the base. A failure not on that list is yours.

## Two logs that outlive the step (append one line each; never rewrite or reorder them)
- `ORCHESTRATOR`: work only the person or agent outside the sandbox can do, written as an exact action,
  for example `- install the dependency listed in tools.txt` or `- merge branch run/<id> after review`.
  Then carry on. Return `blocked:` only when the next unit cannot start without it.
- `FRICTION`: anything that cost you more than two calls: a refused command and the form that worked, a
  fact you had to rediscover, a helper that was missing, an instruction that misled you. One line:
  `- step <NN>: <what happened>, <calls it cost>; <the rule or helper that would have saved it>`.
  The runner logs refused calls itself; add what it cannot see. At the end of the run these lines are
  turned into suggested rules and helpers.

## Never ask
A decision that belongs to the owner (product choices, wording, a risky change, anything the plan does
not settle) becomes the status `blocked: <one-line question>`. Do not guess it, and do not wait for an
answer. Say in the handoff what you would do for each possible answer, so the next step can start fast.

## End
Rewrite `HANDOFF.md` completely (40 lines at most). It holds: what is done (with commit hashes), what
comes next, anything half-done and where it stands, and test results with their counts. Its
second-to-last line is what this step did, on one line under 120 characters, with the hash if you
committed: `SUMMARY: <what this step did>`. Its LAST line must be exactly one of:
- `STATUS: next` (more units remain)
- `STATUS: blocked: <question for the owner>`
- `STATUS: done` (the goal in RUN.md is met and checked)

The runner stops the chain when a step makes no commit and leaves the handoff unchanged, so a step that
finds nothing to do must still say so in the handoff and end with `STATUS: done` or `STATUS: blocked: ...`.

## Checkpoint mode
If the prompt says CHECKPOINT MODE, usage is nearly exhausted: rewrite `HANDOFF.md` after EVERY commit,
not only at the end, and keep units small, because the session may be cut off at any moment.
