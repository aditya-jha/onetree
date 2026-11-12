#!/bin/sh
# onetree installer: puts the newest release in $ONETREE_HOME and runs its install. Rerun it to update.
#   curl -fsSL https://raw.githubusercontent.com/aditya-jha/onetree/main/install.sh | bash
# POSIX sh on purpose: it is piped into bash, but must work under sh (dash) too.
set -eu
REPO=${ONETREE_REPO:-https://github.com/aditya-jha/onetree.git}
DIR=${ONETREE_HOME:-$HOME/.local/share/onetree}
die() { printf 'onetree install.sh: %s\n' "$*" >&2; exit 1; }

for t in git bash; do command -v "$t" >/dev/null 2>&1 || die "$t is required: install it, then rerun this"; done

if [ -e "$DIR/.git" ] && [ -f "$DIR/bin/onetree" ]; then
  echo "updating the onetree checkout in $DIR"
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
  die "$DIR holds something that is not an onetree checkout; refusing to overwrite it (move it, or set ONETREE_HOME)"
else
  git clone -q "$REPO" "$DIR" || die "cloning $REPO into $DIR failed"
fi

git -C "$DIR" fetch -q --tags origin || die "fetching release tags into $DIR failed"
tag=$(git -C "$DIR" tag -l --sort=-v:refname 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
[ -n "$tag" ] || die "no vX.Y.Z release tag in $REPO"
git -C "$DIR" -c advice.detachedHead=false checkout -q "$tag" || die "checking out $tag in $DIR failed (local changes?)"

"$DIR/bin/onetree" install
echo
echo "onetree ${tag#v} is in $DIR. Next: onetree doctor. To update later: onetree update (or rerun this)."
