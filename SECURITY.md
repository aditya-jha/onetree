# Security

onetree installs hooks that every agent session runs, makes tracked files
read-only and removes worktrees on a schedule. A bug in any of those can let
an agent change what it shouldn't, or lose someone's work.

## Reporting

Please report privately, through GitHub's
[private vulnerability reporting](https://github.com/aditya-jha/onetree/security/advisories/new),
not in a public issue. Include the onetree commit, your OS, and the command or
tool call that shows the problem. You should hear back within a week.

## What counts

- A way for an agent to change a guarded main checkout, or switch the guard
  off, that the guard lets through.
- gc, `rm`, `carry` or `park` removing or overwriting work that wasn't pushed.
- A hook, wrapper or the dashboard running a command, or exposing data, that
  it shouldn't. The dashboard listens only on 127.0.0.1.

The guard is a safety net for agents, not a sandbox. It judges the tool calls
an agent makes through its hooks. A program the agent starts in a worktree
runs as your user and can write anywhere you can, and anything running as your
user can undo what onetree set up. Reports that come down to that are not
vulnerabilities, but a clearer warning in the docs is always welcome.

## Supported versions

Only the latest release gets fixes.
