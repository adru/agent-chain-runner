// Build the per-step Claude Code settings file for an unattended step in a git worktree.
//
// What a step must not do, and what stops it:
//   - push or fetch from a remote: the sandbox network allow-list has no git hosts, and the
//     permission rules deny `git push`, `git stash` and `git worktree`;
//   - read credentials: Read() deny rules for common credential folders (add more with CHAIN_DENY_READ);
//   - move any branch except its own: the sandbox lets a worktree write the shared .git dir, so every
//     other ref path is listed in denyWrite, computed from the LIVE refs at each step;
//   - overwrite existing git objects: objects/pack is denied (the runner packs loose objects first).
//
// usage: node guard.mjs <git-common-dir> <run-id> <out.json>
//   env: CHAIN_SANDBOX=0         omit the sandbox block (machines where the sandbox is unavailable)
//        CHAIN_ALLOWED_DOMAINS   extra comma-separated hosts the sandbox may reach (default: registry.npmjs.org)
//        CHAIN_ALLOWED_PORTS     comma-separated local ports the sandbox may reach (default: none)
//        CHAIN_DENY_READ         extra colon-separated paths the step may not read
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";


const list = (dir) => (existsSync(dir) ? readdirSync(dir) : []);

export function denyWrite(gitDir, runId) {
  const refs = execFileSync("git", ["--git-dir", gitDir, "for-each-ref", "--format=%(refname)"], { encoding: "utf8" })
    .split("\n").filter(Boolean);
  const tops = new Set([...refs.map((r) => r.split("/")[1]), ...list(`${gitDir}/refs`)]);
  tops.delete("heads");
  const deny = [...tops].sort().map((t) => `refs/${t}`);
  const heads = new Set([
    ...refs.filter((r) => r.startsWith("refs/heads/")).map((r) => r.split("/")[2]),
    ...list(`${gitDir}/refs/heads`),
  ]);
  heads.delete("run");
  deny.push(...[...heads].sort().map((h) => `refs/heads/${h}`));
  const mine = `refs/heads/run/${runId}`;
  deny.push(...refs.filter((r) => r.startsWith("refs/heads/run/") && r !== mine));
  deny.push(...list(`${gitDir}/refs/heads/run`).filter((n) => n !== runId).map((n) => `refs/heads/run/${n}`));
  deny.push("packed-refs", "HEAD", "config", "info", "hooks", "objects/pack", "logs/refs/stash");
  return [...new Set(deny.map((p) => `${gitDir}/${p}`))].sort();
}

export function secretPaths() {
  const home = homedir();
  const paths = [".ssh", ".aws", ".config/gh", ".git-credentials", ".netrc", ".npmrc", ".docker",
    ".claude/.credentials.json"].map((p) => `${home}/${p}`);
  for (const p of (process.env.CHAIN_DENY_READ || "").split(":").filter(Boolean)) paths.push(p);
  return paths;
}

function readRule(p) {
  // A leading double slash marks an absolute path in permission rules.
  const isDir = existsSync(p) && statSync(p).isDirectory();
  return isDir ? `Read(/${p}/**)` : `Read(/${p})`;
}

export function buildSettings(gitDir, runId) {
  const settings = {
    env: { GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "gc.auto", GIT_CONFIG_VALUE_0: "0" },
    permissions: {
      deny: ["Bash(git push:*)", "Bash(git stash:*)", "Bash(git worktree:*)", ...secretPaths().map(readRule)],
    },
  };
  if (process.env.CHAIN_SANDBOX !== "0") {
    const domains = ["registry.npmjs.org", ...(process.env.CHAIN_ALLOWED_DOMAINS || "").split(",").filter(Boolean)];
    const ports = (process.env.CHAIN_ALLOWED_PORTS || "").split(",").filter(Boolean).map((p) => `127.0.0.1:${p}`);
    settings.sandbox = {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      network: { allowedDomains: [...domains, ...ports] },
      filesystem: { denyWrite: denyWrite(gitDir, runId) },
    };
  }
  return settings;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [gitDir, runId, out] = process.argv.slice(2);
  if (!gitDir || !runId || !out) {
    console.error("usage: node guard.mjs <git-common-dir> <run-id> <out.json>");
    process.exit(2);
  }
  const settings = buildSettings(gitDir, runId);
  writeFileSync(out, JSON.stringify(settings, null, 1));
  console.log(`guard: ${settings.sandbox ? settings.sandbox.filesystem.denyWrite.length : 0} denyWrite, ` +
    `${settings.permissions.deny.length} permission denies`);
}
