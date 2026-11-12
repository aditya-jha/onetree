// What the screens show, derived from one snapshot. Pure functions, tested
// against fixtures/snapshot.json with node:test.

import type { Agent, Check, Event, MainRow, Repo, Snapshot, WorktreeRow } from "./types.ts";
import type { ActionRequest } from "./actions.ts";
import { ago, isPlaceholder, plural, short } from "./format.ts";

/** Codex Desktop cua-repl.mjs controller. A SessionStart id is identity metadata only; killing the pid still leaves sibling helpers in the checkout. */
export function isDesktopController(a: Agent): boolean {
  return a.command.includes("@oai/cua-repl/bin/cua-repl.mjs");
}

export type Tone = "ok" | "auto" | "decide" | "warn" | "muted";
export interface State {
  label: string;
  tone: Tone;
}

/** One line per worktree: gc's verdict read as a person would, not the raw columns. */
export function stateOf(w: WorktreeRow): State {
  const merged = w.pr?.state === "MERGED";
  if (w.gc.action === "would-remove" || w.gc.action === "remove") {
    const why = w.gc.code === "pr-merged" ? "Merged" : w.gc.code === "review" ? "Review checkout, read" : w.gc.code === "pr-closed" ? "PR closed" : "In integration";
    return { label: `${why} · gc removes next run`, tone: "auto" };
  }
  switch (w.gc.code) {
    case "locked":
      return { label: "Locked", tone: "muted" };
    case "live":
      if (merged) return { label: "Merged · held by session", tone: "decide" };
      return { label: isPlaceholder(w.branch) ? "Working · placeholder branch" : "Working", tone: "ok" };
    case "dirty":
      if (merged) return { label: "Merged · uncommitted change", tone: "decide" };
      if (w.live > 0) return { label: "Working · uncommitted", tone: "ok" };
      if (w.pr?.state === "OPEN") return { label: "PR open · uncommitted", tone: "ok" };
      return { label: "Stalled · no PR, nobody inside", tone: "decide" };
    case "keep-file":
      return { label: "Keep-file drift", tone: "decide" };
    case "pr-open":
      return { label: "PR open", tone: "ok" };
    case "young":
      return w.detached ? { label: "Review checkout · expires", tone: "auto" } : { label: "Fresh · nothing committed", tone: "ok" };
    case "after-merge":
      return { label: "Commits after merged PR", tone: "warn" };
    case "unpushed":
      return { label: "Merged by ancestry · unpushed", tone: "warn" };
    case "not-merged":
      if (w.pr?.state === "CLOSED") return { label: "PR closed, not merged", tone: "decide" };
      if (w.detached) return { label: "Detached · commits live only here", tone: "decide" };
      if (w.live > 0) return { label: "Working", tone: "ok" };
      return (w.unpushed ?? 1) > 0 ? { label: "Stalled · unpushed, no PR", tone: "decide" } : { label: "Stalled · pushed, no PR", tone: "decide" };
    case "foreign":
      return { label: w.gc.reason.charAt(0).toUpperCase() + w.gc.reason.slice(1), tone: "muted" };
    default:
      return { label: w.gc.reason, tone: "muted" };
  }
}

/** The remote holding the integration branch: origin, or upstream in a fork clone. */
export function baseRemote(r: Repo): string {
  return r.info.remotes?.base.name ?? "origin";
}

/** A fork clone pushes to a different repo than the one its PRs live on. */
function forkOf(r: Repo): { slug: string; owner: string; push: string } | null {
  const rm = r.info.remotes;
  if (!rm || rm.push.name === rm.base.name || !rm.base.slug || !rm.push.slug) return null;
  const owner = rm.push.slug.split("/").at(-2);
  return owner ? { slug: rm.base.slug, owner, push: rm.push.name } : null;
}

export function mainState(m: MainRow, sessions: number, base = "origin"): State {
  const behind = m.behind && m.behind > 0 ? ` · ${m.behind} behind ${base}` : "";
  if (m.guard) return { label: `Locked · read-only${behind}`, tone: "muted" };
  if (m.dirty > 0) return { label: `Unguarded · ${plural(m.dirty, "uncommitted path")}${behind}`, tone: "warn" };
  if (sessions > 1) return { label: `Unguarded · ${sessions} sessions share it${behind}`, tone: "warn" };
  return { label: `Unguarded${behind}`, tone: "muted" };
}

// ---- the decision inbox

