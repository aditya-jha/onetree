# A dsh session gets its worktree from the plugin

**Status:** built 2026-11-13 (#20); checked against a fake dsh host in
`tests/agents.mjs`, not yet in a real browser session.

**In one line:** when dsh announces a session whose folder is a guarded main
checkout, onetree's plugin makes its worktree, opens the sandbox to it and
moves the session's working directory there.

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

At `agent/created` (startup, resume, clear, compact), for a session whose
folder is a guarded main checkout, the plugin:

1. runs `onetree auto dsh` there with the session's id in the environment. A
   plugin runs in dsh's server process, outside the sandbox. The call is
   asynchronous with a ten-minute limit: dsh holds the session's queued input
   until the listener returns, and a synchronous spawn would stop the server
   for every session while bootstrap runs;
2. registers the worktree, by real path, and each `onetree codex-grants`
   directory as writable roots of the session. The sandbox's own root stays
   the session's folder, grants are lost on resume, and dsh fails a call over
   a root that is a symlink alias;
3. sets the session's working directory to the worktree
   (`workingDirectory.set`), unless it is already inside it. dsh's bash and
   file tools resolve against that directory, and dsh records it in the
   session, so it survives a resume;
4. injects `onetree session`'s hint, which names the worktree, its
   placeholder branch and the read-only main checkout.

The guard is then sent the session's working directory
(`workingDirectory.ensure`, the call dsh's own tools make) instead of its
folder; a bash call's `workdir` still wins.

`onetree auto` with a session id binds the worktree as `new` does (the `new`
event carries the session) and is idempotent per session through
`bound_worktrees`, so every later announcement ends in the same state without
a second worktree. A subagent's session is created in its parent's folder; the
plugin asks under the parent's id, so it shares the parent's worktree.

If `auto` fails or times out, the session stays where it is, the guard still
protects the main checkout, and the injected message says what failed. Without
the `workingDirectory` service the worktree is still made and the hint says to
pass `workdir`; without `sandboxPolicy` nothing is granted.

## What was rejected

- **Making the worktree on the first refused call.** A question-only session
  would get none, but the agent would see one refusal first, and
  `tools/pre-execute` cannot rewrite the refused call (its arguments are
  frozen). Every other agent gets its worktree at launch, and `gc` removes a
  placeholder with no commits after the stale window.
- **Letting the agent run `onetree new` with broader grants.** It would mean
  granting the sandbox onetree's registry and the whole worktrees root.
- **A second registry of session-to-worktree.** The event log already binds
  worktrees to sessions for the guard's refusal text.

## Known limits

- The web UI lists the session under the folder it was created in, so its
  file pane shows the main checkout. dsh fixes a session's folder at creation.
- The parent-of-a-subagent lookup is kept in the plugin's memory: a subagent
  of a subagent resumed alone after a server restart gets its own worktree.
- A timeout stops `onetree auto`, not a bootstrap command it started.
