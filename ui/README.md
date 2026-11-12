# onetree dashboard

A loopback page over `onetree snapshot`: what gc will and will not do, the
decisions it leaves to you, which agent sessions are alive and where, what
the guard refused, and whether the install is healthy. One tab per question.

```
onetree ui                                       # serve the committed build and open it (127.0.0.1:7180, a per-run token in the URL)
onetree ui --port 8080 --no-open
onetree ui --ttl 30 --interval 30                # a snapshot is fresh for 30 s; check every 30 s while the page is open
onetree ui --fixture ui/fixtures/snapshot.json   # the sample data instead of `onetree snapshot`
```

The server is `server.ts`: node's `http` module, no dependencies, run by
`onetree ui` with `node --experimental-strip-types`. It answers `/api/snapshot`,
`/api/health`, `POST /api/action`, and serves `dist/`. GET calls take the
token as `Authorization: Bearer` or `?t=`.

The first request waits for a snapshot. After that, `GET /api/snapshot`
answers with the last one at once and, when it is older than `ttl` seconds,
starts a new run behind the answer; every `interval` seconds, for ten minutes
after the last request, the server starts one when the snapshot is older than
`ttl`. The calls that wait are `?refresh=now` (a new run; the page uses it after an action) and
`?refresh=full` (a run that also bypasses onetree's own caches of PR states,
fetches and the doctor report; the Refresh button). The response carries
`x-snapshot-age` and `x-snapshot-refreshing`, and the header shows "updating"
while a run is in progress.

## What the page can run

`POST /api/action` runs one of five things and nothing else: `rm` (a
worktree named by slug and repo, optionally `--force`, optionally after
ending listed sessions), `kill` (sessions by pid), `gc` (`--all`, optionally
`--dry-run`), `doctor`, `unlock` (a worktree by path). Every argument is
checked against the last snapshot: a slug that is not a worktree, a pid that
is not a session, a path that is not a worktree are refused with 400. The
request needs the token in the `Authorization` header and a JSON body, so a
page on another origin cannot send one (a browser will not attach that header
cross-origin without a preflight, which the server does not answer). The
server invalidates its snapshot cache after every action, and it runs only
`onetree`, `git` and `kill`. Actions are disabled while serving a fixture.

In the page, dark buttons run after a confirmation that shows the exact
command; light buttons copy a command for the things the page can't or
shouldn't do itself (open a terminal, show a diff, open a PR, guard a repo).

Agents uses the same verbs. A session sharing an unguarded checkout can be
ended, one pid at a time. A session in a merged worktree is ended and the
worktree removed, the same action Inbox offers. A Codex Desktop controller
is not killable. A session outside every registered repo is not ended
from the page. `onetree init --guard` stays a copied command. Inbox, Agents and
Health badge a count when something there needs a person. A link that says
decide, agents or Inbox puts that row's path in the hash and scrolls to it.

## Working on it

Node 22.6+.

```
cd ui
npm ci
npm run serve        # the API on the fixture, port 7180
npm run dev          # Vite on 5173, proxying /api to 7180; open http://localhost:5173/?t=<token from serve>
npm run verify       # typecheck, build, tests, and that dist matches src
```

`dist/` is committed so `onetree ui` needs no npm at runtime. After changing
`src/`, run `npm run build` and commit `dist/` with the change;
`npm run check:dist` fails when they drift.

Tests use node's own runner: `src/lib/derive.test.ts` covers the derivation
of every screen from `fixtures/snapshot.json`, `server.test.ts` starts the
server on a random port against the fixture.

## Layout

```
src/lib/types.ts       the snapshot schema (docs/snapshot.md)
src/lib/derive.ts      screens as pure functions of a snapshot: states, decisions, invariants, tallies
src/screens/*.tsx      Fleet, Inbox, Agents, Guard, Health
src/components/ui.tsx  pills, buttons, tables, the copy-to-clipboard button
src/theme.css          tokens: roles over a neutral palette, system fonts, light only
fixtures/snapshot.json an anonymised snapshot of a real machine plus a day of synthetic events
```
