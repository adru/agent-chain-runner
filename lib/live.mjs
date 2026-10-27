// Watch a run as it works: each step's own words, each tool call, and a short result.
//
// usage: node live.mjs <run-id> [--all]     (--all: replay every step first, then follow)
// Ctrl-C stops watching; the run is not affected. Reads the step logs and runner log the runner already
// writes under <CHAIN_HOME>/runs/<id>/ and changes nothing. Ends on the run's stop line.
import { execFileSync } from "node:child_process";
import { existsSync, openSync, readSync, readdirSync, readFileSync, fstatSync, closeSync } from "node:fs";
import { basename, join } from "node:path";

const [id, flag] = process.argv.slice(2);
if (!id) { console.error("usage: node live.mjs <run-id> [--all]"); process.exit(2); }

let home = process.env.CHAIN_HOME;
if (!home) {
  const top = execFileSync("git", ["-C", process.env.CHAIN_REPO || process.cwd(), "rev-parse", "--show-toplevel"],
    { encoding: "utf8" }).trim();
  home = join(top, ".chain");
}
const runDir = join(home, "runs", id);
const stepsDir = join(runDir, "steps");
const [GREY, BOLD, GREEN, RED, OFF] = ["\x1b[90m", "\x1b[1m", "\x1b[32m", "\x1b[31m", "\x1b[0m"];

const short = (t, n = 160) => { const s = String(t).split(/\s+/).filter(Boolean).join(" "); return s.length <= n ? s : `${s.slice(0, n - 3)}...`; };

function toolLine(b) {
  const input = b.input || {};
  if (b.name === "Bash") return `$ ${short(input.command || "", 200)}`;
  if (["Read", "Write", "Edit"].includes(b.name)) return `${b.name} ${input.file_path || ""}`;
  return `${b.name} ${short(JSON.stringify(input), 120)}`;
}

function render(line) {
  let e;
  try { e = JSON.parse(line); } catch { return; }
  if (!e || typeof e !== "object") return;
  if (e.type === "result") {
    console.log(`${e.is_error ? RED : GREEN}-- step finished (${e.subtype}, ${e.num_turns} turns)${OFF}`);
    return;
  }
  const content = e.message && e.message.content;
  if (!Array.isArray(content)) return;
  for (const b of content) {
    if (!b || typeof b !== "object") continue;
    if (b.type === "text" && (b.text || "").trim()) console.log(`${BOLD}${b.text.trim()}${OFF}`);
    else if (b.type === "tool_use") console.log(`${GREY}${toolLine(b)}${OFF}`);
    else if (b.type === "tool_result" && b.is_error) {
      const body = typeof b.content === "string" ? b.content : (b.content || []).map((x) => x.text || "").join(" ");
      console.log(`${RED}  error: ${short(body, 140)}${OFF}`);
    }
  }
}

const stopped = () => existsSync(join(runDir, "progress.log"))
  && readFileSync(join(runDir, "progress.log"), "utf8").includes(`run ${id} stopped:`);
const stepFiles = () => (existsSync(stepsDir) ? readdirSync(stepsDir).filter((f) => f.endsWith(".jsonl")).sort() : []);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readFrom(file, pos) {
  const fd = openSync(file, "r");
  const size = fstatSync(fd).size;
  const buf = Buffer.alloc(size - pos);
  readSync(fd, buf, 0, buf.length, pos);
  closeSync(fd);
  const text = buf.toString("utf8");
  const end = text.lastIndexOf("\n") + 1; // only whole lines
  return { lines: text.slice(0, end).split("\n").filter(Boolean), next: pos + Buffer.byteLength(text.slice(0, end)) };
}

const done = new Set();
if (flag !== "--all") for (const f of stepFiles().slice(0, -1)) done.add(f);
let current = null; let pos = 0;
for (;;) {
  const next = stepFiles().find((f) => !done.has(f));
  if (current === null && next) { current = next; pos = 0; console.log(`${BOLD}== step ${basename(current).slice(0, 2)} ==${OFF}`); }
  if (current) {
    const { lines, next: np } = readFrom(join(stepsDir, current), pos);
    pos = np;
    for (const l of lines) { render(l); if (l.includes('"type":"result"')) { done.add(current); current = null; } }
  }
  if (stopped() && !current && !stepFiles().some((f) => !done.has(f))) {
    console.log(`${BOLD}run ended. Report: ${join(runDir, "report.md")}${OFF}`);
    break;
  }
  await sleep(1000);
}
