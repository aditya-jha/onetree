# A dsh session gets its worktree from the plugin

**Status:** built 2026-11-13 (#20) in its third, smaller design (see "What was
dropped"); checked against a fake dsh host in `tests/agents.mjs`, not yet in a
real browser session.

**In one line:** onetree's dsh plugin follows the session's own working
directory: in a guarded main checkout it makes a worktree and moves the
session there, in a worktree it opens the sandbox to it, and it keeps no
record of which session has which worktree.

## The problem

A dsh session made in the web UI takes its folder from the browser, so the
shell wrapper that gives every other agent a worktree at launch never runs.
The first script the agent ran in a guarded main checkout was refused, and the
agent could not do what the refusal said: dsh runs tools in a
`workspace-write` sandbox, and `onetree new` writes `~/.config/onetree/config`
and the worktrees root, both outside it. The owner had to make the worktree in
a terminal and start the session there.

The plugin's session hint had also never run: it listened to
`agent/session-start`, which dsh does not emit. The lifecycle event is
`agent/created`.

## The decision

dsh stores a session's working directory in the session itself (the folder in
its header never changes) and restores it on resume and in a fork; when the
stored directory no longer exists, dsh puts the session back in the folder it
was created in. The plugin reads that directory and nothing else.

When dsh announces a session (`agent/created`):

1. **Working directory in a guarded main checkout:** the plugin runs plain
   `onetree auto dsh` there, the command the shell wrapper runs (`auto`
   binds its worktree to no session). A plugin runs in dsh's server process,
   outside the sandbox. The call is asynchronous with a ten-minute limit: dsh
   holds the session's queued input until the listener returns, and a
   synchronous spawn would stop the server for every session while bootstrap
   runs. It then registers the worktree, by real path (dsh fails a call over a
   root that is a symlink alias), and each `onetree codex-grants` folder as
   writable roots of the session, all of them or none: if `codex-grants`
   fails or a registration throws, the ones made are taken back. Only then
   does it set the session's working directory to the worktree
   (`workingDirectory.set`), and it injects one message.
2. **Working directory already inside a worktree** (a resume, a fork, a
   session started through the shell wrapper): the plugin opens that worktree
   (its root from `git rev-parse --show-toplevel`) and its `codex-grants`
   folders in the sandbox. Nothing is made and nothing is moved.
3. **A subagent** (`origin: "subagent"` in the session's header): dsh already
   starts a new subagent in its parent's working directory. One it left in
   the folder of its header is put where its parent works, when the parent is
   a session the plugin has seen announced; then case 2 applies. A subagent
   never gets a worktree of its own.

Before every tool call the plugin opens the worktree the session's working
directory is in, if it has not yet for this live session: the grants are lost
on resume, a first attempt may have failed, and the directory can change
during a session. A worktree made in case 1 and not entered yet is tried
again first, and entered once its grants are made. The guard is then sent
that working directory (`workingDirectory.ensure`, the call dsh's own tools
make); a bash call's `workdir` still wins.

The injected message says which state the session is in: it works in a
worktree (the path and its branch); no worktree could be made, so it stays in
the main checkout (the reason, and how to work in a worktree by hand); a
worktree was made at a path but the session was not moved (the reason, and
that it is tried again before each call).

`onetree session` and the guard's refusal go by the working directory the
plugin sends: inside a worktree of the checkout, they say the session works
there and to leave `workdir` out.

## What it does not promise

- **A fork shares its source's worktree.** It continues where the source was,
  as a forked session does in every other agent.
- **The sandbox is the enforcement for writes.** If a worktree's folders
  cannot be opened, the plugin says so and tries again before each call; it
  does not refuse calls itself. Writes then fail in the sandbox, as they do
  for any folder that is not granted.
- **No per-session bookkeeping.** `onetree auto` is what it is on `main`: a
  worktree named `<agent>-<timestamp>`, no lock, no ownership record. A
  session whose worktree was removed (by `gc` after its PR merged, or by hand)
  and is then resumed finds its working directory gone, starts from the folder
  it was created in, and gets a new worktree by case 1.
- **A worktree made but never entered is not remembered across a restart.**
  The plugin keeps it for the live session only; the same session resumed in
  a new server process gets another, and `gc` removes the first, which has no
  commits, after the stale window.
- **Without the `workingDirectory` service** nothing is made: the session
  cannot be moved, so it gets the guard and the hint. Without `sandboxPolicy`
  there is no sandbox to open, and the session is moved all the same.

## What was dropped

The first two versions bound a worktree to a session: `auto` took a session
id, named the worktree after its hash, made it under a lock, wrote an
ownership event before the folder existed, and the plugin denied calls in a
worktree whose grants were not complete. Three reviews found thirteen defects
in that machinery (a stale ownership event handed one session another's
worktree; `cd <worktree> && …` slipped past the plugin's denial; the lock was
released twice; a fork of a wrapper-started session shared its worktree
anyway), and each fix added more of it. All of it is gone. The problem needs
a browser session to end up in a worktree it can write to, and the session's
own working directory already says where it is.

## What was rejected

- **Making the worktree on the first refused call.** A question-only session
  would get none, but the agent would see one refusal first, and
  `tools/pre-execute` cannot rewrite the refused call (its arguments are
  frozen). Every other agent gets its worktree at launch, and `gc` removes a
  placeholder with no commits after the stale window.
- **Letting the agent run `onetree new` with broader grants.** It would mean
  granting the sandbox onetree's registry and the whole worktrees root.

## Known limits

- The web UI lists the session under the folder it was created in, so its
  file pane shows the main checkout. dsh fixes a session's folder at creation.
- Grants follow the working directory. A bash call that names another
  worktree as its `workdir` is judged there by the guard, but that worktree is
  not opened in the sandbox.
- A subagent's parent is looked up among the sessions announced in this
  server process. dsh places a new subagent itself, so this matters only
  where it did not.
- A timeout stops `onetree auto`, not a bootstrap command it started.
