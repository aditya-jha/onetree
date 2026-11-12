# onetree

onetree gives every coding-agent task its own git worktree, refuses agents'
changes to your main checkout, and removes each worktree once its pull request
merges. It is for developers who run
[Claude Code](https://github.com/anthropics/claude-code),
[Codex](https://github.com/openai/codex), [pi](https://pi.dev/) or
[dsh](https://deepseek.com/en/harness/) on GitHub repositories, often several
at once; unlike a worktree manager, it is enforced by hooks, so the agents
can't forget it.

[![ci](https://github.com/aditya-jha/onetree/actions/workflows/ci.yml/badge.svg)](https://github.com/aditya-jha/onetree/actions/workflows/ci.yml)

## The problem

Two agents in one checkout share a branch, an index and the working files. One
switches branch under the other, a stash swallows half-finished work, two
sessions push to the same branch. Asking agents to be careful doesn't fix it:
an agent that has decided to run `git checkout` doesn't re-read the rules
first. Refusing the command does.

## Install

Requirements: macOS or Linux (with cron), bash 3.2+, git 2.31+, `jq` 1.6+,
`gh` logged in, `lsof`, `perl`. Node 22.6+ only for the optional dashboard.

```
curl -fsSL https://raw.githubusercontent.com/aditya-jha/onetree/main/install.sh | bash
exec $SHELL -l       # load the shell wrappers; install says if ~/.local/bin is not on PATH
onetree doctor
```

`install.sh` clones the newest release into `~/.local/share/onetree` (set
`ONETREE_HOME` to change it) and runs `onetree install`. To work on onetree
itself, clone it instead:

```
git clone https://github.com/aditya-jha/onetree.git ~/src/onetree
~/src/onetree/bin/onetree install
exec $SHELL -l
onetree doctor
```

To update:
- **install.sh:** `onetree update` moves to the newest release, and so does
  rerunning `install.sh`. On 1.0.0, rerun `install.sh`: its `update` still
  pulls `main`.
- **clone:** `onetree update` fast-forwards your branch and reinstalls.

Install your agents first: `install` sets up only the ones it finds, and you
run it again after adding one. An agent can run `install` and `doctor` for you.
In Codex, approve onetree's hooks with `/hooks` after install and after any
update that changes them; `doctor` fails until you have. `onetree uninstall`
reverses all of it and keeps the registry and your worktrees.

## Quick start

```
cd ~/src/shop
onetree init --guard      # main becomes a read-only mirror
claude                    # starts in a fresh worktree of shop, on feature/claude-<timestamp>
```

The agent works there, pushes its branch and opens a PR. When the PR merges,
the hourly cleanup removes the worktree and fast-forwards main.

Other ways to onboard (pick one instead of the `init` above):

```
onetree init --guard --integration develop   # PRs target develop, not the remote's default branch
onetree init --guard --carry fix-login       # main has uncommitted work: move it to a worktree first
onetree init --no-guard                      # register for cleanup only; keep working in main directly
onetree init --file                          # write the settings to a .onetree file to commit, for every clone
```

An agent in a repo that isn't onboarded asks you which you want; it never
onboards on its own. A checkout that production automation runs from stays
unregistered: see [Production checkouts](docs/reference.md#production-checkouts).

## What it does

- **Agents start in a worktree.** The shell wrappers start `claude`, `codex`,
  `pi` or `dsh` in a fresh worktree of a guarded repo; one-shot commands such
  as `claude -p` run as typed. A session that starts in the main checkout
  another way is told to run `onetree new <slug>` and how to work there.
- **The main checkout is refused changes.** A PreToolUse hook refuses file
  edits, mutating git, chmod, and running scripts, servers or tests there, and
  names the rule it matched. Tracked files are read-only on disk too, so an
  editor or a tool the hook doesn't see fails as well. Gitignored state
  (`node_modules/`, caches, `.env`, IDE and agent settings) stays writable.
- **Each worktree is ready to work in.** `.env` and other listed files are
  copied; npm, pnpm, yarn or bun dependencies are installed from the lockfile
  (or cloned from main's when they match it), and a Python `uv.lock` gets its
  own venv through `uv`. A failed install rolls the new worktree back.
- **Work leaves through a pull request.** The rules onetree adds to each
  agent's instructions say to push the branch, open a PR into the integration
  branch, fetch before every commit and never force-push. There is no local
  merge command.
- **Cleanup removes only what is safe to remove.** An hourly `onetree gc`
  asks GitHub for each branch's PR. It removes a worktree whose PR merged at
  its head and, after a stale window (24 h by default), one whose PR closed
  with every commit pushed or that holds nothing beyond the integration
  branch. It keeps one that has uncommitted changes, a live process, an open
  PR, commits after the merged head, a changed gitignored file you listed in
  `keep`, or that another tool made. Every removal is logged;
  `onetree rm --force` is the only way to discard work.

## What it looks like

```
$ git checkout other-branch        # an agent, in the main checkout
onetree guard (mutating git): /Users/you/src/shop is the read-only main checkout of shop. Work in a worktree instead: run `onetree new <slug> shop`, then prefix every command with `cd <path> &&` and edit by absolute path (Claude: `EnterWorktree` with that path; in the Claude desktop app, `change_directory`). Never switch, stash, reset, edit, or run scripts, servers or tests in the main checkout; reading is fine. Gitignored local state (dependencies, caches, .env, local settings) stays writable here; tracked files, and new files git would track, do not.

$ onetree ls
PATH                                      BRANCH                  DIRTY  UNPUSHED  PR             PRHEAD   LOCK  LIVE
/Users/you/src/shop                       main                    0      -         main checkout  -        -     0
/Users/you/worktrees/shop/checkout-retry  feature/checkout-retry  2      1         OPEN           3c3b084  -     0

$ onetree events -n 4
2026-11-12T05:12:43Z  guard   guard  block           mutating git  /Users/you/src/shop                 git checkout other-branch
2026-11-12T05:12:45Z  gc      gc     remove          pr-merged     /Users/you/worktrees/shop/fix-typo  feature/fix-typo, pr=MERGED
2026-11-12T05:12:46Z  park    gc     fast-forwarded  updated       /Users/you/src/shop                 main to cace5d6
2026-11-12T05:12:46Z  gc-run  gc
```

## What onetree installs per agent

| Agent | Installed when | Guard | Session notice | Rules block | Approval |
|---|---|---|---|---|---|
| Claude Code | always | PreToolUse hook in `~/.claude/settings.json` | SessionStart hook; WorktreeCreate/Remove hooks for the app's Worktree toggle | `~/.claude/CLAUDE.md` | none |
| Codex | `~/.codex` exists | PreToolUse hook in `~/.codex/hooks.json` | SessionStart hook | `~/.codex/AGENTS.md` | `/hooks` in Codex, again after an update changes them |
| pi | `~/.pi/agent` exists | `~/.pi/agent/extensions/onetree.ts` | the same extension | `~/.pi/agent/AGENTS.md` | none |
| dsh | `~/.dsh` exists | `~/.dsh/onetree-plugin.mjs`, loaded from `~/.dsh/cordis.patch.yml` | the same plugin | `~/.dsh/AGENTS.md` | none |

Every install also writes the shell wrappers (`~/.onetree-agents.sh`, sourced
from `~/.zshrc`, and from `~/.bashrc` when it exists) and the hourly
`onetree gc --all` (launchd on macOS, cron on Linux). The rules block sits
between `<!-- onetree:start -->` and `<!-- onetree:end -->`; your own text in
those files is kept.

## Commands

```
Repos
  init [repo] [--guard|--no-guard] [--integration B] [--root D] [--branch-prefix P] [--copy "f g"] [--keep "f g"]
       [--keep-source D] [--bootstrap CMD] [--stale H] [--file] [--remote R] [--push-remote R] [--gh-user LOGIN]
       [--writable "f d/"|--writable-add "f"|--writable-remove "f"] [--exclude-writable]
       [--lock-ignored|--no-lock-ignored] [--carry <slug> [--carry-untracked]]
  repos | unregister [repo] | info [repo] [--json] | snippet [repo]
Worktrees
  new <slug> [repo] | carry <slug> [repo] [--untracked] | review <branch>|<PR> [repo]
  ls [repo|--all] [--json] [--fresh] | rm <slug> [repo] [--force]
  gc [repo|--all] [--dry-run] [--json] [--fresh] | park [repo|--all] | bootstrap [path]
Agents
  launch [--task <slug>] <agent> [args…] | resume [slug|session] [repo] | agents [--json]
Visibility
  events [--json] [--since 24h|7d|<epoch>] [--kind K] [-n N] | snapshot [repo|--all] [--fresh]
  ui [--port N] [--no-open] [--ttl S] [--interval S] [--fixture F]      (a local dashboard on 127.0.0.1; Node 22.6+)
Machine
  install | update | uninstall | doctor [--json] | rules | version
Hooks and adapters (called by agents and wrappers, not by hand)
  guard | session | hook-create | hook-remove | auto <agent>|--check
```

`[repo]` is a registered repo's directory name or any path inside a checkout;
omitted, it is the repo that owns the current directory. Every setting, the
guard's exact rules, fork clones, dependency handling and the JSON output are
in [docs/reference.md](docs/reference.md). [docs/why.md](docs/why.md) has what
went wrong behind each rule, and [docs/design/](docs/design/) the larger
decisions, including an approach measured and dropped.

## What it is not

onetree is not a worktree manager for a person at a terminal. If you want to
switch between worktrees by hand, pick one from a list, and merge locally,
[Worktrunk](https://worktrunk.dev) does that well. onetree is for the case
where the agents drive themselves, the merge path is the pull request, and
the main checkout has to survive all of it.

## Why bash

The tool runs inside agent hooks on every tool call, and from an hourly job.
One file that needs only bash, git, jq, gh and standard Unix tools, with no
runtime to install and nothing to build, is what makes `onetree install` a
copy. The guard's parser is the one part that would be nicer in another
language.

## Tests

```
bash tests/run.sh                    # hermetic end-to-end: temp HOME and registry, local bare origin, no GitHub
cd ui && npm ci && npm run verify    # typecheck and test the dashboard; fails if the committed build is stale
```

The guard's cases are tables of `allow` and `block` per command shape
(`guard_table` in `tests/run.sh`). CI runs the end-to-end suite on Ubuntu and
macOS, the dashboard checks on Ubuntu, and shellcheck.

## Limits

- Cleanup asks GitHub through `gh`. Without it, gc still removes worktrees
  whose head is an ancestor of the integration branch, but can't see
  squash-merged PRs.
- The guard is a command parser, not a sandbox. It stops the mistakes agents
  make in normal work, not a determined adversary; a program an agent starts
  runs as you and can write wherever you can. See [SECURITY.md](SECURITY.md).

## License

MIT
