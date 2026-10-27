// Summarise one step's stream-json log for the runner: usage-limit state, how the step ended, the first
// line of its final message (the progress-line fallback when the handoff has no SUMMARY), and the calls the
// permission layer or the sandbox refused (the runner's own friction evidence, independent of the step).
//
// usage: node step-summary.mjs <step.jsonl>            prints one JSON object
//        node step-summary.mjs --get <field>           reads that JSON on stdin, prints the field ("" if null)
//        node step-summary.mjs --refused <step-no>     reads that JSON on stdin, prints one friction line per refusal
import { existsSync, readFileSync } from "node:fs";

// A refusal, not an ordinary failure: the permission layer said no, or the sandbox blocked a write or read.
const REFUSED = ["Permission for this tool use was denied", "Operation not permitted", "EROFS",
  "read-only file system", "EPERM", "EACCES", "Permission denied"];

const textOf = (c) => (typeof c === "string" ? c
  : Array.isArray(c) ? c.map((b) => (b && b.text) || "").join(" ") : "");

const squash = (s) => String(s).split(/\s+/).filter(Boolean).join(" ");

function describe(call) {
  const input = (call && call.input) || {};
  const what = input.command || input.file_path || JSON.stringify(input).slice(0, 120);
  return `${call && call.name}: ${squash(what).slice(0, 120)}`;
}

export function summarise(text) {
  const out = { limit_status: null, limit_type: null, resets_at: null, weekly: null, five_hour: null,
    is_error: null, subtype: null, turns: null, tool_calls: 0, tool_errors: 0, result_head: "", refused: [] };
  const calls = new Map();
  for (const line of text.split("\n")) {
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (!e || typeof e !== "object") continue;
    if (e.type === "rate_limit_event") {
      const info = e.rate_limit_info || {};
      const w = info.unifiedWindows || {};
      Object.assign(out, { limit_status: info.status ?? null, limit_type: info.rateLimitType ?? null,
        resets_at: info.resetsAt ?? null, weekly: (w.seven_day || {}).utilization ?? null,
        five_hour: (w.five_hour || {}).utilization ?? null });
    } else if (e.type === "result") {
      Object.assign(out, { is_error: e.is_error ?? null, subtype: e.subtype ?? null, turns: e.num_turns ?? null });
      const first = String(e.result || "").split("\n").map((l) => l.trim()).find(Boolean);
      out.result_head = first ? first.slice(0, 160) : "";
    }
    const content = e.message && e.message.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (!b || typeof b !== "object") continue;
      if (b.type === "tool_use") {
        out.tool_calls += 1;
        calls.set(b.id, b);
      } else if (b.type === "tool_result" && b.is_error) {
        out.tool_errors += 1;
        const body = textOf(b.content);
        if (REFUSED.some((r) => body.includes(r)) && out.refused.length < 12) {
          out.refused.push(`${describe(calls.get(b.tool_use_id))} -> ${squash(body).slice(0, 90)}`);
        }
      }
    }
  }
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [a, b] = process.argv.slice(2);
  if (a === "--get" || a === "--refused") {
    const sum = JSON.parse(readFileSync(0, "utf8") || "{}");
    if (a === "--get") {
      const v = sum[b];
      console.log(v === null || v === undefined ? "" : v);
    } else {
      for (const r of sum.refused || []) console.log(`- step ${b} (runner): refused ${r}`);
    }
  } else {
    console.log(JSON.stringify(summarise(a && existsSync(a) ? readFileSync(a, "utf8") : "")));
  }
}
