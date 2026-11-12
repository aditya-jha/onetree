// Drives the pi extension and the dsh plugin that `onetree render` prints through fake hosts and prints what they did, as one JSON
// object for tests/run.sh to judge. Usage: node --experimental-strip-types tests/agents.mjs <ext.ts> <plugin.mjs> <mirror> <untrusted-main>
// onetree runs as itself (the extension and plugin call the absolute path baked into them); HOME, the registry and the event log are the
// suite's. Every case runs in a fresh host, so nothing one case does leaks into the next.
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [ext, plugin, mirror, untrusted] = process.argv.slice(2);
const onetree = /const ONETREE = "([^"]+)"/.exec(readFileSync(ext, "utf8"))[1];
const out = {};
let n = 0;

function sh(args, env = {}) {
  const r = spawnSync(onetree, args, { encoding: "utf8", env: { ...process.env, ...env } });
  return String(r.stdout || "").trim();
}
async function load(file, swapOnetree) {   // a copy per load: a fresh module state, and optionally an onetree that is not there
  const text = readFileSync(file, "utf8");
  const copy = file.replace(/(\.\w+)$/, "-" + n++ + "$1");
  writeFileSync(copy, swapOnetree ? text.replace(onetree, "/nonexistent/onetree") : text);
  return import(pathToFileURL(copy).href);
}
async function pi(opts = {}) {
  const on = {}, entries = [];
  (await load(ext, opts.missing)).default({ on: (ev, fn) => (on[ev] = fn), appendEntry: (t, d) => entries.push({ type: "custom", customType: t, data: d }) });
  on.session_start({}, { cwd: mirror, sessionManager: { getBranch: () => opts.branch || [] } });
  const call = (toolName, input) => {
    const event = { toolName, input: { ...input } };
    const r = on.tool_call(event, { cwd: mirror });
    return { input: event.input, blocked: !!(r && r.block), reason: (r && r.reason) || "" };
  };
  return { on, entries, call };
}

// pi: a session that ran onetree new follows its worktree; the guard sees the rewritten call
{
  const host = await pi();
  const before = host.call("bash", { command: "git stash" });
  const worktree = sh(["new", "pi-follow", mirror], { ONETREE_SESSION_PID: String(process.pid), ONETREE_HOST: "pi" });
  host.on.tool_result({ toolName: "bash", input: { command: "onetree new pi-follow" }, isError: false });
  out.pi = {
    worktree,
    before,
    entries: host.entries,
    bash: host.call("bash", { command: "echo hi > notes.md" }),
    write: host.call("write", { path: "src/a.ts" }),
    absolute: host.call("edit", { path: join(mirror, "README.md") }),
    read: host.call("read", { path: "README.md" }),
  };
}
// pi: /resume restores the worktree from the session's own entries
{
  const host = await pi({ branch: [{ type: "custom", customType: "onetree-worktree", data: { path: out.pi.worktree } }] });
  out.piResumed = host.call("bash", { command: "ls" });
}
// pi: without onetree a call is refused, as before
{
  const host = await pi({ missing: true });
  out.piMissing = host.call("bash", { command: "ls" });
}
// pi: worktrees of a trusted main are trusted; the main itself, a review checkout and an untrusted main's worktree are left to pi
{
  const review = sh(["review", "main", mirror]);
  const other = sh(["new", "pi-untrusted", untrusted]);
  mkdirSync(join(process.env.HOME, ".pi", "agent"), { recursive: true });
  writeFileSync(join(process.env.HOME, ".pi", "agent", "trust.json"), JSON.stringify({ [mirror]: true, [untrusted]: false }));
  const host = await pi();
  out.trust = [out.pi.worktree, mirror, review, other].map(cwd => host.on.project_trust({ type: "project_trust", cwd }).trusted);
}
// dsh: calls mapped onto the guard's shapes, judged where they run; the session hint injected at start
async function dsh(missing) {
  const on = {};
  const mod = await load(plugin, missing);
  mod.apply({ on: (ev, fn) => (on[ev] = fn) });
  const agent = { session: { header: { cwd: mirror, id: "dsh-1" } } };
  const call = async (name, args) => {
    let passed = false;
    const r = await on["tools/pre-execute"]({ name, arguments: args, agent }, async () => { passed = true; return { kind: "allow" }; });
    return passed ? "allow" : r.kind;
  };
  return { mod, on, agent, call };
}
{
  const host = await dsh(false);
  const worktree = out.pi.worktree;
  out.dsh = {
    shapes: [["bash", { command: "ls", workdir: "w" }], ["write", { file_path: "f" }], ["edit", { file_path: "f" }],
      ["str_replace_editor", { command: "undo_edit", path: "f" }], ["str_replace_editor", { command: "view", path: "f" }], ["read", { file_path: "f" }]]
      .map(([t, a]) => host.mod.shape(t, a)),
    verdicts: [
      await host.call("bash", { command: "git stash" }),
      await host.call("bash", { command: "npm test", workdir: worktree }),
      await host.call("write", { file_path: join(mirror, "README.md") }),
      await host.call("str_replace_editor", { command: "create", path: join(worktree, "new.ts") }),
      await host.call("read", { file_path: join(mirror, "README.md") }),
    ],
  };
  const injected = [];
  host.on["agent/session-start"]({ agent: { ...host.agent, inject: m => injected.push(m) }, source: "startup" });
  out.dshHint = injected.map(m => ({ role: m.role, text: m.content[0].text, plugin: m.source.plugin }));
  out.dshMissing = await (await dsh(true)).call("bash", { command: "ls" });
}
process.stdout.write(JSON.stringify(out) + "\n");
