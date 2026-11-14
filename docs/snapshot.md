# Machine-readable output

`onetree` prints tables for people. The same facts are available as JSON for
scripts and for the dashboard:

| Command | Output |
|---|---|
| `onetree ls [repo\|--all] --json` | an array: one **main** object per repo followed by one **worktree** object per worktree |
| `onetree gc [repo\|--all] --dry-run --json` | an array of verdicts: one per worktree (`gc`) and one per main (`park`). Without `--dry-run` the verdicts are what gc did. |
| `onetree info [repo] --json` | the effective config and, under `sources`, the layer each value came from |
| `onetree doctor --json` | every check with its result; the exit status is still non-zero when one fails |
| `onetree events [--json] [--since 24h] [--kind K] [-n N]` | what onetree did or refused: guard blocks, removals, parks, new worktrees (see Events) |
| `onetree agents [--json]` | live agent sessions and where they sit (see Agents) |
| `onetree snapshot [repo\|--all] [--fresh]` | everything above in one document; `--all` is the default |
| `onetree ui` | the dashboard: a page over `onetree snapshot` (`ui/README.md`) |

gc's log lines are the `reason` strings below. `--fresh` on `ls`, `gc` and `snapshot` ignores the caches described under
Caches.

## Snapshot

```
{
  "schema": 1,
  "generatedAt": "2026-09-21T02:04:00Z",     UTC
  "host": "…",
  "onetree": { "bin": "/Users/you/.local/bin/onetree" },
  "repos": [ { "info": …, "main": …, "worktrees": [ … ] } ],
  "agents": [ … ],                           live agent sessions, oldest first
  "doctor": { "ok": 37, "failed": 0, "repos": ["shop"], "checks": [ { "name": "git on PATH", "ok": true } ] },
  "events": [ … ]                            the last 24 hours, at most 500, oldest first
}
```

The schema number changes only when an existing key changes meaning or goes
away. New keys can appear at any time.

`snapshot` runs the same fetch and prune that `gc` does, so it is as fresh as
an hourly gc run. It is not as slow as one: the repos are judged at the same
time, each repo's worktrees at the same time, doctor and agents alongside,
and the slow external answers come from the caches below. On a machine with
8 repos and 19 worktrees a snapshot takes about 3.5 s with warm caches and
7 s cold, where the cold time is the doctor's walk over the guarded mains.

## Caches

Some answers are slow to get and change rarely. onetree keeps them under
`~/.local/state/onetree/cache` (override with `ONETREE_CACHE`), each with a time to
live in seconds:

| What | Where | TTL | Used by |
|---|---|---|---|
| a branch's PR state from `gh` | `cache/pr/<key>` | `ONETREE_PR_TTL`, 300 | `ls`, `gc`, `snapshot` |
| the last 30 merged PR heads of a repo | `cache/merged/<key>` | `ONETREE_PR_TTL` | gc's "never had a PR, but merged" check |
| a fetch of a main checkout | `<git dir>/onetree-fetched`, a stamp | `ONETREE_FETCH_TTL`, 120 | `gc`, `snapshot` |
| the doctor report | `cache/doctor.json` | `ONETREE_DOCTOR_TTL`, 300 | `snapshot` only; `onetree doctor` always runs |

`ls`, `gc` and `snapshot` warm the PR cache first, one background job per
repo, so a cold run asks `gh` about every branch at once rather than one after
another. `--fresh` forgets every cached answer first and then asks once.
`onetree rm` and the WorktreeRemove hook always ask `gh` for the one branch they
judge. A TTL of 0 disables that cache. `ONETREE_TIMING=1` prints the phases of a
run with their times on stderr.

### info

```
{
  "repo": "shop", "main": "/Users/you/src/shop", "registered": true,
  "production": false, "productionConflict": false, "devClone": null,
  "guard": true, "integration": "main",
  "root": "/Users/you/worktrees", "worktreeDir": "/Users/you/worktrees/shop",
  "branchPrefix": "feature/", "copy": [".env", ".env.local"],
  "keep": [], "keepSource": "/Users/you/src/shop",
  "bootstrap": null, "stale": 24, "committedFile": false,
  "sources": { "guard": "local", "integration": "remote-head", "root": "global", "branchPrefix": "default", … },
  "remotes": {
    "base": { "name": "upstream", "source": "upstream-convention", "slug": "acme/shop" },
    "push": { "name": "origin", "source": "default", "slug": "you/shop" },
    "ghUser": { "login": null, "source": "default" },
    "ignoredFromFile": []
  },
  "writable": { "paths": [".env", ".claude/standup/"], "source": "local" },
  "lockIgnored": false,
  "deps": { "manager": "npm", "state": "current", "detail": "1119 installed, 25 optional not installed" }
}
```

