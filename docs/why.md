# Why onetree works the way it does

Some of onetree's rules came from things that went wrong in real use, and
some from reviews that found a hole before it cost anything. Each section says
which. Dates are in 2026 and mark when the change landed.

## Agents sharing one checkout (September)

Two agents in one checkout share a branch, an index and the working files. A
branch switch or a stash by one changes what the other is working on, and two
sessions on one branch can push over each other. Instructions in an AGENTS.md
ask an agent to avoid that; nothing stops it.

So the first version did two things. A PreToolUse hook refuses changes to the
main checkout, and one command gives each task its own worktree and branch.

## Ignored files gc could delete (14 September)

`git status` says nothing about gitignored files. A clean worktree can hold
the only current copy of one, such as a private config, and removing the
worktree deletes it. `keep` lists such files, and gc keeps a worktree whose
copy differs from the one in `keepSource`.

## Writes the hook never sees (19 September)

The hook judges the tool calls an agent makes. An editor saving a file, or a
program the agent started, writes without asking it. Guarded main checkouts
became read-only on disk as well, and onetree unlocks them only for its own
controlled steps, such as fast-forwarding the checkout (`park`).

## Matching text instead of commands (22 September)

A review found that the first guard matched patterns against the whole
command line. `echo git stash` was blocked, and a mutation after `;` or
inside `bash -c` could get through. The guard became a parser: it splits the
line into simple commands, judges each in command position, follows `cd` and
`git -C`, and parses `bash -c` and `eval` as nested commands. Literal quoted
arguments are data; a command substitution inside quotes is still judged.

## gc discarded uncommitted work (13 October, observed)

A main checkout was guarded while it had uncommitted changes. gc's park step
took the dirty state for a half-finished branch switch and ran
`git switch -f`, which discarded the change. gc now leaves a dirty guarded
checkout alone, and `carry` moves that work into a worktree first, checking
the copy byte for byte before it restores the main checkout.

## Locking ignored files broke the repo's tools (13 October, observed)

Guarding a Node repo locked every file, ignored ones included. `npm ci` failed
on `node_modules/`, husky couldn't rewrite its hook, the pre-push typecheck
couldn't write `.tsbuildinfo`, and the agent couldn't save its own settings.
The lock now covers only what git tracks or would track. By default, ignored
paths stay writable: they are the tools' working state, not task work.

## A stale node_modules looked fresh (13 October, observed)

The lockfile was fast-forwarded to add a package, but the main checkout's
`node_modules` had been installed three weeks earlier. The lockfiles matched,
so every new worktree cloned the stale tree and failed its typecheck. The check
now compares what npm recorded installing against the lockfile, entry by
entry, and gc keeps a guarded checkout's dependencies current by installing in
a scratch directory and swapping the result in.

## A checkout that production runs from (20 October)

One repo's main checkout was also where its scheduled jobs ran. They rewrote
tracked files, committed everything in the checkout and pushed, which could
include unfinished development work. Guarding that checkout would have made
those writes fail, and `writable` can't help because the files are tracked.

Letting production jobs write through the guard was considered and rejected:
it would have made onetree responsible for how another application publishes.
Instead, production stays unregistered and development moves to its own
guarded clone. The same review found two holes in onetree. The guard let an
agent run any `onetree` command, `uninstall` included, and an agent in
production was invited to onboard it. Both are fixed. The details and limits
are in [design/production-checkouts.md](design/production-checkouts.md).

## What it doesn't do

onetree protects a main checkout from the mistakes agents make in normal
work. It is not a sandbox: a program running as your user can still write
wherever you can.
