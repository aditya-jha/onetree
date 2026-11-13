# Sessions follow their worktree

**Status:** shipped; revised 2026-11-13: the Claude CLI no longer moves with `EnterWorktree` (see "What was dropped"), and a dsh session is moved by onetree's plugin ([dsh-session-worktree.md](dsh-session-worktree.md)).

**In one line:** where onetree can, it starts an agent inside its worktree.
Where it can't, it tells the agent exactly how to work there.

## The problem

A Claude desktop session started in a guarded main checkout, ran
`onetree new`, then `EnterWorktree`. Claude Code moved into the worktree; the
app around it did not. The file pane refused the worktree's files ("outside
this session's folders"), and the diff, terminal and PR card stayed on the main
checkout. The app only follows a move into `<repo>/.claude/worktrees/`, and
onetree's worktrees live under `~/worktrees`.

Each agent onetree supports has the same root cause. The host decides a
session's folder when the session starts, and onetree moves the work after
that, without telling the host.

| Agent | Can a running session change folder? | What stays on the old folder |
|---|---|---|
| Claude CLI | yes, `EnterWorktree` with a path, at the cost below | nothing |
| Claude desktop app | yes, with `change_directory` | nothing, but `EnterWorktree` leaves the panes behind |
| Codex CLI | only if the user types `/cd`, which starts a new thread | instructions, resume list, sandbox |
| Codex app | no; the user opens a new thread on the worktree | review pane, sandbox |
| pi | no | resume list, project trust |
| dsh | its working directory yes (a plugin can set it), its folder no | web UI workspace, the sandbox's own root |

## The decision

**Start in the worktree when onetree launches the agent.** The shell wrappers
(`claude`, `codex`, `pi`, `dsh` in a guarded repo) and `onetree launch` make
the worktree first and start the agent inside it, so nothing has to move.
Claude starts in the folder and not through `claude --worktree`: that flag
binds the session to the worktree, and Claude Code then refuses any shell
command it can't prove stays inside it.

**Otherwise, say the next step for that host.** `onetree new`, `carry` and
`review` print the move that works for the agent that ran them:
`change_directory` in the Claude app, and `cd <worktree> &&` before every
command anywhere else, the Claude CLI included. When
the guard refuses a change, it names the worktree that session already has.

**Judge work by where it lands, not where the session sits.** An agent that
can't move edits by absolute path and passes `workdir` to its commands. The
guard checks the files a patch names and the folder a command runs in, so that
work is allowed in the worktree and refused in the main checkout.

**Guard every agent the same way.** pi's extension runs a session's commands
in its worktree, dsh gets a guard plugin, and Codex runs a hook only while it
matches the version the user approved, so `doctor` checks that approval and
`install` doesn't disturb it.

**Find the worktree again later.** `onetree resume` reopens a session's
worktree, recreating it if gc has removed it, and gc leaves worktrees made by
other tools alone.

## What it doesn't solve

- Codex and dsh keep their panes on the folder the thread started in.
- Codex's hook never sees `workdir`, so a Codex command has to `cd` into the
  worktree for the guard to judge it there.
- An agent that can't move still reads its instructions and config from the
  main checkout.

## What was dropped

**`EnterWorktree` in the Claude CLI** (issue #15). It moves the session, and it
also binds it: Claude Code marks the session worktree-isolated and refuses any
shell command with git in it that it cannot verify statically (a `$(…)`, a loop,
a variable), in the main conversation and in every subagent, whichever
worktree the command targets. One long session took 153 such refusals after
its one `EnterWorktree` and none in the 105 commands before it. The binding
protects nothing onetree needs: a plain `cd <other worktree> && git commit`
still runs. A second `EnterWorktree` is refused until `ExitWorktree`. It is
the same binding as `claude --worktree`, which `onetree launch` already
avoided. Telling agents to "run one plain command per call" was tried first
and did not hold across a long session.