`sources` values: `local` (the repo's `.git/config`), `file` (a committed
`.onetree`), `global` (`~/.config/onetree/config`), `default`. `integration` can also be
`remote-head` (taken from `<base>/HEAD`, the base remote's HEAD branch).
`committedFile` says whether a `.onetree` exists at the repo root.
`production`, `productionConflict` and `devClone` describe the local production
marker. `productionConflict` is true when the marked checkout is still registered.
The marker values come only from that checkout's local `.git/config`, never
from `.onetree` or onetree's global config.

`remotes.base` is where the integration branch lives and where PRs are looked
up; `remotes.push` is where feature branches are pushed. They differ only in a
fork clone. `source` is `local`, `global`, `upstream-convention` (an `upstream`
remote that is another repo than `origin`), `remote.pushDefault` (git's own
setting, push only) or `default`. `slug` is what `gh -R` is given: `owner/repo`
(also behind an SSH host alias), `host/owner/repo` on another host, or a local
path for a local remote; null when the remote has no URL. `ghUser.login` is the
`gh auth login` account onetree's gh calls for this repo use, null for gh's active
account. These keys are per clone, so onetree never reads them from a committed
`.onetree`; `ignoredFromFile` lists the ones a `.onetree` tried to set. `writable.paths`
is the local state listed by name (`d/` is a directory); `onetree doctor` checks
that each is untracked and ignored. In a guarded mirror every gitignored path
stays writable unless `lockIgnored` is true, in which case only the listed
paths do. `deps` is null without a `package.json`; otherwise `manager` is
`npm`, `pnpm`, `yarn` or `bun`, and `state` is `current` or `stale` (main's
`node_modules` against its own lockfile), `absent` (no `node_modules`) or
`unknown` (nothing recorded to compare: always for yarn and bun). `detail`
gives the counts for npm.

### main and worktree rows

Both carry the same keys; a main row adds `guard`, `integration` and `behind`.

```
{
  "path": "/Users/you/worktrees/shop/checkout-retry", "repo": "shop", "main": "/Users/you/src/shop",
  "kind": "worktree",                 "main" for the main checkout
  "slug": "checkout-retry",           null for the main checkout; what `onetree rm <slug>` accepts
  "branch": "feature/checkout-retry", null when detached
  "detached": false,
  "head": "a1b2c3d…",                 full sha
  "dirty": 2,                         paths `git status --porcelain` lists
  "unpushed": 1,                      commits ahead of <push>/<branch>, or of <base>/<integration> before the first push; for a detached HEAD, the commits on no remote-tracking ref; null when unknown or on a main row
  "pr": { "state": "OPEN", "head": "a1b2c3d…" },   state: MERGED OPEN CLOSED NONE UNKNOWN; head null unless gh returned one; null on a main row. For a review checkout, the PR of the branch it was made from
  "lock": null,                       "LOCKED: <reason>" when `git worktree lock` was used
  "live": 1,                          processes whose cwd is inside
  "guard": true, "integration": "main", "behind": 0    main rows only; behind = commits <base>/<integration> has that HEAD lacks, null when unknown
}
```

### gc verdicts

A worktree row from `gc --json` or a snapshot adds `gc`; a main row adds `park`.

```
"gc":   { "action": "keep", "code": "live",           "reason": "1 live process(es) or dsh session(s) inside" }
"park": { "action": "none", "code": "on-integration", "reason": "on main" }
```

| `gc.action` | `gc.code` | Meaning |
|---|---|---|
| `keep` | `foreign` | another tool made it (the Codex app, the Claude app's own `.claude/worktrees`, anything outside onetree's root that no event names); the reason names it. Explicit `onetree rm` still removes it |
| `keep` | `locked` | `git worktree lock` is set |
| `keep` | `live` | a process has its cwd inside |
| `keep` | `dirty` | uncommitted paths |
| `keep` | `keep-file` | a `keep` file differs from the copy in `keepSource` |
| `keep` | `pr-open` | the PR is open |
| `keep` | `young` | no merged PR and younger than the stale window |
| `keep` | `after-merge` | commits after the merged PR head |
| `keep` | `not-merged` | not merged and no other reason applies (a CLOSED PR with unpushed commits stays here) |
| `keep` | `unpushed` | merged by ancestry but with unpushed commits |
| `keep` | `changed` | git refused `worktree remove`: something wrote into it after the checks above |
| `would-remove` / `remove` | `pr-merged` | the PR merged at this head |
| `would-remove` / `remove` | `pr-closed` | the PR was closed, every commit is already on the push remote, past the stale window |
| `would-remove` / `remove` | `in-integration` | no merged PR, but HEAD is inside the integration branch |
| `would-remove` / `remove` | `review` | a `onetree review` checkout, past the stale window or with its PR resolved (see Review checkouts) |
| `remove` | `on-remote` | `onetree rm` of a clean detached checkout whose `HEAD` is on a remote ref or a fetched PR head, whatever its age or PR state |
| `remove` | `forced` | `onetree rm --force` |

| `park.action` | `park.code` | Meaning |
|---|---|---|
| `none` | `unguarded` | unguarded repos are never parked |
| `none` | `on-integration` | already on the integration branch |
| `leave` | `dirty` | uncommitted changes in the main checkout |
| `leave` | `not-merged` | the branch it sits on has not merged |
| `leave` | `diverged` | on the integration branch with commits the remote lacks, so it cannot fast-forward; the reason gives the count |
| `leave` | `blocked` | git refused the switch or fast-forward, for example because it would overwrite an ignored file; the reason names the files |
| `would-park` | `candidate` | dry run: clean, on another branch (merge state is checked only when parking for real) |
| `parked` | `merged` | switched back to the integration branch |
| `fast-forwarded` | `updated` | was on the integration branch and pulled new commits |

The checks run in the order of the `keep` rows, so one worktree gets one
verdict: the first reason that applies.

### Review checkouts

`onetree review <branch>` leaves a detached worktree at `<base>/<branch>` (else `<push>/<branch>`) and
records that branch, and the head it was made at, in `<the worktree's git
dir>/onetree-review`. While HEAD is still that head, or everything in it is on
a remote, it holds no work of its own: gc removes it once clean, unlocked and
idle, as soon as the branch's PR is merged or closed, or otherwise once past
the stale window. While that PR is open it is kept (`pr-open`), because that
is what you are reading. A commit made in it keeps it (`not-merged`), and
`onetree review` run again refuses to move it, naming the commits.

Its row reports `branch: null` and `detached: true`, and its `pr` is the PR of
the branch it was made from. A `review-` worktree with no record counts as a
review checkout too; its `pr` is `NONE`, so the stale window decides.

`onetree review <n>` (or `pr:<n>`) checks out PR `<n>` instead: it fetches
`pull/<n>/head` from the base remote into `refs/onetree/pr/<n>`, which GitHub serves
for a PR from any fork, and records `#<n>`. The slug is `review-pr-<n>`, its
`pr` is that PR's state (`gh pr view <n>`), gc treats it like any review
checkout, and removing it deletes `refs/onetree/pr/<n>`. That ref sits outside every
remote's namespace, so `fetch -p` never prunes it, and `unpushed` counts the
PR's commits as pushed.

A detached worktree that `onetree review` did not make is left alone by gc: it may
hold commits that exist nowhere else, and gc cannot tell. It keeps the
`not-merged` verdict, and the dashboard asks you about it. `onetree rm` without
`--force` takes any clean detached checkout whose `HEAD` is on a remote ref or
a fetched PR head (code `on-remote`, or `review`), since it holds no unique
work, and still refuses one that is dirty or holds a commit on no remote.

For any detached HEAD, `unpushed` counts the commits reachable from HEAD and
from no remote-tracking ref, which is what would be lost. It is not compared
against the integration branch, which means nothing without an upstream.

## Events

`~/.local/state/onetree/events.jsonl` (override with `ONETREE_EVENTS`) is an
append-only file with one JSON object per line. onetree writes to it only when it
changes something or refuses something, so it stays small: a `keep` verdict
is not an event, a removal is. `onetree uninstall` keeps the file. A write that
fails never fails the command that tried it. `ONETREE_NO_EVENTS=1` in the
environment suppresses writing; `onetree doctor` uses it for its guard probes.

Every event carries `ts` (UTC), `t` (epoch seconds, what `--since` compares),
`kind` and `cmd` (the onetree subcommand that was running). The rest depends on
`kind`:

| `kind` | When | Fields |
|---|---|---|
| `guard` | the guard refused a tool call in a guarded mirror, or one that would turn the guard off or change onetree's settings (`main` and `repo` are empty when it would change every repo) | `decision` (`block`), `rule` (the guard's rule name), `tool`, `agent`, `session`, `pid` (the agent process, see Agents), `cwd`, `path`, `main`, `repo`, `command`, `file` |
| `gc` | a worktree was removed, by `gc`, `rm` or the WorktreeRemove hook | `action` (`remove`), `code` (`pr-merged`, `pr-closed`, `in-integration`, `review`, `on-remote`, `forced`), `reason`, `path`, `repo`, `branch` |
| `gc-run` | a real (not dry) `onetree gc` finished | `target`, `kept`, `removed`, `parked`, `fastForwarded`, `seconds` |
| `park` | a guarded main was parked or fast-forwarded | `action` (`parked`, `fast-forwarded`), `code`, `reason`, `main`, `repo` |
| `new` | `onetree new` created a worktree, or an agent ran it again on one (`reused`) | `path`, `repo`, `branch`, `seconds` (how long it took; not on `reused`), `resumed` (true when the branch already existed), `agent`, `host`, `session`, `pid`, `pidStart` (the agent session that ran it; empty for a person), `subagent` (only for a Claude subagent's isolated worktree: its agent id; the session never moves there) |
| `review` | `onetree review` made a checkout | `path`, `repo`, `branch` (`#<n>` for a PR, with `pr`: the number) |
| `carry` | `onetree carry` (or `init --carry`) moved a main's uncommitted work into a new worktree | `path`, `main`, `repo`, `branch`, `tracked`, `untracked` (path counts) |
| `deps` | gc or park refreshed a guarded main's stale npm dependencies, deferred it, or failed to | `action` (`refreshed`, `deferred` while something works in main, `failed`, `stuck` when a swap could not finish and the previous tree waits in `.git/onetree-deps/old`), `reason`, `main`, `repo` |

`agent` is the payload's own `agent` field (the pi extension and the dsh
plugin set it), else `claude`, `codex`, `pi` or `dsh` from where the hook
payload's transcript lives, else `unknown`. `session` is the
hook payload's `session_id` when present. Allowed calls are not recorded.