export type Group = "merged-held" | "closed-pr" | "stalled" | "keep-file" | "detached" | "locked";
/** A button. With `run` the page asks the server to do it (after `confirm`, when set); with only `command` it copies the command. */
export interface Action {
  label: string;
  kind: "primary" | "secondary" | "quiet";
  command?: string;
  run?: ActionRequest;
  confirm?: string;
}
export interface Decision {
  id: string;
  group: Group;
  repo: string;
  slug: string;
  path: string;
  branch: string | null;
  reason: string;
  unblock: string;
  actions: Action[];
  state: State;
  w: WorktreeRow;
  agents: Agent[];
}

export const GROUPS: Record<Group, { title: string; why: string }> = {
  "merged-held": { title: "Merged, but not removable", why: "the PR is in, something still pins the worktree" },
  "closed-pr": { title: "PR closed without merging", why: "unpushed commits would be lost; fully pushed closed PRs gc removes after the stale window" },
  stalled: { title: "Stalled: work with no PR and nobody inside", why: "might be forgotten, might be tomorrow morning" },
  "keep-file": { title: "Holds the only current copy of a keep file", why: "removing it could lose a private file" },
  detached: { title: "Detached, holding commits that live nowhere else", why: "gc cannot tell whether this is work or a stray checkout" },
  locked: { title: "Locked by hand", why: "git worktree lock is set; gc will never touch it" },
};
export const GROUP_ORDER: Group[] = ["merged-held", "closed-pr", "stalled", "keep-file", "detached", "locked"];

const keep = (): Action => ({ label: "Keep", kind: "quiet" });

