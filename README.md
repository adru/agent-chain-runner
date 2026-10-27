# agent-chain-runner

Run a long task as a chain of short, unattended Claude Code sessions, each one starting fresh and
picking up from a written handoff.

## The problem

One agent session has a limited context window. On a long task (a migration across many files, a
feature with ten parts, a cleanup pass) the session slowly fills up with old tool output and dead ends.
Quality drops, it forgets decisions, and eventually it stops or gets compacted into something vague.

A chain avoids this. Each session does one small, finished piece of work, writes down exactly where it
stopped, and exits. The next session starts clean, reads the notes, and continues. The state lives in
git and in a short handoff file, not in anyone's memory.

## How a step works

You write two files: `RUN.md` (goal, plan, limits, checks) and `HANDOFF.md` (where to start). Then the
runner loops:

1. Create a git worktree on a branch `run/<id>` (once per run).
2. Start `claude -p` in that worktree with a prompt that names `RUN.md`, `HANDOFF.md` and the step
   contract in [STEP.md](STEP.md).
3. The step reads both files, checks `git status` for leftovers from a cut-off predecessor, does one
   unit of work (one atomic commit), rewrites `HANDOFF.md`, and exits.
4. The runner reads the last lines of `HANDOFF.md`:
   - `STATUS: next`: start another step.
   - `STATUS: done`: stop, write the report, remove the worktree (the branch stays).
   - `STATUS: blocked: <question>`: stop and write the report. Answer the question in `HANDOFF.md`
     and run again; the run resumes in the same worktree.
5. Other stop conditions: the step limit, two failed steps in a row, a step that made no commit and left
   the handoff unchanged ("stuck"), or a usage limit that keeps coming back.

The runner itself uses no model tokens. It is a bash script plus a few small Node helpers.

At the end it writes `report.md`: why it stopped, the commits, the files changed, a list of tasks the
steps could not do themselves (the orchestrator log), and optional suggestions for rules or helpers
that would have saved calls (from the friction log).

## The step contract

[STEP.md](STEP.md) is the text every step receives. The main ideas:

- **One unit per step.** One atomic commit's worth of work, sized so it is worth starting a session for.
- **Read git before trusting the handoff.** A step cut off by a usage limit or timeout can leave
  uncommitted changes and a stale handoff. The next step compares `git status` and the diff with the
  handoff, then finishes or discards the change.
- **Commit message through a file.** `git commit -F file`, so there are no quoting accidents and no
  long command text for a permission filter to misread.
- **Never `git stash`, never push.** Stashes are shared across worktrees, and the run branch is for the
  owner to review.
- **Name code by symbol, not line number.** Line numbers in notes go stale in days.
- **Never ask.** A decision that belongs to the owner becomes `STATUS: blocked: <question>`.
- **Two append-only logs.** `orchestrator.md` for work only the outside world can do, `friction.md` for
  anything that cost more than two calls. Steps add lines and never rewrite them.

## Safety choices

- **No push, no merge.** The runner never contacts a remote and never touches your branch. The result is
  a local branch `run/<id>` that you review and merge yourself.
- **Worktree isolation.** Steps work in `.chain/worktrees/run-<id>`, not in your checkout.
- **Per-step settings** (`lib/guard.mjs`): permission rules deny `git push`, `git stash` and
  `git worktree`, and deny reading common credential folders. With the sandbox on, every branch ref
  except the run's own is listed as write-protected (computed from the live refs at each step),
  `objects/pack` is write-protected, and the network allow-list is just the npm registry. Loose git
  objects are packed before each step so a step cannot overwrite them.
- **One runner per run id**, with a pid file (a crashed runner leaves no stuck lock), and a cap on runs
  at once (`CHAIN_MAX_RUNS`, default 3).
- **A lock for heavy work.** `lib/lock.sh` is a small counting lock. Steps take a slot before running
  test suites or builds, so several chains on a small machine do not run them all at once.
- **Time limit per step** (`CHAIN_STEP_TIMEOUT`) and **turn limit** (`CHAIN_MAX_TURNS`).
- State lives in `.chain/` and is kept out of `git status` through `.git/info/exclude`, so your
  tracked files are never edited.

## Usage

Requirements: bash, git with worktree support (tested on 2.34), Node 18 or newer, and the `claude` CLI on your PATH.