```
onetree events                       the last 100, oldest first, one line each
onetree events --json --since 24h    a JSON array; --since takes 30m, 24h, 7d or an epoch
onetree events --kind guard -n 0     one kind, no limit
```

## Agents

`onetree agents` lists the agent sessions alive right now and where each one sits.
A process is a session when the SessionStart hook recorded it, or else when
its own name says so (`claude`, Claude Code's version-numbered binary,
`codex`, `pi`, or an interpreter running one of their scripts). Codex Desktop
threads that started before the hook was installed are a fallback: the
process whose command line names `@oai/cua-repl/bin/cua-repl.mjs` counts as
`codex`. There is one such controller per observed thread. Sibling helpers
(`node_repl`, template-picker, `server.mjs` under `cua_node`) are not
sessions, so two controllers in one checkout stay two rows and the Agents
page can still see the collision. Arbitrary Node, and any command that merely
mentions `cua_node`, is ignored. The shared Codex app-server is not a session
(its cwd is `/`). Two hook-recorded sessions remain two rows; the hook's `session_id` is
identity metadata when it exists. The dashboard does not offer End session
on a Desktop controller row, recorded or not: killing the controller would
leave its helpers in the checkout, so gc would still keep the worktree.
Close that thread in the Codex app. Shells, editors and builds inside a repo are not
listed; `live` on a worktree row still counts them.