function decide(w: WorktreeRow, r: Repo, agents: Agent[]): Decision | null {
  const st = stateOf(w);
  if (st.tone !== "decide" && w.gc.code !== "locked") return null;
  const rm = `onetree rm ${w.slug} ${w.repo}`;
  const rmf = `${rm} --force`;
  const merged = w.pr?.state === "MERGED";
  const base = { id: w.path, repo: w.repo, slug: w.slug, path: w.path, branch: w.branch, reason: w.gc.reason, state: st, w, agents };

  const forced: ActionRequest = { type: "rm", slug: w.slug, repo: w.repo, force: true };
  if (w.gc.code === "locked") {
    return {
      ...base,
      group: "locked",
      unblock: "Unlock it and gc judges it like any other worktree.",
      actions: [{ label: "Unlock", kind: "secondary", command: `git -C ${r.main.path} worktree unlock ${w.path}`, run: { type: "unlock", main: r.main.path, path: w.path } }, keep()],
    };
  }
  if (w.gc.code === "live" && merged) {
    const pids = agents.map((a) => a.pid);
    const who = agents.length ? agents.map((a) => `${a.agent} pid ${a.pid}`).join(", ") : plural(w.live, "process", "processes");
    if (agents.some(isDesktopController)) {
      return {
        ...base,
        group: "merged-held",
        reason: `PR merged at ${short(w.pr?.head)}. Held by ${who} with cwd inside.`,
        unblock: "Close that Codex Desktop thread in the app. Ending the listed pid would leave its helper processes in the checkout, so gc would still keep the worktree.",
        actions: [{ label: "Open terminal here", kind: "secondary", command: `cd ${w.path}` }, keep()],
      };
    }
    return {
      ...base,
      group: "merged-held",
      reason: `PR merged at ${short(w.pr?.head)}. Held by ${who} with cwd inside.`,
      unblock: agents.length ? "That session finished its task. Ending it lets the next gc remove the worktree." : "Removable the moment the process exits.",
      actions: [
        pids.length
          ? { label: "End session & remove", kind: "primary", command: `kill ${pids.join(" ")} && ${rm}`, run: { type: "rm", slug: w.slug, repo: w.repo, kill: pids }, confirm: `End ${plural(pids.length, "session")} (pid ${pids.join(", ")}) and remove ${w.slug}?` }
          : { label: "End process & remove", kind: "primary", command: rm },
        { label: "Open terminal here", kind: "secondary", command: `cd ${w.path}` },
        keep(),
      ],
    };
  }
  if (w.gc.code === "dirty" && merged) {
    return {
      ...base,
      group: "merged-held",
      reason: `PR merged. ${plural(w.dirty, "uncommitted path")} left behind, nobody inside.`,
      unblock: "Look at the leftover change, then discard it or commit it somewhere.",
      actions: [
        { label: "Show diff", kind: "secondary", command: `git -C ${w.path} status --short && git -C ${w.path} diff` },
        { label: "Discard & remove", kind: "primary", command: rmf, run: forced, confirm: `Discard ${plural(w.dirty, "uncommitted path")} in ${w.slug} and remove it?` },
        keep(),
      ],
    };
  }
  if (w.gc.code === "not-merged" && w.pr?.state === "CLOSED") {
    return {
      ...base,
      group: "closed-pr",
      reason: `PR closed, not merged. ${w.unpushed ?? 0} unpushed, ${plural(w.live, "process", "processes")} inside.`,
      unblock: "These commits live only here. Reopen the PR, push, or remove the worktree knowing they go with it.",
      actions: [
        { label: "Remove worktree & branch", kind: "primary", command: rmf, run: forced, confirm: `Remove ${w.slug} and delete its local branch ${w.branch ?? ""}? The PR stays closed on GitHub.` },
        { label: "Reopen PR", kind: "secondary", command: `gh pr reopen ${w.branch ?? ""}`.trim() },
        keep(),
      ],
    };
  }
  if (w.gc.code === "dirty") {
    const prNote = !w.pr || w.pr.state === "NONE" || w.pr.state === "UNKNOWN" ? "no PR" : `PR ${w.pr.state.toLowerCase()}`;
    const unpushed = w.unpushed ?? 1;   // an unknown count is treated as some
    const lost = unpushed > 0 ? ` and ${w.unpushed === null ? "any unpushed commits" : plural(unpushed, "unpushed commit")}` : "";
    return {
      ...base,
      group: "stalled",
      reason: `${plural(w.dirty, "uncommitted path")}, ${prNote}, no live process.`,
      unblock: "Decide whether it is still going anywhere.",
      actions: [
        { label: "Show diff", kind: "secondary", command: `git -C ${w.path} diff` },
        { label: "Discard & remove", kind: "primary", command: rmf, run: forced, confirm: `Discard ${plural(w.dirty, "uncommitted path")}${lost} in ${w.slug} and remove it? Nothing is saved.` },
        keep(),
      ],
    };
  }
  if (w.gc.code === "not-merged" && !w.detached) {
    const fork = forkOf(r);
    const open = fork
      ? `gh pr create --repo ${fork.slug} --base ${r.info.integration} --head ${fork.owner}:${w.branch ?? ""} --fill`
      : `gh pr create --head ${w.branch ?? ""} --fill`.replace("  ", " ");
    const remote = fork?.push ?? "origin";
    const unpushed = w.unpushed ?? 1;   // unknown counts as unpushed: never claim a remote copy we can't see
    if (unpushed > 0) {
      return {
        ...base,
        group: "stalled",
        reason: `${plural(unpushed, "commit")} on no remote, no PR, nobody inside, older than the stale window.`,
        unblock: "Push it and open the PR, or let it go.",
        actions: [
          { label: "Push & open PR", kind: "secondary", command: `git -C ${w.path} push -u ${remote} ${w.branch ?? ""} && ${open}` },
          { label: "Discard & remove", kind: "primary", command: rmf, run: forced, confirm: `Remove ${w.slug} and delete its branch? Its ${plural(unpushed, "commit")} exist nowhere else.` },
          keep(),
        ],
      };
    }
    return {
      ...base,
      group: "stalled",
      reason: "Pushed, no PR, nobody inside, older than the stale window.",
      unblock: "Open the PR or let it go.",
      actions: [
        { label: "Open PR", kind: "secondary", command: open },
        { label: "Remove worktree", kind: "primary", command: rmf, run: forced, confirm: `Remove ${w.slug} and delete its local branch? The pushed branch stays on ${remote}.` },
        keep(),
      ],
    };
  }
  if (w.gc.code === "keep-file") {
    const m = /^(\S+) differs from (.+)$/.exec(w.gc.reason);
    const file = m?.[1] ?? "<file>";
    const src = m?.[2] ?? "<keepSource>";
    return {
      ...base,
      group: "keep-file",
      unblock: "Copy the worktree version back, or confirm the other copy is the right one.",
      actions: [
        { label: "Show diff", kind: "secondary", command: `diff ${w.path}/${file} ${src}` },
        { label: "Copy back & remove", kind: "primary", command: `cp ${w.path}/${file} ${src} && ${rm}` },
        keep(),
      ],
    };
  }
  if (w.gc.code === "not-merged" && w.detached) {
    return {
      ...base,
      group: "detached",
      reason: `Detached HEAD with ${plural(w.unpushed ?? 0, "commit")} on no branch and no remote. onetree review did not make this one, so gc leaves it alone.`,
      unblock: "Put the commits on a branch, or let them go.",
      actions: [
        { label: "Show the commits", kind: "secondary", command: `git -C ${w.path} log --oneline HEAD --not --remotes` },
        { label: "Remove", kind: "primary", command: rmf, run: forced, confirm: `Remove ${w.slug}? Its ${plural(w.unpushed ?? 0, "commit")} exist on no branch and no remote, so they go with it.` },
        keep(),
      ],
    };
  }
  return null;
}

