# Production checkouts

**Status:** shipped.

**In one line:** a checkout that production runs from is never guarded.
Development gets its own clone, and that clone is guarded.

## The problem

Some repos are also where production lives. Their scheduled jobs run from the
main checkout, rewrite tracked files such as positions or reports, commit them
and push. Services start from paths inside it, and AI jobs work in it.

Guarding that checkout breaks all of it:

- the guard makes tracked files read-only, so the jobs' writes fail;
- gc fast-forwards a guarded checkout to the latest `main` (it "parks" it),
  which can change files under a job that is running;
- every session there is told to stop and make a worktree, scheduled AI jobs
  included.

`onetree.writable` can't make room for this, because it only covers gitignored
paths and these outputs are tracked.

## The decision

Split production and development by checkout:

| Checkout | What onetree does with it |
|---|---|
| Production: the existing checkout, where services and jobs already run | Leaves it alone: not registered, never guarded, marked as production |
| Development: a new, separate clone of the same remote | Guards it like any other repo |
| Worktrees of the development clone | The normal lifecycle |

Nothing in production moves, so no service path, environment, permission or
schedule has to change. Only development moves, and moving development into
worktrees is what onetree already does. The setup steps are in
[reference.md](../reference.md#production-checkouts).

Four changes to onetree made this safe:

- **An agent can't switch the guard off.** Before, the guard let any `onetree`
  command through, including `uninstall` and `init --no-guard`. Now an agent is
  refused anything that removes a guard or unregisters a repo, and any direct
  write to onetree's settings, whatever folder it runs from. Reads, `new` and
  `init --writable-add` still pass.
- **A production marker.** An unregistered checkout normally gets an offer to
  onboard it, which is the worst advice for an agent sent into production to
  fix an incident. `onetree.production=true` in the checkout's own
  `.git/config` replaces that offer with a notice: this is production, inspect
  it but don't change it, and the development clone is over here. `onetree init`
  refuses such a checkout. A committed or global value is ignored, so the
  marker can't leak into other clones.
- **Scheduled jobs are left alone.** A non-interactive session outside a
  registered repo hears nothing from onetree, and the rules onetree adds to each
  agent's global instructions say they never tell a scheduled job to onboard,
  make a worktree or stop.
- **One-shot commands run where they're typed.** `claude -p`, `codex exec` and
  `codex login` are never moved into a worktree. In a guarded checkout they
  still get no exemption from the guard.

## Rejected

**A publisher role in onetree.** The first design let registered production
jobs write through the guard, with a transaction controller, a shared lock and
a conflict resolver. That would have made onetree responsible for how another
application publishes its output, and given the guard a door that agents could
learn to use. What production writes, how its writers take turns and what
happens on a conflict belong to that application.

## What it doesn't solve

The split is a habit, not a permission. An agent running as the same OS user
can still write to the production checkout by its absolute path. Real isolation
needs a separate user or a sandbox.
