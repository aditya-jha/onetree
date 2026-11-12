// The shape of `onetree snapshot` (docs/snapshot.md, schema 1). Keys the page does not
// read are left out; new keys may appear in the JSON at any time.

export type PrState = "MERGED" | "OPEN" | "CLOSED" | "NONE" | "UNKNOWN";

export interface Verdict {
  action: string;
  code: string;
  reason: string;
}

export interface Row {
  path: string;
  repo: string;
  main: string;
  kind: "main" | "worktree";
  slug: string | null;
  branch: string | null;
  detached: boolean;
  head: string | null;
  dirty: number;
  unpushed: number | null;
  pr: { state: PrState; head: string | null } | null;
  lock: string | null;
  live: number;
}

export interface MainRow extends Row {
  kind: "main";
  guard: boolean;
  integration: string;
  behind: number | null;
  park: Verdict;
}

export interface WorktreeRow extends Row {
  kind: "worktree";
  slug: string;
  gc: Verdict;
}

export interface Info {
  repo: string;
  main: string;
  registered: boolean;
  guard: boolean;
  integration: string;
  root: string;
  worktreeDir: string;
  branchPrefix: string;
  copy: string[];
  keep: string[];
  keepSource: string;
  bootstrap: string | null;
  stale: number | null;
  committedFile: boolean;
  sources: Record<string, string>;
  /** Absent in snapshots from a onetree older than the base/push split. */
  remotes?: Remotes;
  writable?: { paths: string[]; source: string };
  /** Absent before onetree left gitignored paths writable in a guarded mirror; true restores the old lock (only writable.paths stay writable). */
  lockIgnored?: boolean;
  /** Main's node_modules against its lockfile; null without a package.json, absent in older snapshots. */
  deps?: { manager: string; state: "current" | "stale" | "absent" | "unknown"; detail: string } | null;
}

export interface RemoteRef {
  name: string;
  /** local | global | upstream-convention | remote.pushDefault | default */
  source: string;
  /** owner/repo (or host/owner/repo) gh is asked about; a local path for a local remote; null when the remote has no url. */
  slug: string | null;
}

/** base: the integration branch and the PRs. push: where feature branches go. Different only in a fork clone. */
export interface Remotes {
  base: RemoteRef;
  push: RemoteRef;
  ghUser: { login: string | null; source: string };
  /** Per-clone keys a committed .onetree tried to set; onetree ignores them. */
  ignoredFromFile: string[];
}

export interface Repo {
  info: Info;
  main: MainRow;
  worktrees: WorktreeRow[];
}

export interface Agent {
  pid: number;
  agent: string;
  session: string | null;
  command: string;
  exe: string;
  cwd: string;
  kind: "main" | "worktree" | null;
  repo: string | null;
  main: string | null;
  path: string | null;
  slug: string | null;
  started: number;
  startedAt: string;
}

export interface Check {
  name: string;
  ok: boolean;
}

export interface Doctor {
  ok: number;
  failed: number;
  repos: string[];
  checks: Check[];
}

export interface Event {
  ts: string;
  t: number;
  kind: string;
  cmd: string;
  [key: string]: unknown;
}

export interface Snapshot {
  schema: number;
  generatedAt: string;
  host: string;
  onetree: { bin: string };
  repos: Repo[];
  agents: Agent[];
  doctor: Doctor | null;
  events: Event[];
}
