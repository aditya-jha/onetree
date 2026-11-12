import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Snapshot, WorktreeRow } from "./types.ts";
import { agentAction, agentsAttention, agentsView, decisions, doctorFixes, doctorGroups, fleet, guardView, headsUp, healthView, isDesktopController, mainState, repoLabel, stateOf, GROUP_ORDER, GUARD_RULES, SESSION_STALE_S } from "./derive.ts";
import type { Agent } from "./types.ts";
import { ago, homeOf, isPlaceholder, shorten } from "./format.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const snap = JSON.parse(readFileSync(path.join(here, "..", "..", "fixtures", "snapshot.json"), "utf8")) as Snapshot;
const worktrees = snap.repos.flatMap((r) => r.worktrees);

function row(over: Partial<WorktreeRow>): WorktreeRow {
  return {
    path: "/Users/you/worktrees/shop/x",
    repo: "shop",
    main: "/Users/you/src/shop",
    kind: "worktree",
    slug: "x",
    branch: "feature/x",
    detached: false,
    head: "a".repeat(40),
    dirty: 0,
    unpushed: 0,
    pr: { state: "NONE", head: null },
    lock: null,
    live: 0,
    gc: { action: "keep", code: "young", reason: "no merged PR and younger than 24h" },
    ...over,
  };
}

test("stateOf reads each gc verdict as a person would", () => {
  assert.deepEqual(stateOf(row({ gc: { action: "would-remove", code: "pr-merged", reason: "" }, pr: { state: "MERGED", head: "x" } })), { label: "Merged · gc removes next run", tone: "auto" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "live", reason: "" }, pr: { state: "MERGED", head: "x" }, live: 1 })), { label: "Merged · held by session", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "live", reason: "" }, live: 2 })), { label: "Working", tone: "ok" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "live", reason: "" }, live: 2, branch: "feature/claude-260917-162554" })), { label: "Working · placeholder branch", tone: "ok" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "dirty", reason: "" }, dirty: 1 })), { label: "Stalled · no PR, nobody inside", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "dirty", reason: "" }, dirty: 1, pr: { state: "MERGED", head: "x" } })), { label: "Merged · uncommitted change", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "keep-file", reason: "f differs from g" } })), { label: "Keep-file drift", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "pr-open", reason: "" }, pr: { state: "OPEN", head: "x" } })), { label: "PR open", tone: "ok" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "young", reason: "" }, detached: true, branch: null })), { label: "Review checkout · expires", tone: "auto" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "not-merged", reason: "" }, pr: { state: "CLOSED", head: "x" } })), { label: "PR closed, not merged", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "not-merged", reason: "" }, detached: true, branch: null, unpushed: 1 })), { label: "Detached · commits live only here", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "would-remove", code: "review", reason: "" }, detached: true, branch: null })), { label: "Review checkout, read · gc removes next run", tone: "auto" });
  assert.deepEqual(stateOf(row({ gc: { action: "would-remove", code: "pr-closed", reason: "" }, pr: { state: "CLOSED", head: "x" } })), { label: "PR closed · gc removes next run", tone: "auto" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "not-merged", reason: "" } })), { label: "Stalled · pushed, no PR", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "not-merged", reason: "" }, unpushed: 1 })), { label: "Stalled · unpushed, no PR", tone: "decide" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "locked", reason: "LOCKED: hands off" }, lock: "LOCKED: hands off" })), { label: "Locked", tone: "muted" });
  assert.deepEqual(stateOf(row({ gc: { action: "keep", code: "foreign", reason: "made by the Codex app, which removes it itself" } })), { label: "Made by the Codex app, which removes it itself", tone: "muted" });
  for (const w of worktrees) assert.ok(stateOf(w).label.length > 0, w.path);
});