export function decisions(s: Snapshot): Decision[] {
  const out: Decision[] = [];
  for (const r of s.repos) {
    for (const w of r.worktrees) {
      const d = decide(w, r, s.agents.filter((a) => a.path === w.path));
      if (d) out.push(d);
    }
  }
  return out.sort((a, b) => GROUP_ORDER.indexOf(a.group) - GROUP_ORDER.indexOf(b.group));
}

export interface HeadsUp {
  w: WorktreeRow;
  agents: Agent[];
  note: string;
}
/** Not decisions yet, but about to become one. */
export function headsUp(s: Snapshot): HeadsUp[] {
  const out: HeadsUp[] = [];
  for (const r of s.repos) {
    for (const w of r.worktrees) {
      if (isPlaceholder(w.branch) && w.gc.code === "live") {
        out.push({ w, agents: s.agents.filter((a) => a.path === w.path), note: "Placeholder branch with a live session. Rename it before the first push. The page does not know the name, so it will not invent a command." });
      }
    }
  }
  return out;
}

// ---- fleet

export interface FleetRow {
  w: WorktreeRow;
  state: State;
  agents: Agent[];
}
export interface FleetRepo {
  repo: Repo;
  rows: FleetRow[];
  mainAgents: Agent[];
  mainState: State;
}
export interface Fleet {
  repos: FleetRepo[];
  counts: { repos: number; guarded: number; worktrees: number; decisions: number; sessions: number };
}
export function fleet(s: Snapshot): Fleet {
  const repos = s.repos.map((repo) => {
    const mainAgents = s.agents.filter((a) => a.path === repo.main.path);
    return {
      repo,
      rows: repo.worktrees.map((w) => ({ w, state: stateOf(w), agents: s.agents.filter((a) => a.path === w.path) })),
      mainAgents,
      mainState: mainState(repo.main, mainAgents.length, baseRemote(repo)),
    };
  });
  return {
    repos,
    counts: {
      repos: s.repos.length,
      guarded: s.repos.filter((r) => r.main.guard).length,
      worktrees: s.repos.reduce((n, r) => n + r.worktrees.length, 0),
      decisions: decisions(s).length,
      sessions: s.agents.length,
    },
  };
}

// ---- agents

/** A session older than this in a shared checkout is the one to end. A newer one may be you. */
export const SESSION_STALE_S = 24 * 60 * 60;

export type AgentAttention = "shared" | "merged" | null;

