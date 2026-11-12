# Contributing

onetree is one bash script, `bin/onetree`, plus a small dashboard under
`ui/`. CI runs the end-to-end suite on Ubuntu and macOS, and the dashboard
checks and shellcheck on Ubuntu.

## Run the tests

The suite needs bash, git, jq and zsh (for the shell-wrapper tests); the
dashboard needs Node 22.6+.

```
bash tests/run.sh
cd ui && npm ci && npm run verify
```

`npm run verify` typechecks and tests the dashboard, then fails if the
committed `ui/dist` differs from what `src` builds to. After changing anything
under `ui/src`, run `npm run build` and commit `ui/dist` with it.

`tests/run.sh` is hermetic: `HOME`, the registry, the event log and the
caches live in a temp dir, origin is a local bare repo, and a stub `gh` on
`PATH` answers from JSON files and logs every call, which is how the caches
are checked. It never touches your real config or GitHub, and takes a few
minutes. Its fixtures cover:

- `new`, `ls`, gc's verdicts across the young, dirty, not-merged and merged
  states, real removals, `info` provenance, `doctor` and `snapshot` shapes,
  the events each command writes, and Codex Desktop controllers as sessions;
- a fork clone (`origin` a lagging fork behind an SSH host alias, `upstream`
  the canonical repo, the integration branch neither remote's HEAD): where
  branches are cut, tracked and pushed, which repo gh is asked, PR head-owner
  filtering, gc, park and review against the base, and `ghUser`;
- writable local state: what `init` refuses, the lock, what the guard lets
  through, and which writers the filesystem allows in a locked directory;
- dependency clone-or-install and the main's refresh with a stub `npm`,
  `carry` including failures midway, `review` against a PR from a separate
  fork, and the installed hooks, wrappers, pi extension and dsh plugin.

Each assertion is one behaviour: the facets of one operation are checked
together, and the guard's cases sit in tables (`guard_table`) of `allow` and
`block` per command shape, whose failure names every case that got the wrong
verdict.

## Where things live

| Area | Where |
|---|---|
| command dispatch | the `case` at the end of `bin/onetree` |
| the guard: tokenising, command-position walk, allow/block rules | `cmd_guard`, `_guard_walk`, `_check_simple` and the `_wr_*` helpers |
| locking a mirror, writable state, dependency refresh | `lock_main`, `unlock_main`, `writable_ok`, `wr_*`, `deps_refresh` |
| gc verdicts | `verdict_of`, `gc_run`, `remove_one` |
| install, hooks, wrappers, agent rules block | `cmd_install`, `hook_json`, `write_block`, `cmd_rules` |
| snapshot schema | `docs/snapshot.md` |
| dashboard | `ui/server.ts` (loopback server), `ui/src/lib/derive.ts` (what the page concludes from a snapshot) |

Every setting, the guard's rules, forks and dependencies are described in
`docs/reference.md`; keep it in step with behaviour changes. A test fails when
a subcommand or a config key is missing from it.

## What a pull request needs

The rules, for people and agents alike, are in [`AGENTS.md`](AGENTS.md): the
gates, bash 3.2, how tests are written, the CHANGELOG line, and never pushing
to `main`. Releases follow [`RELEASING.md`](RELEASING.md). Beyond those:

- A CHANGELOG entry says what changed and why, with the failure that
  motivated it when there was one.
- A `# shellcheck disable=` comment carries a reason, and only where the
  warning is wrong.
- For a larger design choice, or an approach tried and dropped, a note in
  `docs/design/`: a status line, the problem, the decision, what was
  rejected and why. Keep the status current.

Open the PR against `main`. Squash merges are fine; gc reads merged state
from GitHub, not from the commit graph.