test("a fork clone's Open PR names the canonical repo, the integration branch and the fork's owner", () => {
  const withStalled = () => {   // pushed, no PR, nobody inside, past the stale window
    const s = structuredClone(snap);
    const r = s.repos.find((x) => x.info.repo === "shop-agent")!;
    r.worktrees.push(row({ repo: "shop-agent", main: r.main.path, path: `${r.info.worktreeDir}/stuck`, slug: "stuck", branch: "feature/stuck", gc: { action: "keep", code: "not-merged", reason: "" } }));
    return s;
  };
  const stalledIn = (s: Snapshot) => decisions(s).find((d) => d.group === "stalled" && d.slug === "stuck")!;
  const open = (s: Snapshot) => stalledIn(s).actions.find((a) => a.label === "Open PR")!.command!;
  const plain = withStalled();
  for (const r of plain.repos) delete r.info.remotes;
  assert.equal(open(plain), "gh pr create --head feature/stuck --fill");
  const forked = withStalled();
  const r = forked.repos.find((x) => x.info.repo === "shop-agent")!;
  r.info.remotes = {
    base: { name: "upstream", source: "upstream-convention", slug: "Shop-Co/shop-agent" },
    push: { name: "origin", source: "default", slug: "you_shop/shop-agent" },
    ghUser: { login: null, source: "default" },
    ignoredFromFile: [],
  };
  assert.equal(open(forked), `gh pr create --repo Shop-Co/shop-agent --base ${r.info.integration} --head you_shop:feature/stuck --fill`);
  assert.match(stalledIn(forked).actions.find((a) => a.label === "Remove worktree")!.confirm!, /stays on origin\.$/);
  r.main.behind = 4;
  assert.match(fleet(forked).repos.find((x) => x.repo.info.repo === "shop-agent")!.mainState.label, /4 behind upstream$/);
});

