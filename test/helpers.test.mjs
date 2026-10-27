// Unit tests for the Node helpers. Run with: node --test test/
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { summarise } from "../lib/step-summary.mjs";
import { denyWrite } from "../lib/guard.mjs";

const jsonl = (...events) => events.map((e) => JSON.stringify(e)).join("\n");

test("summarise: result head, counts and refusals", () => {
  const s = summarise(jsonl(
    { type: "assistant", message: { content: [
      { type: "tool_use", id: "t1", name: "Bash", input: { command: "sed -i s/a/b/ x.txt" } },
      { type: "tool_use", id: "t2", name: "Bash", input: { command: "git status --short" } },
      { type: "tool_use", id: "t3", name: "Write", input: { file_path: "/w/.hidden/x" } },
      { type: "tool_use", id: "t4", name: "Bash", input: { command: "npm test" } },
    ] } },
    { type: "user", message: { content: [
      { type: "tool_result", tool_use_id: "t1", is_error: true, content: "Permission for this tool use was denied." },
      { type: "tool_result", tool_use_id: "t2", content: "?? x" },
      { type: "tool_result", tool_use_id: "t3", is_error: true, content: [{ type: "text", text: "EROFS: read-only file system" }] },
      { type: "tool_result", tool_use_id: "t4", is_error: true, content: "Exit code 1\nTests: 3 failed" },
    ] } },
    { type: "result", is_error: false, subtype: "success", num_turns: 5, result: "\n\nCommitted the parser fix (abc123).\nSecond line." },
  ));
  assert.equal(s.result_head, "Committed the parser fix (abc123).");
  assert.equal(s.tool_calls, 4);
  assert.equal(s.tool_errors, 3);
  assert.equal(s.refused.length, 2);
  assert.match(s.refused[0], /^Bash: sed -i s\/a\/b\/ x\.txt/);
  assert.match(s.refused[1], /^Write: \/w\/\.hidden\/x/);
  assert.ok(!s.refused.some((r) => r.includes("npm test")), "a failing test is not a refusal");
});

test("summarise: rate limit event and empty input", () => {
  const s = summarise(jsonl({ type: "rate_limit_event", rate_limit_info: {
    status: "rejected", rateLimitType: "five_hour", resetsAt: 123,
    unifiedWindows: { seven_day: { utilization: 0.97 } } } }));
  assert.equal(s.limit_status, "rejected");
  assert.equal(s.weekly, 0.97);
  assert.equal(summarise("").result_head, "");
  assert.deepEqual(summarise("not json\n").refused, []);
});

test("guard: other branches are write-protected, the run's own branch is not", () => {
  const dir = mkdtempSync(join(tmpdir(), "chain-guard-"));
  const git = (...a) => execFileSync("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", ...a], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "f"), "x");
  git("add", "f"); git("commit", "-q", "-m", "init");
  git("branch", "run/mine"); git("branch", "run/other"); git("branch", "feature/x");
  const deny = denyWrite(join(dir, ".git"), "mine");
  const has = (p) => deny.some((d) => d.endsWith(`/.git/${p}`));
  assert.ok(has("refs/heads/main"));
  assert.ok(has("refs/heads/feature"));
  assert.ok(has("refs/heads/run/other"));
  assert.ok(!has("refs/heads/run/mine"), "own branch must stay writable");
  assert.ok(has("objects/pack") && has("packed-refs") && has("HEAD"));
});
