# Releasing onetree

A release is a `vX.Y.Z` tag on `main` plus a GitHub release. `install.sh` and
`onetree update` (on a release install) both take the newest `vX.Y.Z` tag, so
pushing the tag is what ships. Run these steps in order and run the check after
each one. Stop if a check fails.

An agent runs steps 4 and 5, which publish, only when the owner has asked for
this release.

## 1. Choose the version

- **patch** (`X.Y.Z+1`): fixes only;
- **minor** (`X.Y+1.0`): new commands or settings;
- **major** (`X+1.0.0`): anything that breaks an existing setup, or the
  `--json` / snapshot schema (`docs/snapshot.md`).

Decide from `## Unreleased` in `CHANGELOG.md`. Below, `V=X.Y.Z` is set in
every shell.

## 2. Prepare the release PR

```sh
onetree new release-$V onetree && cd ~/worktrees/onetree/release-$V   # the path onetree new prints
sed -i.bak "s/^VERSION=.*/VERSION=$V/" bin/onetree && rm bin/onetree.bak
(cd ui && npm version "$V" --no-git-tag-version)     # ui/package.json and ui/package-lock.json
```

In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z (YYYY-MM-DD)`, with
today's UTC date, and add a new empty `## Unreleased` above it.

Check: every gate passes. The suite's `version:` test fails unless
`bin/onetree`, `ui/package.json` and the CHANGELOG heading agree.

```sh
bash tests/run.sh && shellcheck -S warning bin/onetree tests/run.sh && shellcheck install.sh && (cd ui && npm run verify)
```

```sh
git commit -am "onetree $V" && git push -u origin HEAD
gh pr create --repo aditya-jha/onetree --base main --title "onetree $V" --body "Release $V. See CHANGELOG.md."
```

## 3. Merge it once CI passes

```sh
gh pr checks <PR> --repo aditya-jha/onetree --watch && gh pr merge <PR> --repo aditya-jha/onetree --squash
```

Check: `gh pr view <PR> --repo aditya-jha/onetree --json state,mergeCommit` says `MERGED`; note the merge sha.

## 4. Tag the merge commit

```sh
git fetch origin
git show origin/main:bin/onetree | grep -x "VERSION=$V"   # must print the line
git tag -a "v$V" -m "onetree $V" <merge sha>
git push origin "v$V"
```

Check: `git ls-remote --tags origin "v$V"` prints the tag.

## 5. Publish the release

```sh
awk -v h="## $V " 'index($0, h) == 1 { p = 1; next } /^## / { p = 0 } p' CHANGELOG.md > "/tmp/onetree-$V-notes.md"
gh release create "v$V" --repo aditya-jha/onetree --title "onetree $V" --notes-file "/tmp/onetree-$V-notes.md"
```

Check: `gh release view "v$V" --repo aditya-jha/onetree` shows the notes.

## 6. Verify

```sh
d=$(mktemp -d) && git clone -q --depth 1 --branch "v$V" https://github.com/aditya-jha/onetree.git "$d/o" && "$d/o/bin/onetree" version   # onetree X.Y.Z
onetree update && onetree version   # on a release install (install.sh): onetree X.Y.Z
```

## Rules

- Never move or delete a published tag. A bad release is fixed by the next
  patch release.
- Release only from `main`, and only through a merged release PR.
