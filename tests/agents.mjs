// Drives the pi extension and the dsh plugin that `onetree render` prints through fake hosts and prints what they did, as one JSON
// object for tests/run.sh to judge. Usage: node --experimental-strip-types tests/agents.mjs <ext.ts> <plugin.mjs> <mirror> <untrusted-main>
// onetree runs as itself (the extension and plugin call the absolute path baked into them); HOME, the registry and the event log are the
// suite's. Every case runs in a fresh host, so nothing one case does leaks into the next.
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
async function load(file, swapOnetree) {   // a copy per load: a fresh module state, and optionally an onetree that is not there (true) or another one (its path)
  const text = readFileSync(file, "utf8");
  const copy = file.replace(/(\.\w+)$/, "-" + n++ + "$1");
  writeFileSync(copy, swapOnetree ? text.replace(onetree, swapOnetree === true ? "/nonexistent/onetree" : swapOnetree) : text);
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
// dsh: calls mapped onto the guard's shapes, judged where they run. The fake host has dsh's two optional services (bare: neither): the
// sandbox policy records grants (and takes one back through the disposer it returns; host.refuse makes it throw for a directory), and the
// working directory is kept per session id, as dsh keeps it across a resume. opts.without names services the profile lacks
async function dsh(opts = {}) {
  const on = {}, grants = [], moves = [], dirs = new Map(), host = { refuse: () => false };
  const mod = await load(plugin, opts.onetree);
  const workingDirectory = {
    get: session => dirs.get(session.header.id) || session.header.cwd,
    ensure: async agent => workingDirectory.get(agent.session),
    set: async (agent, path) => { moves.push([agent.session.header.id, path]); dirs.set(agent.session.header.id, path); return path; },
  };
  const sandboxPolicy = { registerWritableRoot: (session, dir) => {
    if (host.refuse(dir)) throw new Error("the sandbox refuses " + dir);
    const entry = [session.header.id, dir]; grants.push(entry);
    return () => grants.splice(grants.indexOf(entry), 1);
  } };
  const services = opts.bare ? {} : { workingDirectory, sandboxPolicy };
  for (const name of opts.without || []) delete services[name];
  mod.apply({ on: (ev, fn) => (on[ev] = fn), inject: (names, fn) => { if (names.every(name => services[name])) fn(services); } });
  const session = (id, cwd = mirror, more = {}) => {   // a new session object each time, as after a resume
    const injected = [];
    return { session: { header: { cwd, id, ...more } }, injected, inject: m => injected.push({ role: m.role, text: m.content[0].text, plugin: m.source.plugin }) };
  };
  const created = async (agent, source = "startup") => { await on["agent/created"]({ agent, source }); return agent; };
  const call = async (name, args, agent = { session: { header: { cwd: mirror, id: "dsh-1" } } }) => {
    let passed = false;
    const r = await on["tools/pre-execute"]({ name, arguments: args, agent }, async () => { passed = true; return { kind: "allow" }; });
    host.reason = passed ? "" : String(r.reason || "");
    return passed ? "allow" : r.kind;
  };
  return Object.assign(host, { mod, on, call, grants, moves, session, created });
}
const trees = () => spawnSync("git", ["-C", mirror, "worktree", "list", "--porcelain"], { encoding: "utf8" }).stdout.split("\n").filter(l => l.startsWith("worktree ")).length;
const gitDirs = (host, id) => host.grants.filter(g => g[0] === id).map(g => g[1].replace(/^.*\/\.git\//, ".git/")).filter(d => d.startsWith(".git/")).length;
{
  const host = await dsh();
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
  out.dshMissing = await (await dsh({ onetree: true })).call("bash", { command: "ls" });
  // a session whose folder is a worktree is granted that worktree's git folders, once, and gets no worktree, move or message
  const before = trees();
  const inTree = host.session("dsh-wt", worktree);
  await host.call("read", {}, inTree);
  await host.created(inTree, "resume");
  out.dshGrants = host.grants;
  out.dshInTree = { made: trees() - before, moves: host.moves, injected: inTree.injected };
}
// dsh: a session announced in the guarded main checkout gets a worktree, the grants for it, its working directory moved there and one message
{
  const host = await dsh();
  const before = trees();
  const first = await host.created(host.session("dsh-web"));
  const tree = (host.moves[0] || [])[1] || "";
  const about = agent => ({ granted: host.grants.some(g => g[0] === agent.session.header.id && g[1] === tree), gitDirs: gitDirs(host, agent.session.header.id), injected: agent.injected });
  out.dshAuto = {
    made: trees() - before, tree, moves: host.moves.length, ...about(first),
    branch: spawnSync("git", ["-C", tree || mirror, "branch", "--show-current"], { encoding: "utf8" }).stdout.trim(),
    // the guard is sent the working directory: a plain command passes, the same one sent back to the main checkout does not
    plain: await host.call("bash", { command: "git stash" }, first),
    inMain: await host.call("bash", { command: "git stash", workdir: mirror }, first),
  };
  // announced again (a resume: a new session object, the working directory dsh kept): the same worktree, granted again, not moved twice
  const grantsBefore = host.grants.length;
  const again = await host.created(host.session("dsh-web"), "resume");
  out.dshResume = { made: trees() - before, moves: host.moves.length, regranted: host.grants.slice(grantsBefore).some(g => g[1] === tree), injected: again.injected.length, plain: await host.call("bash", { command: "git stash" }, again) };
  // a subagent's session (dsh marks it with origin) starts in its parent's folder: it shares the parent's worktree
  const child = await host.created(host.session("dsh-child", mirror, { parentSession: "dsh-web", origin: "subagent" }));
  out.dshChild = { made: trees() - before, moved: host.moves.slice(1), ...about(child) };
  // a fork can carry its source's id as parentSession too, and is a session of its own: its own worktree
  await host.created(host.session("dsh-fork", mirror, { parentSession: "dsh-web" }));
  const forked = (host.moves.find(m => m[0] === "dsh-fork") || [])[1] || "";
  out.dshFork = { made: trees() - before, own: forked !== "" && forked !== tree, granted: host.grants.some(g => g[0] === "dsh-fork" && g[1] === forked) };
}
// dsh: `auto` fails (here an onetree whose `auto dsh` fails, and is itself in every other call): the session stays, is told why, and is still guarded
{
  const stub = join(process.env.HOME, "onetree-auto-fails");
  writeFileSync(stub, `#!/bin/sh\n[ "$1 $2" = "auto dsh" ] && [ ! -f "${stub}.off" ] && { echo "error: bootstrap failed; rolled back new worktree" >&2; exit 1; }\nexec "${onetree}" "$@"\n`);
  chmodSync(stub, 0o755);
  const host = await dsh({ onetree: stub });
  const before = trees();
  const agent = await host.created(host.session("dsh-fails"));
  out.dshFails = { made: trees() - before, moves: [...host.moves], grants: [...host.grants], injected: [...agent.injected], plain: await host.call("bash", { command: "git stash" }, agent) };
  writeFileSync(stub + ".off", "");   // auto works again: the session, granted nothing so far, is announced once more
  await host.created(agent, "clear");
  const tree = (host.moves[0] || [])[1] || "";
  out.dshFails.retry = { moves: host.moves.length, granted: host.grants.filter(g => g[1] === tree).length, gitDirs: gitDirs(host, "dsh-fails") };
}
// dsh: a profile with neither service: the worktree is made and the session told to name it; calls are judged in the session's folder
{
  const host = await dsh({ bare: true });
  const before = trees();
  const agent = await host.created(host.session("dsh-bare"));
  const tree = (/has its own worktree, ([^,]+),/.exec((agent.injected[0] || {}).text || "") || [])[1] || "";
  out.dshBare = { made: trees() - before, tree, injected: agent.injected, plain: await host.call("bash", { command: "git stash" }, agent), inTree: await host.call("bash", { command: "git stash", workdir: tree }, agent) };
}
// dsh: a session is moved only into a worktree its sandbox is open to. While the grants cannot be made (codex-grants fails, or lists nothing,
// or the sandbox refuses one directory) it stays, holds no partial grant and is told why; the next tool call tries again, and then it moves
{
  const flag = join(process.env.HOME, "codex-grants-mode"), stub = join(process.env.HOME, "onetree-grants-fail");
  writeFileSync(stub, `#!/bin/sh\nif [ "$1" = codex-grants ] && [ -f "${flag}" ]; then [ "$(cat "${flag}")" = empty ] && exit 0; "${onetree}" "$@"; exit 1; fi\nexec "${onetree}" "$@"\n`);
  chmodSync(stub, 0o755);
  const stuck = async (id, close, open) => {
    const host = await dsh({ onetree: stub });
    close(host);
    const agent = await host.created(host.session(id));
    const before = { moves: host.moves.length, grants: host.grants.length, injected: agent.injected.map(m => m.text), plain: await host.call("bash", { command: "git stash" }, agent) };
    // not moved, so a read in the main checkout runs; a call sent into the closed worktree is refused with the reason, not left to the sandbox
    const closed = (/worktree, ([^,]+), could not be opened/.exec(before.injected[0] || "") || [])[1] || "";
    before.read = await host.call("bash", { command: "ls" }, agent);
    before.inTree = [await host.call("bash", { command: "ls", workdir: closed }, agent), host.reason];
    open(host);
    const after = await host.call("bash", { command: "git stash" }, agent);
    const tree = (host.moves[0] || [])[1] || "";
    return { before, after, tree, moves: host.moves.length, granted: host.grants.filter(g => g[1] === tree).length, gitDirs: gitDirs(host, id), all: host.grants.length };
  };
  out.dshClosed = {
    fails: await stuck("dsh-grants-fail", () => writeFileSync(flag, "fail"), () => rmSync(flag)),
    empty: await stuck("dsh-grants-empty", () => writeFileSync(flag, "empty"), () => rmSync(flag)),
    refused: await stuck("dsh-grant-refused", host => { host.refuse = dir => dir.endsWith("/objects"); }, host => { host.refuse = () => false; }),
  };
}
// dsh: a resumed session's working directory is still in its worktree, and its grants are gone: while they cannot be made again every call
// there is refused with the reason (a read too: nothing runs in a worktree that is not open), and the first call after they can be passes
{
  const flag = join(process.env.HOME, "codex-grants-mode");
  const host = await dsh({ onetree: join(process.env.HOME, "onetree-grants-fail") });
  await host.created(host.session("dsh-resume-closed"));
  const tree = (host.moves[0] || [])[1] || "";
  writeFileSync(flag, "fail");
  const agent = await host.created(host.session("dsh-resume-closed"), "resume");
  const held = host.grants.length;
  out.dshResumeClosed = {
    tree, injected: agent.injected.map(m => m.text),
    bash: [await host.call("bash", { command: "git status" }, agent), host.reason],
    read: await host.call("read", { file_path: "README.md" }, agent),
    newGrants: host.grants.length - held,
  };
  rmSync(flag);
  out.dshResumeClosed.after = await host.call("bash", { command: "git stash" }, agent);
  out.dshResumeClosed.granted = host.grants.length - held;
}
// dsh: a profile with no sandbox policy has no sandbox to open: the session is moved all the same
{
  const host = await dsh({ without: ["sandboxPolicy"] });
  const agent = await host.created(host.session("dsh-no-sandbox"));
  out.dshNoSandbox = { moves: host.moves.length, grants: host.grants.length, plain: await host.call("bash", { command: "git stash" }, agent) };
}
process.stdout.write(JSON.stringify(out) + "\n");