A session the hook recorded whose cwd is outside every registered repo is still a row: `kind`, `repo`, `main`, `path` and `slug` are null, and `cwd` is that directory. The empty fields are part of the row. Dropping them shifts the elapsed time into `kind` and makes `started` look like now.

The SessionStart hook (`onetree session`) writes `~/.local/state/onetree/sessions/<pid>.json`
(override the directory with `ONETREE_SESSIONS`) with the agent's pid, its
`session_id`, the agent name and the cwd. That record is the preferred identity
when it exists. The pid is the nearest ancestor of the hook that is not a
shell, so Claude, Codex and pi are found whether they run the hook through
`sh -c` or directly; `ONETREE_SESSION_PID` overrides the walk. Files of dead
processes are pruned on every `onetree agents`. The same pid is recorded on
`guard` events, which is how a block is tied to a session.

```
{
  "pid": 54738, "agent": "claude",          claude | codex | pi | dsh | unknown
  "session": "9f2c…",                       the hook's session_id, null when nothing was recorded
  "command": "…/claude --output-format …",  argv, first 200 characters
  "exe": "claude", "cwd": "/Users/you/worktrees/shop/checkout-retry",
  "kind": "worktree",                       main | worktree | null (outside every registered repo)
  "repo": "shop", "main": "/Users/you/src/shop", "path": "/Users/you/worktrees/shop/checkout-retry", "slug": "checkout-retry",
  "started": 1789964400, "startedAt": "2026-09-20T15:00:00Z"
}
```
