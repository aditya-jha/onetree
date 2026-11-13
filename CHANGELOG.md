# Changelog

## Unreleased

- `onetree new` and `carry` record the new worktree as trusted in
  `~/.claude.json` when Claude already trusts its main checkout. The Claude
  desktop app asked for workspace trust on every `change_directory` into a
  worktree, and after five minutes without an answer the move failed with
  "Couldn't move the session to …": a session that ended its turn while a
  background agent worked never moved. A `review` checkout is not recorded.

- A dsh session started in the browser on a guarded main checkout gets its
  worktree with no step by the user or the agent. Nothing made one (the web UI
  picks the session's folder, so the shell wrapper never ran), the first script
  was refused, and the agent could not follow the refusal: dsh's sandbox
  stopped `onetree new` at `~/.config/onetree/config: Operation not permitted`
  (#20). The dsh plugin now runs `onetree auto dsh` when dsh announces the
  session, grants the session's sandbox the worktree and its git folders,
  moves the session's working directory there and tells it once; the guard
  judges a call in that working directory. It does this at startup, resume,
  clear and compact. `onetree auto <agent>` with `ONETREE_SESSION_ID` (else
  `DSH_SESSION_ID`) set binds the worktree to that session and returns the
  same one when asked again, and never gives a session a folder or branch
  that already exists; the shell wrappers are unchanged. The plugin moves a
  session only after every grant is made, and retries before each tool call
  until then. The plugin's
  session hint had never been shown: it listened to `agent/session-start`,
  which dsh does not emit (the event is `agent/created`). The hint and a
  refusal now say "this session works in <worktree>" once it is moved, and no
  longer that a dsh session cannot change its folder. The web UI still lists
  the session under the folder it was created in. Run `onetree update` to
  rewrite the plugin.
- A sandboxed dsh can commit in its worktree. dsh's `workspace-write` sandbox
  (the headless default) kept the worktree's git directory read-only, so
  `git commit` failed on `index.lock`; onetree granted those folders to Codex
  at launch and to dsh not at all. The dsh plugin now grants a session in a
  worktree what `onetree codex-grants` lists, through dsh's own per-session
  grant, for every profile. `codex-grants` prints nothing for a main checkout
  (it used to list `.git` itself). Run `onetree update` to rewrite the plugin.
- dsh started as `pnpm dsh web` (`node … apps/cli/src/bin.ts`, a relative path
  with no "dsh" in it) still got the generic next step in a refusal. The guard
  now takes the agent from what the dsh plugin (or the pi extension) sends, and
  `onetree new` run from a dsh shell command knows dsh by the `DSH_SESSION_ID`
  dsh sets. The same id binds the new worktree to the dsh session, so a later
  refusal says "this session already has a worktree" and names it.
- dsh run from its source checkout (`node … deepseek-harness/apps/cli/src/bin.ts`,
  what `pnpm dsh` and a wrapper around it start) is recognised as dsh, so
  `onetree new` and the guard give it dsh's next step (`workdir`) where it got
  the generic one, or Claude's when started from a Claude shell.

- Claude CLI, IDE and SDK sessions are no longer told to call `EnterWorktree`
  after `onetree new`; like every other agent they prefix commands with
  `cd <worktree> &&` and edit by absolute path, and the rules say never to
  call it. `EnterWorktree` binds the session to that worktree, and Claude Code
  then refuses any shell command with git in it that it cannot verify (a
  `$(…)`, a loop, a variable), in the session and all its subagents: one
  session took 153 refusals after a single call (#15). Run `onetree update`
  to refresh the rules block in `~/.claude/CLAUDE.md`.
- The guard judges an interpreter by the script it runs, not by every
  argument. `python3 tools/x.py --repo <main checkout>`, run from a worktree,
  was refused as "running a mirror script by path" although the path was data;
  and `python3 -u <main>/x.py`, `node --inspect server.js` in a main checkout
  and `npm --prefix=<main> run build` passed, because an option came first.
  Now the script is the first word that is no option, `npm` is judged by its
  subcommand and `--prefix`, and `python3.12` counts as python (#15).
- `onetree new` in a session that cannot write the main checkout's `.git` (a
  Codex under `workspace-write`, whose sandbox is fixed at launch) says so and
  names `onetree launch --task <slug> <agent>`, where it used to die on git's
  "could not lock config file".

## 1.1.0 (2026-11-12)

Install without cloning, and updates that follow releases instead of `main`.

- `install.sh`: `curl -fsSL https://raw.githubusercontent.com/aditya-jha/onetree/main/install.sh | bash`
  clones the newest release into `${ONETREE_HOME:-~/.local/share/onetree}` and
  runs `onetree install`; rerunning it updates in place. It refuses a folder that
  holds anything but an onetree checkout.
- `onetree update` follows releases: a release install moves to the newest
  `vX.Y.Z` tag, a contributor clone still fast-forwards its branch, and a
  Homebrew install prints the `brew upgrade` command instead of changing anything.
  On 1.0.0, a release install's `update` still pulls `main` and fails: rerun
  `install.sh` once to reach 1.1.0.
- `onetree version` adds `(dev <short sha>)` when run from a clone that is not at
  a release tag.
- Docs: the README installs with `install.sh` first and the clone second, with
  one update line for each. `RELEASING.md` is the release procedure, written
  as commands with a check after each. `AGENTS.md` (loaded by `CLAUDE.md`) holds
  the rules for changes, and `CONTRIBUTING.md` points to it.

## 1.0.0 (2026-11-12)

First public release: guarded main checkouts, one-command worktrees with
dependencies in place, PR-aware hourly cleanup, and hooks for Claude Code,
Codex, pi and dsh. See [README.md](README.md) for what each part does.