```sh
cd your-repo
/path/to/agent-chain-runner/bin/chain init my-task      # scaffolds .chain/runs/my-task/RUN.md and HANDOFF.md
$EDITOR .chain/runs/my-task/RUN.md                      # goal, plan, limits, checks
/path/to/agent-chain-runner/bin/chain run my-task --bg  # detach; or without --bg to stay in the foreground
/path/to/agent-chain-runner/bin/chain watch my-task     # one line per finished step, ends when the run stops
/path/to/agent-chain-runner/bin/chain live my-task      # each step's messages and commands as they happen
/path/to/agent-chain-runner/bin/chain report my-task    # the report, after the run stops
```

Put `bin/` on your PATH to shorten that to `chain ...`. A sample file is in
[examples/RUN.md](examples/RUN.md).

`RUN.md` lines the runner reads: `Base: <branch>` (default: the branch checked out at init),
`Max steps: <n>` (default 20), `Plan: <absolute path>|none`. The rest is for the steps.

When a run ends with `blocked:`, put your answer in `.chain/runs/<id>/HANDOFF.md` (keep the final
`STATUS:` line, set to `next`) and run `chain run <id>` again.

### Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `CHAIN_CLAUDE_CMD` | `claude` | The agent command. Any script that accepts `-p <prompt>` works. |
| `CHAIN_CLAUDE_ARGS` | `--permission-mode acceptEdits --output-format stream-json --verbose` | Extra arguments for each step. |
| `CHAIN_MODEL` | `sonnet` | Model for each step. |
| `CHAIN_MAX_TURNS` | `80` | Turn limit for one step. |
| `CHAIN_MAX_STEPS` | from `RUN.md`, else 20 | Step limit for the run. |
| `CHAIN_STEP_TIMEOUT` | `3600` | Seconds one step may run. |
| `CHAIN_MAX_RUNS` | `3` | Runs allowed at once. |
| `CHAIN_SETUP_CMD` | none | Run once in a new worktree (for example `npm ci`). |
| `CHAIN_ON_STOP` | none | Command run with the report path when the run stops (a notifier). |
| `CHAIN_SUGGEST` | `1` | Set to `0` to skip the end-of-run suggestions session. |
| `CHAIN_SANDBOX` | `1` | Set to `0` to leave the sandbox block out of the step settings. |
| `CHAIN_REPO`, `CHAIN_HOME`, `CHAIN_LOCKS` | repo of the current directory, `<repo>/.chain`, a folder in `$TMPDIR` | Locations. |

## Tests

```sh
bash test/selftest.sh
```

The self-test builds throwaway git repos and runs real chains against a fake agent
(`test/fake-agent.sh`) that edits a file, commits, and rewrites the handoff, the way a real step would.
It checks the commits, the report, the stop conditions (done, step limit, blocked then resumed, stuck,
repeated failure), the locks, and the guard settings, and runs the Node unit tests for the helpers. No
model is called and no network is used. It ends with a line like `Tests: 51 total, 0 failed`.

## Layout

```
bin/chain          command-line entry point (init, run, watch, live, report)
lib/run.sh         the runner loop
lib/watch.sh       one-line progress follower
lib/live.mjs       detailed live view of a step
lib/guard.mjs      builds the per-step settings (permissions, sandbox)
lib/step-summary.mjs  reads a step's transcript: limits, result, refused calls
lib/lock.sh        counting lock
lib/pack-loose.sh  packs loose git objects before a step
lib/suggest.sh     end-of-run suggestions from the friction log
STEP.md            the contract every step receives
examples/RUN.md    a sample run file
test/              self-test, fake agent, helper tests
```

## Limitations

- It was built around the `claude` CLI's headless mode and its stream-json output. The flags and the
  settings format (`--settings`, the sandbox keys) may change between CLI versions; `CHAIN_CLAUDE_ARGS`
  and `lib/guard.mjs` are the places to adjust. The sandbox settings are only exercised against the fake
  agent in the self-test, which ignores them.
- The sandbox is only as strong as the CLI's implementation of it. Run chains on repositories where a
  mistake is recoverable, and review the branch before merging.
- A step is only as good as `RUN.md`. Vague goals produce vague steps. A good plan has units that each
  fit one commit and checks that can actually fail.
- Steps run one at a time. There is no parallelism inside a run.
- The stuck check looks only at commits and the handoff, so a step that rewrites the handoff with
  different text but makes no progress will not be caught until the step limit.
- The usage-limit wait is a fixed delay or the reset time the CLI reports; it does not switch accounts.
- Tested on Linux with bash 5 and git 2.34. macOS needs GNU `md5sum` (or an alias) and `timeout`.

## License

MIT. See [LICENSE](LICENSE).
