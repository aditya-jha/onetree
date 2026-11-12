# onetree: rules for agents (and people)

onetree is one bash script, `bin/onetree`, plus a dashboard under `ui/`.
`CONTRIBUTING.md` explains the tests and where things live.

- **Gates**, all green before a PR: `bash tests/run.sh`,
  `shellcheck -S warning bin/onetree tests/run.sh` (and `shellcheck install.sh`),
  `cd ui && npm run verify`.
- **bash 3.2:** no associative arrays, no `${var,,}`, no `mapfile`, no `;&`.
  macOS may run the script under `/bin/bash`. `install.sh` is POSIX `sh`.
- **Tests:** one assertion per behaviour; a table of cases where several inputs
  share a rule. A guard change is a `guard_table` row (`allow`/`block`) per
  command shape. Prove a new test by making it fail on a mutant.
- **CHANGELOG:** a line under `## Unreleased` for every user-visible change.
- **docs:** update `docs/reference.md` when a command, setting or rule changes.
- **Releases** only through `RELEASING.md`.
- **Never push to `main` or force-push.** Open a PR and wait for its CI to pass
  before merging.