export interface AgentView {
  a: Agent;
  status: string;
  tone: Tone;
  worktree?: WorktreeRow;
  main?: MainRow;
  /** Why this row is pinned above working sessions. A shared merged worktree is "shared". */
  attention: AgentAttention;
}
export interface AgentsView {
  sessions: AgentView[];
  shared: { path: string; repo: string; kind: string; agents: Agent[] }[];
  inMirror: Agent[];
  inMerged: AgentView[];
}
export function agentsView(s: Snapshot): AgentsView {
  const byPath = new Map<string, Agent[]>();
  for (const a of s.agents) {
    if (!a.path) continue;
    byPath.set(a.path, [...(byPath.get(a.path) ?? []), a]);
  }
  const sharedPaths = new Set(
    [...byPath.entries()]
      .filter(([, list]) => list.length > 1)
      .filter(([path]) => !s.repos.some((r) => r.main.path === path && r.main.guard))
      .map(([path]) => path),
  );
  const sessions: AgentView[] = s.agents.map((a) => {
    const repo = s.repos.find((r) => r.info.repo === a.repo);
    const worktree = repo?.worktrees.find((w) => w.path === a.path);
    const main = repo && repo.main.path === a.path ? repo.main : undefined;
    const attention: AgentAttention = a.path && sharedPaths.has(a.path) ? "shared" : worktree?.pr?.state === "MERGED" ? "merged" : null;
    if (worktree) {
      if (worktree.pr?.state === "MERGED") return { a, worktree, status: "done? worktree merged", tone: "decide", attention };
      if (isPlaceholder(worktree.branch)) return { a, worktree, status: "working · placeholder branch", tone: "ok", attention };
      return { a, worktree, status: "working", tone: "ok", attention };
    }
    if (main) {
      if (main.guard) return { a, main, status: "read-only · guard active", tone: "muted", attention };
      const n = byPath.get(main.path)?.length ?? 1;
      return { a, main, status: n > 1 ? `shares checkout with ${n - 1} other${n > 2 ? "s" : ""}` : "in the main checkout", tone: n > 1 ? "warn" : "ok", attention };
    }
    return { a, status: "outside every registered repo", tone: "muted", attention };
  });
  const shared = [...byPath.entries()]
    .filter(([, list]) => list.length > 1)
    .filter(([path]) => sharedPaths.has(path))
    .map(([path, agents]) => ({ path, repo: agents[0]?.repo ?? "", kind: agents[0]?.kind ?? "", agents }));
  const inMirror = s.agents.filter((a) => s.repos.some((r) => r.main.path === a.path && r.main.guard));
  const inMerged = sessions.filter((v) => v.worktree?.pr?.state === "MERGED");
  const rank = (v: AgentView) => (v.attention === "shared" ? 0 : v.attention === "merged" ? 1 : 2);
  return { sessions: sessions.sort((x, y) => rank(x) - rank(y) || x.a.started - y.a.started), shared, inMirror, inMerged };
}

/** Sessions a person has to look at: a shared unguarded checkout, or a merged worktree still held open. */
export function agentsAttention(v: AgentsView): number {
  const ids = new Set<number>();
  for (const s of v.shared) for (const a of s.agents) ids.add(a.pid);
  for (const m of v.inMerged) ids.add(m.a.pid);
  return ids.size;
}

export interface AgentAction {
  label: string;
  kind: "primary" | "quiet";
  command: string;
  confirm: string;
  run: ActionRequest;
}

/** The one verb for this row, or nothing. Desktop controllers and sessions outside a repo are not ended from the page. */
export function agentAction(v: AgentView, now: number): AgentAction | null {
  if (isDesktopController(v.a) || !v.a.path) return null;
  const age = ago(v.a.started, now);
  if (v.worktree?.pr?.state === "MERGED") {
    const w = v.worktree;
    return {
      label: "End session & remove",
      kind: "primary",
      command: `kill ${v.a.pid} && onetree rm ${w.slug} ${w.repo}`,
      confirm: `End the ${v.a.agent} session pid ${v.a.pid} (${age}) and remove ${w.slug}? Its PR is merged.`,
      run: { type: "rm", slug: w.slug, repo: w.repo, kill: [v.a.pid] },
    };
  }
  if (v.attention !== "shared") return null;
  const stale = now - v.a.started >= SESSION_STALE_S;
  return {
    label: "End session",
    kind: stale ? "primary" : "quiet",
    command: `kill ${v.a.pid}`,
    confirm: `End the ${v.a.agent} session pid ${v.a.pid} (${age})? The other sessions in this checkout stay. This does not guard the repo.`,
    run: { type: "kill", pids: [v.a.pid] },
  };
}

// ---- guard

