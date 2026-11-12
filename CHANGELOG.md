# Changelog

## Unreleased

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
