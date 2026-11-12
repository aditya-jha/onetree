#!/bin/sh
# Fails when ui/dist is not what ui/src builds to. dist is committed so `onetree ui` needs no npm at runtime;
# after changing src, run `npm run build` and commit dist with it.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
npx vite build --outDir "$tmp" --emptyOutDir >/dev/null 2>&1
if diff -r "$tmp" dist >/dev/null 2>&1; then
  echo "dist is up to date"
else
  echo "dist is stale: run npm run build and commit ui/dist" >&2
  diff -rq "$tmp" dist >&2 || true
  exit 1
fi