export interface GuardEvent extends Event {
  rule: string;
  agent: string;
  session: string | null;
  pid: number | null;
  repo: string;
  command: string;
  file: string;
  tool: string;
}
export interface GuardView {
  events: GuardEvent[];
  total: number;
  byRule: [string, number][];
  byAgent: [string, number][];
  repeated: { key: string; count: number }[];
  candidates: GuardEvent[];
  /** GUARD_RULES, then any rule the events carry that this build does not know (a newer onetree), so every event can be filtered. */
  rules: string[];
}
/** Every rule name the guard in bin/onetree can record. derive.test.ts reads bin/onetree and fails when the two drift apart. */
export const GUARD_RULES = [
  "mutating git",
  "chmod/chflags on a mirror",
  "chmod/chflags on a mirror path",
  "a file-changing command",
  "an output redirect",
  "a new file in a locked directory",
  "an in-place rewrite of a file whose directory is locked (it is writable in place only: use the Edit tool, > or >>)",
  "running a script, server or test",
  "running a mirror script by path",
  "a shell reading its commands from stdin",
  "a write to a mirror path",
  "a write",
  "turning the guard off: onetree uninstall",
  "turning the guard off: onetree unregister",
  "turning the guard off: onetree init --no-guard",
  "changing onetree settings: git config onetree.*",
  "changing onetree settings: onetree's config file",
  "changing onetree settings: production marker",
];
/** A refusal that would change onetree for every repo (uninstall, its config file) records no repo. */
export const repoLabel = (repo: string | null | undefined): string => repo || "every repo";
const PATH_RULES = /mirror path|mirror script/;
export function guardView(s: Snapshot): GuardView {
  const events = s.events.filter((e) => e.kind === "guard") as GuardEvent[];
  const tally = (key: (e: GuardEvent) => string) => {
    const m = new Map<string, number>();
    for (const e of events) m.set(key(e), (m.get(key(e)) ?? 0) + 1);
    return [...m.entries()].sort((a, b) => b[1] - a[1]);
  };
  const bySession = tally((e) => e.session ?? (e.pid ? `pid ${e.pid}` : "unknown"));
  return {
    events: [...events].reverse(),
    total: events.length,
    byRule: tally((e) => e.rule ?? "?"),
    byAgent: tally((e) => e.agent ?? "unknown"),
    repeated: bySession.filter(([, n]) => n >= 3).map(([key, count]) => ({ key, count })),
    candidates: events.filter((e) => PATH_RULES.test(e.rule ?? "")),
    rules: [...new Set([...GUARD_RULES, ...events.map((e) => e.rule).filter((r): r is string => typeof r === "string" && r !== "")])],
  };
}

// ---- health

export interface CheckGroup {
  name: string;
  checks: Check[];
  ok: number;
}
const GROUP_TESTS: [string, RegExp][] = [
  ["Tooling", /on PATH|git >=|gh logged in/],
  ["Install", /executable|resolves to|registry|hooks point|rules block|extension calls|wrappers|gc job|event log/],
  ["Guard probes", /^guard /],
  ["Guarded mains", /^guarded main|^park lock/],
  ["Unguarded roots", /^unguarded/],
];
export function doctorGroups(checks: Check[]): CheckGroup[] {
  const groups = new Map<string, Check[]>();
  for (const c of checks) {
    const name = GROUP_TESTS.find(([, re]) => re.test(c.name))?.[0] ?? "Other";
    groups.set(name, [...(groups.get(name) ?? []), c]);
  }
  return [...groups.entries()].map(([name, list]) => ({ name, checks: list, ok: list.filter((c) => c.ok).length }));
}

export interface DoctorFix {
  label: string;
  command: string;
  note: string;
}
const PORCELAIN = /^guarded main (.+) porcelain clean /;

/** A button only when it is the fix. A dirty mirror is not an install failure. */
export function doctorFixes(checks: Check[]): DoctorFix[] {
  const failed = checks.filter((c) => !c.ok);
  const fixes: DoctorFix[] = [];
  const seen = new Set<string>();
  for (const c of failed) {
    const m = PORCELAIN.exec(c.name);
    if (!m?.[1]) continue;
    const command = `git -C ${m[1]} status --short`;
    if (seen.has(command)) continue;
    seen.add(command);
    fixes.push({ label: "Show status", command, note: `${m[1].split("/").pop()} is dirty. Reinstalling does not clean it.` });
  }
  const install = failed.some((c) => {
    const group = GROUP_TESTS.find(([, re]) => re.test(c.name))?.[0];
    return group === "Install" || group === "Tooling";
  });
  if (install) fixes.push({ label: "onetree install", command: "onetree install", note: "Install or tooling checks are failing." });
  return fixes;
}

export interface GcRun extends Event {
  target: string;
  kept: number;
  removed: number;
  parked: number;
  fastForwarded: number;
  seconds: number;
}
export interface HealthView {
  groups: CheckGroup[];
  lastRun: GcRun | null;
  runs: GcRun[];
  removals: Event[];
  parks: Event[];
}
export function healthView(s: Snapshot): HealthView {
  const runs = s.events.filter((e) => e.kind === "gc-run") as GcRun[];
  return {
    groups: doctorGroups(s.doctor?.checks ?? []),
    lastRun: runs.length ? (runs[runs.length - 1] ?? null) : null,
    runs,
    removals: [...s.events.filter((e) => e.kind === "gc")].reverse(),
    parks: [...s.events.filter((e) => e.kind === "park")].reverse(),
  };
}
