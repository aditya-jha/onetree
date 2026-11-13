# onetree reference

The long form of [README.md](../README.md): every setting, the guard's rules,
forks, dependencies, machine-readable output and the dashboard.

- [Settings](#settings)
- [Production checkouts](#production-checkouts)
- [Forks](#forks)
- [Writable local state](#writable-local-state)
- [Dependencies in a guarded mirror](#dependencies-in-a-guarded-mirror)
- [The guard](#the-guard)
- [How agents work under onetree](#how-agents-work-under-onetree)
- [Machine-readable output](#machine-readable-output)
- [Dashboard](#dashboard)
- [Notes and limits](#notes-and-limits)

## Settings

Settings resolve in this order, first hit wins:

1. the repo's `.git/config` under `[onetree]`, written by `onetree init` (this machine only)
2. a committed `.onetree` file at the repo root, written by `onetree init --file` (every clone)
3. `~/.config/onetree/config` (this machine's defaults)
4. built-in defaults

`onetree repos` lists the registered repos; `onetree info [repo]` prints the
effective settings for one and `--json` says which layer each came from.
`onetree version` (or `--version`) prints `onetree 1.0.0`, plus `(dev <short sha>)`
when run from a git clone that is not at a release tag.

`onetree update` follows releases, by what the source it was installed from is:
- **a release install**, detached at a `vX.Y.Z` tag (as `install.sh` leaves it): fetches
  tags, checks out the newest `vX.Y.Z` by version order (never a pre-release), reinstalls;
- **a contributor clone**, on a branch: fast-forwards that branch, reinstalls;
- **a Homebrew install**, under `$(brew --prefix)`: changes nothing and prints
  `brew upgrade onetree && $(brew --prefix)/bin/onetree install`.

| Key | Default | Meaning |
|---|---|---|
| `integration` | the base remote's HEAD branch, else `main` | the branch PRs target and worktrees are cut from |
| `guard` | `false` | make the main checkout a read-only mirror |
| `root` | `~/worktrees` | worktrees live at `<root>/<repo>/<slug>`. A root inside a checkout is excluded from git: through `.git/info/exclude` when guarded, else `.gitignore` |
| `branchPrefix` | `feature/` | a branch is named `<prefix><slug>` |
| `copy` | `.env .env.local` | gitignored files copied from the main checkout into a new worktree |
| `keep` | none | gitignored files gc must not lose: a worktree holding one that differs from `keepSource` is kept |
| `keepSource` | the main checkout | the directory holding the current copy of the `keep` files |
| `bootstrap` | none | a shell command run inside a new worktree, after the built-in dependency install, with `ONETREE_MAIN` and `ONETREE_PATH` set |
| `stale` | `24` | hours before gc may remove a clean worktree with no merged PR: one whose closed PR has every commit pushed, or one with nothing beyond the integration branch |
| `writable` | none | gitignored local state by name: repo-relative paths, `d/` for a directory. A missing entry is created when the mirror is locked; with `lockIgnored`, only these stay writable |
| `lockIgnored` | `false` | lock gitignored paths in a guarded mirror too, except what `writable` lists |
| `remote` | `upstream` if it is another repo than `origin`, else `origin` | the base remote: where the integration branch lives and PRs are opened, merged and looked up. Per clone |
| `pushRemote` | git's `remote.pushDefault`, else `origin` when it exists, else the base remote | where feature branches are pushed. Per clone |
| `ghUser` | gh's active account | the `gh auth login` account onetree's `gh` calls for this repo use (`gh auth token --user`), without switching the active one. Per clone |

`remote`, `pushRemote` and `ghUser` differ between clones (a teammate may call
the canonical remote `origin`, and a GitHub login is personal), so onetree
reads them from `.git/config` or the global file only. A committed `.onetree`
that sets them is ignored, `onetree info` warns, `onetree doctor` fails, and
`onetree init --file` refuses to write them.

A committed `.onetree`:

```
[onetree]
	integration = develop
	guard = true
	bootstrap = make setup
	copy = .env config/local.yml
```

## Production checkouts

Don't guard a checkout that production automation runs from and writes:
scheduled jobs that update tracked files and push, services started from its
paths, AI jobs that work inside it. `writable` refuses tracked paths, so it
can't make room for them. Leave that checkout unregistered (`onetree
unregister` it if it is registered), give development its own guarded clone,
and mark production in its own git config:

```
git config --local onetree.production true
git config --local onetree.devClone ~/src/app-development   # optional
```

onetree reads `production` and `devClone` only from that clone's local config,
never from a committed `.onetree` or the global file. With the marker:

- an interactive session there is told it may inspect but not change the
  checkout, and is pointed to `devClone`; a non-interactive session hears
  nothing;
- `onetree init` refuses the checkout until you remove the marker;
- `gc` and `park` skip it, and `onetree info` and `onetree doctor` report a
  marker left on a registered checkout;
- an agent can't change or remove the marker: `git config` writes to
  `onetree.production`, `onetree.devClone` or the `onetree` section, and any
  edit, redirect, rewrite or patch of that `.git/config`, or removing or moving
  its `.git`, are refused.

The development clone is a full clone from the remote, not a worktree of
production, sharing no git directory or object alternates with it. Keep its
worktree root outside production, don't commit `guard = true` in a `.onetree`
production also reads, and don't copy production's credentials, mutable state
or venv into it. This separates the two by habit, not permission: an agent
running as the same user can still write to production by its path. Stronger
isolation needs a separate OS user or a sandbox. The decision is in
[design/production-checkouts.md](design/production-checkouts.md).

## Forks

When you work from a fork, two remotes play two roles:

| Role | Holds | In a fork clone | Otherwise |
|---|---|---|---|
| base | the integration branch; the PRs | `upstream` (the canonical repo) | `origin` |
| push | your feature branches | `origin` (your fork) | `origin` |

```
git clone git@github.com:you/app.git && cd app
git remote add upstream git@github.com:acme/app.git && git fetch upstream && git remote set-head upstream -a
onetree init --guard --integration develop
onetree info
```

```
integration   develop
remote        upstream (upstream-convention) acme/app
pushRemote    origin (default) you/app
ghUser        (gh's active account)
```

The base remote is `remote` if set, else a remote named `upstream` that points
at a different repo than `origin` (the `gh repo fork` convention), else
`origin`. The push remote is `pushRemote`, else git's `remote.pushDefault`,
else `origin`. `onetree init` and `onetree info` print both, and why. A clone
with only `origin`, or an `upstream` that is the same repo, uses `origin` for
both.

In a fork clone:

- `onetree new` fetches both remotes and cuts the branch from
  `upstream/<integration>`, never from the fork's copy, which usually lags.
  The branch tracks `upstream/<integration>` and gets
  `branch.<b>.pushRemote = origin`, so a bare `git push -u` lands on the fork
  and `git status` counts commits against the real integration branch. A
  branch that already exists on the fork is resumed from there.
- PR lookups ask the canonical repo and keep only a PR whose head lives in
  your fork: `gh pr list --head <branch>` matches that branch name in every
  fork, so someone else's `feature/fix-login` would otherwise count as yours.
- `behind` compares the main checkout with `upstream/<integration>`.
  `unpushed` compares a worktree with its branch on the fork, or with
  `upstream/<integration>` before the first push. gc sees a merge once the
  head is on `upstream/<integration>`, however far the fork lags, and `park`
  fast-forwards the main checkout from `upstream`.
- `onetree review <branch>` looks on `upstream`, then on the fork, and says
  which. `onetree review <n>` fetches PR `<n>` from `upstream`, whoever's fork
  its head is in.
- `onetree snippet` tells agents to push to the fork and prints the
  `gh pr create --repo <canonical> --base <integration> --head <you>:<branch>`
  that opens the PR in the right place.
- `onetree init` looks at the base branches of the canonical repo's last 50
  merged PRs. When another branch got more of them than the one onetree picked
  (`upstream/HEAD` might say `master` while PRs merge into `develop`), it says
  so with the counts and suggests `--integration`. It uses the PR cache, makes
  no network call when gh has no token, and never fails init.

Remote URLs can be SSH host aliases (`git@github-work:acme/app.git`, for a
second GitHub account); onetree reads `owner/repo` from them. If that account
isn't gh's active one, `onetree init --gh-user <login>` makes onetree's PR
lookups for this repo use it. `onetree init` says when gh can't see the
canonical repo at all.

## Writable local state

A guarded mirror is read-only so that task work never lands in it. The lock
covers what git tracks or would track: every tracked file, and every untracked
file git doesn't ignore. What git ignores stays writable: that is the working
state of the repo's tools (`node_modules/`, husky's `.husky/_/`,
`.tsbuildinfo`, `dist/`, `.env`, IDE and agent settings), not task work, and it
can't carry task work out either, because committing an ignored path takes
`git add -f`, which the guard refuses there.

| What git ignores | Lock | What works |
|---|---|---|
| a whole directory (`node_modules/`, `.husky/_/`, `.idea/`) | keeps `u+w`; no lock or unlock walks into it | every writer: new files, `npm ci`, `husky`, `sed -i`, editors' atomic save, `mv`, `rm` |
| a file in a directory that holds tracked files (`.env` or `.tsbuildinfo` at the root) | the file keeps `u+w`; its directory stays locked | in-place writes: Claude Code's Edit and Write, `>`, `>>`, `tee`, `cp` onto it, most editors, tsc and eslint rewriting their caches |

An ignored file's directory stays locked on purpose. For `.env` that directory
is the repo root, and a writable root would let anything create, rename or
delete any top-level file. So writers that create a temp file and rename it
over the target fail there: `sed -i` and write-then-`mv` fail loudly, `perl -i`
fails silently (exit 0, file unchanged), and editors with "safe write" fail to
save. The guard refuses `sed -i` and `perl -i` on such a file and says to edit
in place.

Nothing can create a new file in a locked directory, even one git would
ignore, such as the first `.tsbuildinfo` or `.eslintcache` at the root. So
whenever onetree locks, it creates, empty, the files git hooks' checks create,
when git ignores them and they are missing: tsc's build info (from a root
`tsconfig*.json`: `tsBuildInfoFile`, or `incremental` / `composite` without
`outDir`), `.eslintcache` and `.stylelintcache`. tsc 5.9 and eslint 10 accept
an empty cache file and rewrite it in place. `onetree doctor` checks that none
is missing. Anything else is refused as "a new file in a locked directory",
and the refusal names the fix: `onetree init --writable-add <path>` creates it
once.

Untracked files git doesn't ignore (Claude Code's `.claude/settings.json`,
say) stay locked, because they look exactly like task work. `onetree init
--guard` lists each one with both fixes: commit it from a worktree (`onetree
carry <slug> --untracked` moves it there), or keep it local with `onetree init
--writable-add <path> --exclude-writable`, which adds it to
`.git/info/exclude` so git ignores it. onetree never edits the exclude file
without that flag.

### writable and lockIgnored

`writable` lists local state by name; `d/` is a directory. Each entry must be
untracked and gitignored: `onetree init` refuses a tracked file, a directory
holding tracked files, or a path git doesn't ignore. A listed entry that is
missing is created the next time onetree locks (a directory, or an empty file,
`{}` for `.json`). Edit the list instead of retyping it:

```
onetree init --writable-add ".claude/settings.local.json"   # adding an entry twice is a no-op
onetree init --writable-remove ".env"                       # removing one that isn't listed is a no-op, with a note
```

Both are validated like `--writable` and print the resulting list.
`--writable "…"` replaces the whole list, and `--writable ""` clears it.

`onetree init --lock-ignored` (`lockIgnored = true`) locks ignored paths too,
so only what `writable` lists stays writable. `onetree init --no-lock-ignored`
gives the ignored paths `u+w` back.

### A dirty main: onetree carry

`onetree init --guard` on a main with uncommitted changes warns, lists each
dirty path, and locks them in place. To move the work out instead:

```
onetree init --guard --carry fix-login          # tracked changes; add --carry-untracked for untracked files too
onetree carry fix-login [repo] [--untracked]    # the same, any time, on a guarded main or not
```

`carry` creates the worktree `fix-login`, its branch cut from main's `HEAD` so
the changes apply exactly as they were made, applies them there uncommitted
(new files intent-to-add, as in main), and copies untracked files when asked.
Then it checks: the worktree's diff against `HEAD` must be byte-identical to
main's, and every changed or copied file must be identical on disk, which also
catches a clean/smudge filter such as LFS. Only then does it restore main to
`HEAD` and remove the copied untracked files, and only then does `init` lock.
If a step fails, main is untouched, the half-made worktree and its branch are
removed, and `init` leaves guard off. If main changes while the carry runs,
main is left as it is and the worktree keeps the earlier copy. A path whose
staged version differs from both `HEAD` and the working copy stops the carry
before it starts, because only one of the two would reach the worktree: stage
all of it or unstage it first.

gc leaves a dirty guarded main alone. `park` never overwrites a gitignored
file in the main checkout: when switching to the integration branch, or
fast-forwarding it, would replace one with a file that branch now tracks, park
leaves main where it is and names the file (code `blocked`).

## Dependencies in a guarded mirror

The built-in install reads one lockfile, at the worktree root. A
`package.json` in a subdirectory (this repo's dashboard lives in `ui/`) isn't
seen, and `onetree info` says `deps (no package.json)`. Declare it with
`bootstrap`:

```
[onetree]
	bootstrap = cd ui && npm ci --ignore-scripts
```

- **A worktree clones main's `node_modules` only when it is what the
  worktree's lockfile asks for**, not when two lockfiles match. With npm, the
  check compares what npm recorded installing (`node_modules/.package-lock.json`)
  with `package-lock.json`, entry by entry: version and source (`integrity`,
  or `resolved` where there is none, as for a git dependency whose new commit
  keeps its version), and each package's directory must exist. A missing
  optional package is fine, since platform packages for other systems are
  never installed. With pnpm, `node_modules/.pnpm/lock.yaml` must equal
  `pnpm-lock.yaml`. yarn and bun record nothing onetree can compare, so they
  never clone. Otherwise the worktree installs fresh, with one line naming the
  drift (`stale: 235 missing, 0 at another version or source, of 1145 in
  package-lock.json`). A failing install rolls the new worktree back, so a
  dead registry token shows up at `onetree new`, not hours later in a git hook.
- **gc and `onetree park` keep a guarded main's npm dependencies current.**
  When main's `node_modules` is stale against its lockfile, after a
  fast-forward added a package say, onetree runs `npm ci --ignore-scripts` in a
  scratch directory inside the git dir, checks the result against the
  lockfile, and only then swaps it in: two renames, under the park lock, with
  the root opened for that moment. `npm ci` empties `node_modules` before it
  installs, which is why it never runs in place. A failed refresh leaves the
  old tree as it was, and gc doesn't retry until the lockfile changes
  (`onetree park` always retries).
  - The refresh waits while anything works in main. onetree runs `lsof` before
    the install and again right before the swap; any process whose working
    directory is in main counts, except shells and agent sessions that merely
    sit there.
  - Each rename lands only where nothing is. If the fresh tree can be neither
    placed nor the previous one put back, onetree keeps both in
    `.git/onetree-deps/`, says where, and fails a `onetree doctor` check until
    you move one back.
  - One refresh runs per main at a time, behind `.git/onetree-deps.lock`. A
    lock whose process died is reported with the command to clear it, never
    removed automatically.

  The refresh skips npm workspaces, a lockfile with uncommitted changes, pnpm,
  yarn and bun, and `lockIgnored`.
- The install uses the worktree flags, `--ignore-scripts` included, so a
  postinstall that needs a toolchain doesn't run. If a package needs its
  install script in the main checkout, install it there yourself.
- Git hooks run from the main checkout (a `git push` there) use main's
  `node_modules`, which is why it is kept current. `onetree info` shows `deps`,
  and `onetree doctor` checks a guarded main's dependencies against its
  lockfile.
- A Python repo with `uv.lock` gets its own `.venv` in each worktree through
  `uv sync`; the main checkout's venv is never shared.

## The guard

`onetree guard` is the PreToolUse hook. It parses the command rather than
matching text, and judges each simple command in the folder it runs in.

**In a guarded main checkout it refuses:** file edits (Edit, Write,
`apply_patch`, redirects, `tee`, `sed -i`, `cp` and `mv` onto tracked paths),
chmod and chflags, running scripts, servers and tests (`npm test`, `make`,
`node script.js`, `./bin/x`, `bash script.sh`), and mutating git. A git command
counts as a write unless its verb is known to read; for `remote`, `config`,
`stash`, `reflog`, `notes` and `worktree` the operation decides. So an alias is
refused there: spell the command out. A fetch into a local branch, git's own
`--output` file, and `git config --file` into the mirror are writes. From
anywhere, a path into the mirror (`git -C <mirror>`, `GIT_DIR=`,
`--git-dir`, `env -C`, a script by its path, `npm --prefix`) is judged as the
mirror. An interpreter (`python`, `node`, `perl`, a shell) is judged by the
script it runs, the first word that is neither an option nor an option's
value. The words after it are the script's own arguments, so from a worktree
`python3 tool.py --repo <mirror>` passes (it reads the mirror) and
`python3 -u <mirror>/tool.py` is refused.

**It passes:** reads (`git status`, `git log`, `git diff`, `cat`, `rg`), writes
into gitignored local state (Edit, Write, redirects and `tee` into an ignored
path; inside an ignored or listed directory also `mkdir`, `mv`, `rm`, `sed -i`
and `perl -i`), a build tool asked only for its version or help (`make
--version`, `npm -v`), and the `onetree` commands that don't turn it off. Every
path is resolved first (symlinks, `..`), so `node_modules/../README.md` is the
tracked file it names. A new file must itself be ignored by git.

**How it reads the shell:** quoted text and heredocs are data, and a quote may
span lines; `$(…)` and backticks are judged, also in a heredoc with an
unquoted delimiter; `bash -c` and `eval` are parsed as nested commands, and
their redirects judged; inside `if`, `while`, `{ … }` and functions each
command is judged; `cd`, `cd -`, `env -C` and each `git -C` set where the next
command runs; after a `cd` that may not run (in a block, after `&&` or `||`,
into a folder that doesn't exist) later commands are judged in both folders.
In a guarded checkout it fails closed: a program given a writing git command
among its words (`watch`, `flock`, `find -exec`, `parallel`, a wrapper it
doesn't know) or a quoted command line to run (`watch '…'`, `flock -c '…'`)
has that command judged, and a shell reading its commands from stdin
(`bash <<EOF`, `… | bash`, `bash -s`) is refused. Tools that only print,
search or send text (`echo`, `grep`, `rg`, `man`, `gh`, `jq`, `curl`, `ssh`)
pass, also after `find -exec`; `gh pr checkout` and `gh repo sync` are writes.

**It can't be switched off by an agent**, from any directory. It refuses
`onetree uninstall` while any repo is guarded, `onetree unregister` of a
guarded repo, and an `onetree init` on one whose last `--guard`/`--no-guard`
is `--no-guard`. It refuses `git config` writes to `onetree.*` keys (a section
renamed into or out of `onetree` included) in a guarded repo's `.git/config`,
which its worktrees share, or in onetree's config file however git is pointed
at it (`-f`, `--file`, `GIT_CONFIG`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`).
It refuses any edit, redirect, `cp` onto, in-place rewrite or `apply_patch` of
that file, under its name or through a symlink or hard link to it, and `rm` or
`mv` of it or of a directory holding it. Reading them passes, and so do the
other `onetree` commands, `init --writable-add` included. The refusal tells
the agent that the user runs the command.

**Its limits:** it is a command parser, not a sandbox. It stops the mistakes
agents make in normal work, not a determined adversary. A mutation inside a
script file, or behind a variable it can't expand, gets through; a program an
agent starts runs as you. The repo's own git hooks stay the last line.

## How agents work under onetree

`onetree install` writes a rules block (`onetree rules` prints it) into each
agent's global instructions. It tells every agent to:

- run `onetree info` to learn a repo's rules, and ask before onboarding a new one;
- in a guarded repo, run `onetree new <slug>` and work only in the printed
  path, stating it in the first reply, never switching branches in the mirror;
- rename placeholder branches like `feature/claude-…` before the first push;
- ship through a PR into the integration branch, fetch before every commit and
  push, never force-push, and say "worktree `<path>` is done" when the PR
  merges.

A project's own AGENTS.md or CLAUDE.md can add to these rules, for example
which ports its dev servers bind, but can't relax them.

Claude and Codex are bound by the PreToolUse hook. Codex runs a hook only
after you approve it with `/hooks`, and again after any change to it; `install`
says when an approval is due, and `onetree doctor` fails until Codex trusts
onetree's hooks. pi is bound by `~/.pi/agent/extensions/onetree.ts`, which
calls the same `onetree guard`. dsh is bound by `~/.dsh/onetree-plugin.mjs`,
loaded for every dsh profile by a managed row in `~/.dsh/cordis.patch.yml`: it
maps dsh's tools (bash with its `workdir`, write, edit, `str_replace_editor`)
onto the shapes the guard reads and denies what it refuses. `onetree render
pi|dsh` prints either file as install writes it. dsh counts as dsh however it
is started: by its name, as the `@deepseek-ai/dsh` package, or from its source
checkout (`node … deepseek-harness/apps/cli/src/bin.ts`).

### Sessions

`onetree session` is the SessionStart hook for all four agents. It tells a
session in a registered repo what that repo expects, and an interactive
session in a repo that isn't onboarded to ask the user once. It records the
session's pid, session id, agent and folder in
`~/.local/state/onetree/sessions/<pid>.json`. A non-interactive session (Claude
exports `CLAUDE_CODE_SESSION_ATTENDED=0` for `-p`; Codex `exec` is recognised
by its process ancestry) hears nothing outside a registered repo; a guarded
checkout's notice and its guard apply to every session.

The shell wrappers (`~/.onetree-agents.sh`, sourced by zsh and bash) start
`claude`, `codex`, `pi` and `dsh` through `onetree launch`. `claude -p` /
`--print`, `codex exec` / `e` (resume included) and `codex login` run as typed
in the caller's folder, even when onetree is missing; anything else in a
guarded mirror starts in a fresh worktree from `onetree auto`, and a missing
or failing onetree refuses to start it there. Claude is started in that
folder, never through its own `--worktree` option, which binds the session and
makes Claude refuse shell commands it can't prove stay inside. onetree
pre-trusts `<root>/<repo>` in `~/.claude.json` once, Claude's documented way to
trust a folder, so no trust dialog appears in its worktrees. Claude's own
`--worktree`, `--continue` and `--resume` pass through. The wrapper functions'
names start with a letter (`onetree_launch`, `onetree_claude_passthrough`, …):
Claude Code snapshots a shell's functions for its agents but drops variables
and names starting with one underscore.

`onetree launch [--task <slug>] <agent> [args…]` is what anything else that
starts agents (fish, a script, a process supervisor) calls. In a guarded mirror
the agent starts in a fresh worktree; `--task <slug>` starts it in that named
worktree, print and exec modes included, for a job that will edit. Elsewhere it
runs as typed. `launch` replaces itself with the agent, so argv, the standard
streams and the exit status are the agent's.

### When a session has to move

A session that started somewhere else (the Claude or Codex desktop app, an
IDE, a resumed session, a read-only conversation that turns into a change)
runs `onetree new <slug>` itself. Its host fixed the session's folder at the
start, so `onetree new`, `carry` and `review` print one more line on stderr,
`onetree: next, …`, saying how that agent works in the worktree; stdout is
only the path. The agent is told apart by its process (a Codex started from a
Claude shell is Codex), the host by its environment:

| Agent and host | What it is told |
|---|---|
| Claude desktop app | `change_directory` with the path (main conversation only): the file pane, diff, terminal and PR card follow when the turn ends. `EnterWorktree` moves Claude but not the app, whose panes follow it only into `<repo>/.claude/worktrees` |
| Claude CLI, IDE, SDK | `cd <path> &&` before every command and absolute paths for edits. Not `EnterWorktree`: it binds the session to that worktree, and Claude Code then refuses any shell command it cannot prove stays inside it (a `$(…)`, a loop, a variable next to `git`), in the session and its subagents |
| Codex CLI | `cd <path> &&` before every command (the hook sees the command, never `workdir`) and absolute `apply_patch` paths; the user can move the thread with `/cd <path>` |
| Codex app | the same; the thread's review pane stays where it started, so a new thread on the path reviews the work |
| pi | nothing: the extension runs the session's commands in the worktree from then on |
| dsh | `workdir` on every bash call and absolute paths for file tools; the web UI keeps the session under the mirror |

`new` records which session made the worktree (`agent`, `host`, `session`,
`pid`), so a guard refusal in the mirror names that session's newest worktree.
From a mirror, `apply_patch` with absolute paths into a worktree passes; a
relative path lands in the mirror and is refused. A shell command's `workdir`
(dsh passes one) is where the guard judges it.

A pi session can't change its folder, so the extension follows the worktree it
makes: after `onetree new` or `carry` it asks onetree which worktree that was
(`onetree bound`), keeps it in the session (so `/resume` restores it), and runs
each bash command and resolves relative read, write and edit paths there. It
trusts a worktree whose main checkout `~/.pi/agent/trust.json` trusts; a
review checkout is never trusted that way.

Codex's `workspace-write` sandbox keeps a worktree's git directory read-only,
so a commit there fails. When the wrapper starts Codex in a worktree it grants,
as `--add-dir` (`onetree codex-grants <worktree>` lists them), exactly what
onetree's workflow writes: the main checkout's `.git/objects`, the worktree's
own git directory, its branch's namespace (`refs/heads/feature/` and its
reflogs; a branch with no prefix gets none, since `refs/heads` holds the
integration branch) and each remote's tracking refs. It also sets
`fetch.writeFetchHead=false`, `maintenance.auto=false` and `gc.auto=0` for that
Codex through `GIT_CONFIG_PARAMETERS`. So commit, rebase and fetch work, and
pushing works where Codex has network access; `git push -u` can't record an
upstream (`.git/config` stays read-only), so push with `git push <remote> HEAD`.

dsh's `workspace-write` sandbox, the headless default, has the same limit, and
takes grants while it runs. So the plugin grants a session whose folder is a
worktree the same folders (`onetree codex-grants`), once per live session and
again after a resume, through dsh's `sandboxPolicy.registerWritableRoot`: every
dsh profile gets them with no launch flag. A session in a main checkout is
granted nothing, and a sandboxed session still cannot make a second worktree:
`onetree new` says so.

Under either sandbox git prints `error: Unable to create
'<main>/.git/packed-refs.lock': Operation not permitted` on each commit. The
commit still lands: git takes that lock as part of a ref update and carries on
without it, and the file sits in `.git` itself, which is never granted.

In the Claude app, a session started with **Worktree** on gets an onetree
worktree from the start: the app runs onetree's WorktreeCreate hook
(`onetree hook-create`). When the app skips the hook (an existing branch, say) it makes
its own worktree under `<repo>/.claude/worktrees`, so a guarded mirror keeps
that folder writable and out of `git status`. In a repo onetree doesn't manage,
the hook makes a plain worktree on `claude/<name>` and leaves registering to
the user. The Codex app makes its own worktrees (`~/.codex/worktrees`) and runs
its environment's setup script in each; `onetree snippet` says how to make that
script run `onetree bootstrap "$CODEX_WORKTREE_PATH"`.

### Other tools' worktrees, and coming back

gc removes only worktrees onetree made: they carry a marker in their git
directory (`onetree`, or `onetree-review` for review checkouts). Markers decide
first: one the Codex app leaves (`codex-thread.json`), or a place in the Claude
app's `<repo>/.claude/worktrees`, makes a worktree that tool's. A worktree
without any marker counts as onetree's when it is under the repo's root or a
`new`, `carry` or `review` event names it, and gets the marker then. Anything
else is kept with code `foreign` and its maker named; that tool removes it. An
explicit `onetree rm`, or Claude's WorktreeRemove hook
(`onetree hook-remove`), still removes one.

A session's host files it under the folder it last worked in, so after a move
the main checkout's resume list no longer shows it, and once gc removes the
worktree there is nowhere to resume. `onetree resume` lists the agent sessions
that made the repo's worktrees, with each worktree's state. `onetree resume
<slug|session>` recreates a removed worktree (its pushed branch comes back) and
prints how to resume the session there: Claude's from the folder its
transcript was last in, Codex's by thread id, pi's from the main checkout,
where the extension takes it back to the worktree.

`onetree doctor` checks that each agent onetree wraps starts (`<agent>
--version`), and that what install wrote is current: the installed copy
against the source checkout (and that one against its upstream, as of its last
fetch), and the shell wrappers, the pi extension, the dsh plugin and each rules
block against what this onetree writes. Any drift names `onetree update`.

## Machine-readable output

`ls`, `gc`, `info` and `doctor` take `--json`, and `onetree snapshot` bundles
them into one document. Every worktree carries gc's verdict as a stable code
plus the reason gc logs, and `info --json` says which layer each value came
from.

`onetree events` is the audit trail: every guard block with its rule, agent,
session and command, every removal, park and new worktree, one JSON line each
in `~/.local/state/onetree/events.jsonl`. Nothing is written for a call the
guard allowed or a worktree gc kept. The snapshot embeds the last 24 hours.

`onetree agents` lists the agent sessions alive now, which repo or worktree
each one sits in, and its session id when the SessionStart hook saw it start.
Without a hook record, a Codex Desktop thread appears as its `cua-repl.mjs`
controller (not each `cua_node` helper, and not the shared app-server); two
threads in one checkout are two rows. The dashboard offers no End session for
those rows: close the thread in the Codex app, because killing the controller
leaves helpers in the checkout. A guard block records the same pid, so a
refusal can be tied to a session.

These commands are quick enough to run every minute: repos, and each repo's
worktrees, are judged in parallel, and the slow external answers (PR states
from `gh`, fetches, the doctor report) are cached for a few minutes under
`~/.local/state/onetree/cache`. `--fresh` ignores the caches; `onetree rm`
never uses them. On 8 repos with 19 worktrees a snapshot takes about 3.5 s
warm and 7 s cold.

The schema is in [snapshot.md](snapshot.md).

## Dashboard

```
onetree ui
```

opens a page on `127.0.0.1` over `onetree snapshot`, with a token in the URL
that changes every run. Five tabs: **Fleet**, every worktree with gc's verdict
in words; **Inbox**, the worktrees gc will never remove on its own, grouped by
reason, each with the command that resolves it; **Agents**, the sessions alive
now, with End session on a shared checkout and End session & remove on a
merged worktree; **Guard**, every block in the last 24 hours with rule, agent
and command; **Health**, doctor, the gc job, the removal trail and each repo's
settings. Dark buttons run on this machine after a confirmation that shows the
exact command: remove a worktree, end a session, run gc or doctor, unlock. The
server allows only those, checks every argument against the last snapshot, and
calls only `onetree`, `git` and `kill`. Light buttons copy a command. The page
is a Vite build committed under `ui/dist`, served by a dependency-free node
server; Node 22.6+ is the only extra requirement. See
[../ui/README.md](../ui/README.md).

## Notes and limits

- Cleanup consults GitHub through `gh`. Without it, gc still removes worktrees
  whose head is an ancestor of the integration branch, but can't see
  squash-merged PRs.
- Two registered repos with the same directory name share a folder under
  `root`; give one of them its own `root`.
- On macOS the installed script is a copy, not a symlink, because launchd isn't
  allowed into `~/Documents` and similar folders.
- `onetree new` checks files out with one worker per core
  (`checkout.workers=0`): on a repo with 29k tracked files (2.8 GB) that takes
  the checkout from 8.7 s to 4.3 s. Repos under 100 files check out serially.
  `ONETREE_TIMING=1 onetree new …` prints the time of each phase, and the `new`
  event records the total in `seconds`.