test("decisions never offer a remove that loses work they claim to keep", () => {
  const one = (w: Partial<WorktreeRow>) => decisions({ ...snap, repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/w", slug: "w", repo: "shop", branch: "feature/w", ...w })] }] })[0]!;
  const stalled = one({ unpushed: 1, gc: { action: "keep", code: "not-merged", reason: "" } });
  assert.deepEqual([stalled.reason, stalled.actions.map((a) => a.label)], ["1 commit on no remote, no PR, nobody inside, older than the stale window.", ["Push & open PR", "Discard & remove", "Keep"]]);
  const dirty = [0, 1, null].map((unpushed) => one({ dirty: 2, unpushed, gc: { action: "keep", code: "dirty", reason: "" } }));   // no patch action: a patch can't hold a staged version beside the working copy
  assert.deepEqual(dirty.map((d) => [d.actions.map((a) => a.label), d.actions.find((a) => a.label === "Discard & remove")!.confirm]), [
    [["Show diff", "Discard & remove", "Keep"], "Discard 2 uncommitted paths in w and remove it? Nothing is saved."],
    [["Show diff", "Discard & remove", "Keep"], "Discard 2 uncommitted paths and 1 unpushed commit in w and remove it? Nothing is saved."],
    [["Show diff", "Discard & remove", "Keep"], "Discard 2 uncommitted paths and any unpushed commits in w and remove it? Nothing is saved."],
  ]);
});

test("mainState says what a person needs to know about a main checkout", () => {
  const m = snap.repos[0]!.main;
  assert.equal(mainState({ ...m, guard: true, behind: 0 }, 1).tone, "muted");
  assert.match(mainState({ ...m, guard: true, behind: 3 }, 1).label, /3 behind origin/);
  assert.match(mainState({ ...m, guard: true, behind: 3 }, 1, "upstream").label, /3 behind upstream/);
  assert.equal(mainState({ ...m, guard: false, dirty: 22 }, 0).tone, "warn");
  assert.match(mainState({ ...m, guard: false, dirty: 0 }, 3).label, /3 sessions share it/);
});

test("decisions: only what gc will never resolve, each with a command to resolve it", () => {
  const ds = decisions(snap);
  assert.ok(ds.length > 0, "the fixture holds decisions");
  assert.equal(new Set(ds.map((d) => d.id)).size, ds.length, "ids are unique");
  for (const d of ds) {
    assert.ok(GROUP_ORDER.includes(d.group), d.group);
    const primary = d.actions.find((a) => a.kind === "primary");
    assert.ok(primary?.command, `${d.slug} has a primary command`);
    assert.ok(d.actions.some((a) => a.label === "Keep" && !a.command), `${d.slug} can be kept`);
    assert.ok(d.reason.length > 0 && d.unblock.length > 0);
  }
  const decideRows = worktrees.filter((w) => stateOf(w).tone === "decide");
  assert.equal(ds.filter((d) => d.group !== "locked").length, decideRows.length, "every decide-tone row is a decision, and nothing else is");
  for (let i = 1; i < ds.length; i++) assert.ok(GROUP_ORDER.indexOf(ds[i - 1]!.group) <= GROUP_ORDER.indexOf(ds[i]!.group), "grouped in order");
  const autoClosed = decisions({ ...snap, repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/c", slug: "closed-a", repo: "shop", pr: { state: "CLOSED", head: "x" }, unpushed: 0, gc: { action: "would-remove", code: "pr-closed", reason: "feature/closed-a, pr=CLOSED" } })] }], agents: [] });
  assert.equal(autoClosed.length, 0, "a fully pushed closed PR that gc will remove is not a decision");
  const closed = ds.filter((d) => d.group === "closed-pr");
  assert.ok(closed.length >= 1, "the fixture has a closed PR");
  assert.match(closed[0]!.actions[0]!.command!, /^onetree rm \S+ \S+ --force$/);
  assert.deepEqual(closed[0]!.actions[0]!.run, { type: "rm", slug: closed[0]!.slug, repo: closed[0]!.repo, force: true });
  assert.match(closed[0]!.actions[0]!.confirm!, /Remove .+ and delete its local branch/);
  assert.match(closed[0]!.actions[1]!.command!, /^gh pr reopen feature\//);
  assert.equal(closed[0]!.actions[1]!.run, undefined, "reopening a PR is copied, not run");
  for (const d of ds) {
    for (const a of d.actions) {
      if (a.run?.type === "rm" && a.run.force) assert.ok(a.confirm, `${d.slug}: a forced removal asks first`);
      if (a.run?.type === "rm" && a.run.kill?.length) assert.ok(a.confirm, `${d.slug}: ending a session asks first`);
      if (a.run) assert.ok(a.command, `${d.slug}: a run shows its command`);
    }
  }
  const detached = decisions({ ...snap, repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/d", slug: "loose", repo: "shop", detached: true, branch: null, unpushed: 2, gc: { action: "keep", code: "not-merged", reason: "(detached) not merged" } })] }], agents: [] });
  assert.equal(detached.length, 1);
  assert.equal(detached[0]!.group, "detached");
  assert.match(detached[0]!.reason, /2 commits on no branch and no remote/);
  assert.match(detached[0]!.actions[1]!.confirm!, /2 commits exist on no branch/);
  const keepFile = ds.find((d) => d.group === "keep-file");
  if (keepFile) {
    assert.match(keepFile.actions[0]!.command!, /^diff .+ .+$/);
    assert.match(keepFile.actions[1]!.command!, /^cp .+ && onetree rm /);
  }
});

test("decisions: a merged worktree held by a known session names its pid", () => {
  const s: Snapshot = {
    ...snap,
    repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/p", slug: "held", repo: "shop", pr: { state: "MERGED", head: "abc1234def" }, live: 1, gc: { action: "keep", code: "live", reason: "1 live process(es) inside" } })] }],
    agents: [{ pid: 4242, agent: "claude", session: "s", command: "claude", exe: "claude", cwd: "/p", kind: "worktree", repo: "shop", main: "/m", path: "/p", slug: "held", started: 0, startedAt: "" }],
  };
  const d = decisions(s);
  assert.equal(d.length, 1);
  assert.equal(d[0]!.group, "merged-held");
  assert.match(d[0]!.reason, /claude pid 4242/);
  assert.equal(d[0]!.actions[0]!.command, "kill 4242 && onetree rm held shop");
  assert.deepEqual(d[0]!.actions[0]!.run, { type: "rm", slug: "held", repo: "shop", kill: [4242] });
  assert.match(d[0]!.actions[0]!.confirm!, /pid 4242/);
  const unknown = decisions({ ...s, agents: [] });
  assert.equal(unknown[0]!.actions[0]!.run, undefined, "with no known session the page cannot end the process, so it only copies");
});

test("Desktop controller rows are not killable; two in one checkout stay two sessions", () => {
  const command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node /Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs";
  const a = { pid: 25412, agent: "codex", session: null, command, exe: "node", cwd: "/p", kind: "worktree" as const, repo: "shop", main: "/m", path: "/p", slug: "held", started: 0, startedAt: "" };
  const b = { ...a, pid: 25685 };
  assert.equal(isDesktopController(a), true);
  assert.equal(isDesktopController({ ...a, session: "s-desk" }), true);
  assert.equal(isDesktopController({ ...a, command: "node /x/artifact-template-picker/server.mjs" }), false);
  const s: Snapshot = {
    ...snap,
    repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/p", slug: "held", repo: "shop", pr: { state: "MERGED", head: "abc1234def" }, live: 4, gc: { action: "keep", code: "live", reason: "4 live process(es) inside" } })] }],
    agents: [a, b],
  };
  const d = decisions(s);
  assert.equal(d.length, 1);
  assert.equal(d[0]!.agents.length, 2);
  assert.equal(d[0]!.actions.some((x) => x.run?.type === "kill" || (x.run?.type === "rm" && x.run.kill?.length)), false);
  assert.match(d[0]!.unblock, /Close that Codex Desktop thread/);
  const v = agentsView(s);
  assert.equal(v.sessions.length, 2);
  assert.equal(v.shared.length, 1);
});

test("a Desktop controller with a SessionStart id is still not killable", () => {
  const command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node /Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs";
  const a = { pid: 25412, agent: "codex", session: "s-desk", command, exe: "node", cwd: "/p", kind: "worktree" as const, repo: "shop", main: "/m", path: "/p", slug: "held", started: 0, startedAt: "" };
  assert.equal(isDesktopController(a), true);
  const s: Snapshot = {
    ...snap,
    repos: [{ ...snap.repos[0]!, worktrees: [row({ path: "/p", slug: "held", repo: "shop", pr: { state: "MERGED", head: "abc1234def" }, live: 4, gc: { action: "keep", code: "live", reason: "4 live process(es) inside" } })] }],
    agents: [a],
  };
  const d = decisions(s);
  assert.equal(d.length, 1);
  assert.equal(d[0]!.agents[0]!.session, "s-desk");
  assert.equal(d[0]!.actions.some((x) => x.run != null && (x.run.type === "kill" || x.run.type === "rm")), false);
  assert.match(d[0]!.unblock, /Close that Codex Desktop thread/);
});

test("headsUp flags placeholder branches with a live session", () => {
  const hs = headsUp(snap);
  for (const h of hs) {
    assert.ok(isPlaceholder(h.w.branch));
    assert.equal(h.w.gc.code, "live");
    assert.match(h.note, /does not know the name/);
    assert.doesNotMatch(h.note, /<meaningful-slug>/);
  }
});

test("fleet counts add up", () => {
  const f = fleet(snap);
  assert.equal(f.counts.repos, snap.repos.length);
  assert.equal(f.counts.worktrees, worktrees.length);
  assert.equal(f.counts.sessions, snap.agents.length);
  assert.equal(f.counts.decisions, decisions(snap).length);
  assert.equal(f.counts.guarded, snap.repos.filter((r) => r.main.guard).length);
});

test("agentsView locates every session and finds shared checkouts", () => {
  const v = agentsView(snap);
  assert.equal(v.sessions.length, snap.agents.length);
  for (const s of v.shared) {
    assert.ok(s.agents.length > 1);
    assert.ok(!snap.repos.some((r) => r.main.path === s.path && r.main.guard), "a locked mirror with several readers is fine");
  }
  for (const m of v.inMerged) assert.equal(m.worktree?.pr?.state, "MERGED");
  for (const a of v.inMirror) assert.ok(snap.repos.some((r) => r.main.path === a.path && r.main.guard));
  const rank = (attention: string | null) => (attention === "shared" ? 0 : attention === "merged" ? 1 : 2);
  for (let i = 1; i < v.sessions.length; i++) {
    const prev = v.sessions[i - 1]!;
    const cur = v.sessions[i]!;
    assert.ok(rank(prev.attention) < rank(cur.attention) || (rank(prev.attention) === rank(cur.attention) && prev.a.started <= cur.a.started), "shared and merged first, then oldest");
  }
});

function agent(over: Partial<Agent> & Pick<Agent, "pid" | "path">): Agent {
  return {
    agent: "pi",
    session: null,
    command: "pi ",
    exe: "pi",
    cwd: over.path ?? "/outside",
    kind: over.path ? "worktree" : null,
    repo: "shop",
    main: "/m",
    slug: null,
    started: 0,
    startedAt: "",
    ...over,
  };
}

test("agentsView pins shared and merged sessions, and only those rows get a verb", () => {
  const desktop = "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs";
  const now = 1_000_000;
  const main = { ...snap.repos[0]!.main, path: "/m", guard: false, branch: "main" };
  const held = row({ path: "/held", slug: "held", repo: "shop", pr: { state: "MERGED", head: "abc" }, live: 1, gc: { action: "keep", code: "live", reason: "1 live process(es) inside" } });
  const working = row({ path: "/work", slug: "work", repo: "shop", live: 1, gc: { action: "keep", code: "live", reason: "1 live process(es) inside" } });
  const s: Snapshot = {
    ...snap,
    repos: [{ ...snap.repos[0]!, info: { ...snap.repos[0]!.info, repo: "shop" }, main, worktrees: [held, working] }],
    agents: [
      agent({ pid: 1, path: "/work", kind: "worktree", slug: "work", started: 10 }),
      agent({ pid: 2, path: "/held", kind: "worktree", slug: "held", started: 20 }),
      agent({ pid: 3, path: "/m", kind: "main", cwd: "/m", started: now - 60 }),
      agent({ pid: 4, path: "/m", kind: "main", cwd: "/m", agent: "claude", started: now - SESSION_STALE_S - 5 }),
      agent({ pid: 5, path: "/m", kind: "main", cwd: "/m", agent: "codex", command: desktop, exe: "node", started: now - SESSION_STALE_S - 9 }),
      agent({ pid: 6, path: null, cwd: "/Users/you/Documents/shop", kind: null, repo: null, main: null, started: now - 100 }),
    ],
  };
  const v = agentsView(s);
  assert.deepEqual(
    v.sessions.map((x) => x.a.pid),
    [5, 4, 3, 2, 1, 6],
    "shared oldest-first, then merged, then the rest",
  );
  assert.equal(agentsAttention(v), 4, "three sharing the checkout plus the merged session");
  const byPid = new Map(v.sessions.map((x) => [x.a.pid, x]));
  const stale = agentAction(byPid.get(4)!, now);
  assert.equal(stale?.kind, "primary");
  assert.equal(stale?.run.type, "kill");
  assert.match(stale?.confirm ?? "", /other sessions in this checkout stay/);
  assert.match(stale?.confirm ?? "", /does not guard the repo/);
  const recent = agentAction(byPid.get(3)!, now);
  assert.equal(recent?.kind, "quiet", "a session younger than a day is not the suggested one");
  assert.equal(recent?.label, "End session");
  assert.equal(agentAction(byPid.get(5)!, now), null, "a Desktop controller is not ended from the page");
  const merged = agentAction(byPid.get(2)!, now);
  assert.equal(merged?.label, "End session & remove");
  assert.deepEqual(merged?.run, { type: "rm", slug: "held", repo: "shop", kill: [2] });
  assert.equal(agentAction(byPid.get(1)!, now), null);
  assert.equal(agentAction(byPid.get(6)!, now), null, "a session outside every repo is not ended from the page");
  assert.equal(byPid.get(6)!.status, "outside every registered repo");
});

test("doctorFixes does not offer onetree install for a dirty mirror", () => {
  const dirty = doctorFixes([{ name: "guarded main /Users/you/src/shop porcelain clean (or warn-only dirty is a FAIL)", ok: false }]);
  assert.deepEqual(dirty.map((f) => f.command), ["git -C /Users/you/src/shop status --short"]);
  assert.match(dirty[0]!.note, /does not clean/);
  const both = doctorFixes([
    { name: "onetree on PATH resolves to /Users/you/.local/bin/onetree", ok: false },
    { name: "guarded main /x porcelain clean (or warn-only dirty is a FAIL)", ok: false },
    { name: "park lock for /x is not stale", ok: false },
  ]);
  assert.deepEqual(
    both.map((f) => f.command),
    ["git -C /x status --short", "onetree install"],
  );
  assert.equal(doctorFixes([{ name: "guarded main /x has no user-writable working-tree entry", ok: false }]).length, 0);
});

test("guardView tallies the last 24 hours of blocks", () => {
  const g = guardView(snap);
  assert.equal(g.total, snap.events.filter((e) => e.kind === "guard").length);
  assert.equal(g.byRule.reduce((n, [, c]) => n + c, 0), g.total);
  assert.equal(g.byAgent.reduce((n, [, c]) => n + c, 0), g.total);
  assert.deepEqual(g.repeated, [{ key: "pid 91278", count: 3 }], "the pi session that bounced three times");
  assert.equal(g.candidates.length, 1);
  assert.match(String(g.candidates[0]!.command), /^du -sh /);
  assert.ok(g.events[0]!.t >= g.events[g.events.length - 1]!.t, "newest first");
});

test("GUARD_RULES is every rule bin/onetree can record, no more and no less", () => {
  const src = readFileSync(path.join(here, "..", "..", "..", "bin", "onetree"), "utf8");
  const vars = new Map<string, string>();
  for (const m of src.matchAll(/\b([A-Z_]+_RULE|SELF_[A-Z]+)="([^"$]+)"/g)) vars.set(m[1]!, m[2]!);
  const expand = (s: string) => s.replace(/\$([A-Z_]+)/g, (_, v: string) => vars.get(v) ?? `$${v}`);
  const found = new Set(["a write"]);   // block()'s rule when none is given
  for (const re of [/\b(?:_hit|_arg_in_mirror) "([^"]+)"/g, /(?<![\w=])block "[^"]*" "[^"]*" "([^"]+)"/g, /\bblock_self "[^"]*" "([^"]+)"/g]) {
    for (const m of src.matchAll(re)) found.add(expand(m[1]!));
  }
  const literal = [...found].filter((r) => !r.includes("$")).sort();   // $rule, $why: passed through from a literal found elsewhere
  assert.deepEqual(literal, [...GUARD_RULES].sort());
});

test("guardView: a refusal about onetree itself has no repo, and a rule this build does not know can still be filtered", () => {
  const ev = (rule: string, repo: string) => ({ ts: "2026-10-20T00:00:00Z", t: 1, kind: "guard", cmd: "guard", rule, repo, agent: "codex", session: null, pid: 7, command: "x", file: "", tool: "Bash" });
  const g = guardView({ ...snap, events: [ev("turning the guard off: onetree uninstall", ""), ev("a rule from a newer onetree", "shop")] });
  assert.equal(g.rules.slice(0, GUARD_RULES.length).join("|"), GUARD_RULES.join("|"));
  assert.deepEqual(g.rules.slice(GUARD_RULES.length), ["a rule from a newer onetree"]);
  assert.deepEqual([repoLabel(""), repoLabel(null), repoLabel("shop")], ["every repo", "every repo", "shop"]);
});

test("healthView: the last gc run, removals and parks from the events", () => {
  const h = healthView(snap);
  assert.equal(h.runs.length, 2);
  assert.equal(h.lastRun?.removed, 0);
  assert.equal(h.lastRun?.kept, 13);
  assert.equal(h.removals.length, 1);
  assert.equal(h.parks.length, 1);
  const checks = snap.doctor!.checks;
  assert.equal(h.groups.reduce((n, g) => n + g.checks.length, 0), checks.length, "every check lands in a group");
  assert.ok(h.groups.some((g) => g.name === "Tooling"));
  assert.deepEqual(doctorGroups([]), []);
});

test("format helpers", () => {
  assert.equal(ago(100, 130), "30s ago");
  assert.equal(ago(0, 3600 * 5), "5h ago");
  assert.equal(ago(0, 86400 * 3), "3d ago");
  assert.equal(homeOf("/Users/you/.local/bin/onetree"), "/Users/you");
  assert.equal(homeOf("/home/me/src/onetree/bin/onetree"), "/home/me");
  assert.equal(shorten("/Users/you/worktrees/x", "/Users/you"), "~/worktrees/x");
  assert.equal(shorten("/opt/x", "/Users/you"), "/opt/x");
  assert.ok(isPlaceholder("feature/pi-260917-160353"));
  assert.ok(isPlaceholder("feature/dsh-260917-160353"));
  assert.ok(!isPlaceholder("feature/pi-launcher"));
});
