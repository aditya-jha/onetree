#!/usr/bin/env bash
# onetree tests. Hermetic: HOME and the registry live under a temp dir, origin is a local bare repo, gh has no login.
#   bash tests/run.sh                          exit 1 on any failure; its parts run in parallel
#   ONETREE_TEST_PART=serial bash tests/run.sh  every part in one process, in file order
# One assertion per behaviour: the facets of one operation are checked together, and a guard table names every case it got wrong.
# Parts (#28): `# ==== part N` starts a block of part N, which runs to the next mark. Each part is its own process with its own
# temp HOME: what precedes the first mark (helpers, fixture) and what follows `# ==== end` (the summary), then its blocks in order.
# A block that needs another's state goes in that block's part.
set -eo pipefail
if [[ -z "${ONETREE_TEST_PART:-}" ]]; then
  ONETREE_TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd -P); export ONETREE_TEST_ROOT
  PARTS=$(mktemp -d); trap 'rm -rf "$PARTS"' EXIT
  ids=$(sed -n 's/^# ==== part \([0-9][0-9]*\)$/\1/p' "$0" | sort -un); pids=""
  for n in $ids; do
    awk -v n="$n" '/^# ==== part /{inpart=1; keep=($4==n); next} /^# ==== end$/{inpart=0; next} !inpart || keep' "$0" > "$PARTS/$n.sh"
    ONETREE_TEST_PART=$n "$BASH" "$PARTS/$n.sh" > "$PARTS/$n.out" 2>&1 & pids="$pids $!"
  done
  pass=0 fail=0 rc=0; set -- $pids
  for n in $ids; do
    if wait "$1"; then st=0; else st=$?; fi; shift
    grep -v -E '^$|^[0-9]+ passed, [0-9]+ failed$' "$PARTS/$n.out" || true
    s=$(sed -n 's/^\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1 \2/p' "$PARTS/$n.out" | tail -1)
    if [[ -n "$s" ]]; then pass=$((pass + ${s% *})); fail=$((fail + ${s#* })); fi
    if [[ $st != 0 && ( -z "$s" || ${s#* } == 0 ) ]]; then fail=$((fail + 1)); printf 'FAIL  part %s stopped early (exit %s)\n' "$n" "$st"; fi
    [[ $st == 0 ]] || rc=1
  done
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit "$rc"
fi
ONETREE=${ONETREE_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}/bin/onetree
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME=$TMP ONETREE_CONFIG=$TMP/config ONETREE_EVENTS=$TMP/state/events.jsonl ONETREE_SESSIONS=$TMP/state/sessions ONETREE_SESSION_PID=$$ ONETREE_CACHE=$TMP/state/cache
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(CLAUDECODE$|CLAUDE_CODE_|CODEX_|DSH_)' || true)   # run from inside an agent, the suite must not inherit its host
export GIT_AUTHOR_NAME=onetree GIT_AUTHOR_EMAIL=onetree@test GIT_COMMITTER_NAME=onetree GIT_COMMITTER_EMAIL=onetree@test GIT_CONFIG_NOSYSTEM=1
cd "$TMP"

# a gh that answers nothing (so every PR is NONE) and logs each call, to count them
# macOS: /usr/bin/git is an xcrun shim costing ~15 ms a call, and the suite makes thousands (#28). Its own folder, not a
# symlink to it: a git reached through a symlink finds no templates. The /usr/bin python3, make and clang shims lead there too
if [[ "$(command -v git)" == /usr/bin/git ]] && GITDIR=$(dirname "$(xcrun -f git 2>/dev/null)") && [[ -x "$GITDIR/git" ]]; then PATH=$GITDIR:$PATH; fi
NODE=$(command -v node || true)   # the real node: later tests put fake agent processes, a node among them, first on PATH
mkdir -p "$TMP/bin"; export GH_LOG=$TMP/gh.log PATH=$TMP/bin:$PATH
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GH_LOG"' 'exit 0' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
gh_calls() { grep -c -e "$1" "$GH_LOG" 2>/dev/null || true; }

pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
json_is() {  # desc json filter — the jq filter must be true
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then ok "$1"; else bad "$1" "$(printf '%s' "$2" | jq -c . 2>/dev/null | head -c 800)"; fi
}
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected: $3 / actual: $2"; fi; }
has() { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "no line matches /$3/ in: $(head -c 300 <<<"$2")"; fi; }
has_all() {  # desc text ERE… — every pattern must match a line of text; names the ones that do not
  local desc=$1 text=$2 re miss=""; shift 2
  for re in "$@"; do grep -qE -- "$re" <<<"$text" || miss+=" /$re/"; done
  if [[ -z "$miss" ]]; then ok "$desc"; else bad "$desc" "no line matches:$miss in: $(head -c 400 <<<"$text")"; fi
}
guard_table() {  # desc cwd verdict command … — the guard's verdict on each case. verdict: allow, block, or block~ERE (the refusal must match it);
  local desc=$1 cwd=$2 v c j err got wrong=""; shift 2   # command: a shell line, Edit:<path> / Write:<path> for those tools, Patch:<text> (\n for newlines) for
  # apply_patch, or Wd:<dir>:<line> for a shell line with a workdir
  while [[ $# -ge 2 ]]; do
    v=$1; c=$2; shift 2
    if [[ "$c" =~ ^(Edit|Write):(.*)$ ]]; then j=$(jq -nc --arg cwd "$cwd" --arg t "${BASH_REMATCH[1]}" --arg fp "${BASH_REMATCH[2]}" '{tool_name:$t,cwd:$cwd,tool_input:{file_path:$fp}}')
    elif [[ "$c" =~ ^Patch:(.*)$ ]]; then j=$(jq -nc --arg cwd "$cwd" --arg p "$(printf '%b' "${BASH_REMATCH[1]}")" '{tool_name:"apply_patch",cwd:$cwd,tool_input:{command:["apply_patch",$p]}}')
    elif [[ "$c" =~ ^Wd:([^:]*):(.*)$ ]]; then j=$(jq -nc --arg cwd "$cwd" --arg wd "${BASH_REMATCH[1]}" --arg cmd "${BASH_REMATCH[2]}" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd,workdir:$wd}}')
    else j=$(jq -nc --arg cwd "$cwd" --arg cmd "$c" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}'); fi
    if err=$(ONETREE_NO_EVENTS=1 $ONETREE guard <<<"$j" 2>&1 >/dev/null); then got=allow; else got=block; fi
    case "$v" in
      allow|block) [[ "$got" == "$v" ]] || wrong+=$'\n'"      want $v, got $got: $c" ;;
      block~*) if [[ "$got" != block ]]; then wrong+=$'\n'"      want block, got allow: $c"
               elif ! grep -qE -- "${v#block~}" <<<"$err"; then wrong+=$'\n'"      blocked, but not with /${v#block~}/: $c — $err"; fi ;;
    esac
  done
  if [[ -z "$wrong" ]]; then ok "$desc"; else bad "$desc" "${wrong#$'\n'      }"; fi
}
doctor_json() { $ONETREE doctor --json 2>/dev/null || true; }   # doctor exits 1 when a check fails, which is the point of several tests
fake_agent() {  # name — $TMP/bin/<name> N sleeps N seconds as a process called <name>. A symlink to sleep does it, except where
  mkdir -p "$TMP/bin"; ln -sf "$(command -v sleep)" "$TMP/bin/$1"   # sleep is a multi-call binary that refuses another name (uutils,
  "$TMP/bin/$1" 0 2>/dev/null && return 0   # Ubuntu 26): there a perl script under that name, which Linux lists by the script's name
  rm -f "$TMP/bin/$1"; printf '%s\n' '#!/usr/bin/perl' 'sleep $ARGV[0];' > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"
}

# ---- fixture: a bare origin, a main checkout with one commit, origin/HEAD known
git init -q --bare -b main origin.git
git clone -q origin.git main 2>/dev/null
( cd main && echo hi > README.md && git add README.md && git commit -qm init && git push -q origin main && git remote set-head origin -a >/dev/null )
MAIN=$TMP/main
$ONETREE init --no-guard --root "$TMP/worktrees" "$MAIN" >/dev/null 2>&1
# an unregistered production checkout, marked only in its own .git/config
git clone -q origin.git production 2>/dev/null
PROD=$TMP/production; DEV=$TMP/development
git -C "$PROD" config --local onetree.production true
git -C "$PROD" config --local onetree.devClone "$DEV"

# ==== part 1
# ---- new + ls. In a single-remote clone the base and push remotes are both origin; the golden rows pin the exact output
p=$($ONETREE new feat-a "$MAIN")
eq "new prints the worktree path, and its branch has no upstream until the first push (golden)" "$p $(git -C "$MAIN" config --get-regexp '^branch\.feature/feat-a\.' || echo no-upstream)" "$TMP/worktrees/main/feat-a no-upstream"
bad_new=""
for a in --help -h -x .. .hidden; do
  r=0; out=$(cd "$MAIN" && $ONETREE new "$a" 2>&1) || r=$?
  [[ -e "$TMP/worktrees/main/$a/.git" ]] && bad_new+=" $a:made"
  case "$a" in
    --help|-h) [[ $r == 0 && "$out" == *"new <slug>"* ]] || bad_new+=" $a:rc$r" ;;   # usage, not a worktree named --help
    *) [[ $r != 0 ]] || bad_new+=" $a:rc0" ;;
  esac
done
eq "new: --help / -h print usage, and a slug starting with - or . is refused; neither makes a worktree" "$bad_new" ""
ls=$($ONETREE ls --json "$MAIN")
golden() { jq -c '.[] | del(.live)' | sed -e "s#$TMP#<TMP>#g" -e 's/[0-9a-f]\{40\}/<SHA>/g'; }
eq "golden: ls --json of a single-remote clone matches the recorded rows" "$(golden <<<"$ls")" '{"path":"<TMP>/main","repo":"main","main":"<TMP>/main","kind":"main","slug":null,"branch":"main","detached":false,"head":"<SHA>","dirty":0,"unpushed":null,"pr":null,"lock":null,"guard":false,"integration":"main","behind":0}
{"path":"<TMP>/worktrees/main/feat-a","repo":"main","main":"<TMP>/main","kind":"worktree","slug":"feat-a","branch":"feature/feat-a","detached":false,"head":"<SHA>","dirty":0,"unpushed":0,"pr":{"state":"NONE","head":null},"lock":null}'
json_is "ls --all --json covers the registry" "$($ONETREE ls --all --json)" 'map(select(.kind == "main")) | length == 1'
has "ls (text) prints the table" "$($ONETREE ls "$MAIN")" "^$TMP/worktrees/main/feat-a +feature/feat-a +0 +0 +NONE "
json_is "info --json: a single-remote clone uses origin for both roles, by default" "$($ONETREE info --json "$MAIN")" '.remotes.base == {name:"origin", source:"default", slug:"'"$TMP"'/origin"} and .remotes.push.name == "origin" and .remotes.push.source == "default" and .remotes.ghUser.login == null and .writable == {paths:[], source:"default"}'

# ---- an unregistered production checkout is marked only in its own .git/config
json_is "production: info --json reports the local marker and development clone without registering it" "$($ONETREE info --json "$PROD")" \
  '.registered == false and .production == true and .devClone == "'"$DEV"'"'
has_all "production: text info reports the marker and development clone" "$($ONETREE info "$PROD")" \
  '^registered +no$' '^production +yes$' "^devClone +$DEV$"
prod_session=$(cd "$PROD" && printf '{"session_id":"prod-i","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$PROD" | $ONETREE session)
has_all "production: an interactive session gets the read-only notice, development clone, and no onboarding offer" "$prod_session" \
  'is a production checkout' 'read-only inspection only' "$DEV" 'Never offer onetree onboarding'
eq "production: claude -p is silent" "$(cd "$PROD" && printf '{"session_id":"prod-p","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$PROD" | CLAUDE_CODE_SESSION_ATTENDED=0 $ONETREE session)" ""
mkdir -p "$TMP/fakeps"
printf '%s\n' '#!/bin/sh' 'echo "codex exec --skip-git-repo-check task"' > "$TMP/fakeps/ps"; chmod +x "$TMP/fakeps/ps"
eq "production: codex exec ancestry is silent" "$(cd "$PROD" && printf '{"session_id":"prod-x","transcript_path":null,"cwd":"%s"}' "$PROD" | PATH="$TMP/fakeps:$PATH" ONETREE_SESSION_PID=424242 $ONETREE session)" ""
st=0; prod_init=$($ONETREE init --no-guard "$PROD" 2>&1) || st=$?
eq "production: init refuses before registry mutation, so gc and park cannot see the checkout" "$st $(grep -cF 'marked as a production checkout' <<<"$prod_init") $(grep -cF "$PROD" <<<"$($ONETREE repos)")" "1 1 0"
has "production: the global rules explicitly forbid onboarding a production checkout" "$($ONETREE rules)" 'production yes.*never offer onboarding'

# Marking an already registered checkout is an invalid operator state. Production still wins over cleanup.
git -C "$MAIN" config --local onetree.production true
json_is "production: info --json flags a marker accidentally set on a registered checkout" "$($ONETREE info --json "$MAIN")" \
  '.registered == true and .production == true and .productionConflict == true'
has_all "production: text info warns that a registered production checkout must be unregistered" "$($ONETREE info "$MAIN" 2>&1)" \
  '^productionConflict +yes$' 'still registered.*onetree unregister'
json_is "production: doctor fails the registered-plus-production conflict explicitly" "$(doctor_json)" \
  '[.checks[] | select(.name | contains("registered repo '"$MAIN"' is not marked production"))] == [{"name":"registered repo '"$MAIN"' is not marked production (unregister it first)","ok":false}]'
eq "production: gc and park skip a marked checkout even if stale registration remains" \
  "$($ONETREE gc --dry-run "$MAIN" 2>/dev/null) | $($ONETREE park "$MAIN" 2>/dev/null)" " | "
git -C "$MAIN" config --local --unset onetree.production

# A committed or onetree-global copy is deliberately not a marker.
git clone -q origin.git false-production 2>/dev/null
FALSE_PROD=$TMP/false-production
printf '[onetree]\nproduction = true\ndevClone = /wrong/committed\n' > "$FALSE_PROD/.onetree"
git config -f "$ONETREE_CONFIG" onetree.production true
git config -f "$ONETREE_CONFIG" onetree.devClone /wrong/global
json_is "production: committed and global marker keys are ignored" "$($ONETREE info --json "$FALSE_PROD")" '.production == false and .devClone == null and .registered == false'
st=0; $ONETREE init --no-guard "$FALSE_PROD" >/dev/null 2>&1 || st=$?
eq "production: ignored marker layers do not make init refuse" "$st $($ONETREE info --json "$FALSE_PROD" | jq -r .registered)" "0 true"
$ONETREE unregister "$FALSE_PROD" >/dev/null
git config -f "$ONETREE_CONFIG" --unset onetree.production
git config -f "$ONETREE_CONFIG" --unset onetree.devClone

# ---- the PR cache: gh is asked once per branch, then not again until the TTL passes or --fresh
c1=$(gh_calls '--head feature/feat-a'); m1=$(gh_calls '--state merged')
$ONETREE ls --json "$MAIN" >/dev/null; c2=$(gh_calls '--head feature/feat-a')
$ONETREE ls --json --fresh "$MAIN" >/dev/null; c3=$(gh_calls '--head feature/feat-a')
ONETREE_PR_TTL=0 $ONETREE ls --json "$MAIN" >/dev/null; c4=$(gh_calls '--head feature/feat-a')
slug=$(git -C "$MAIN" remote get-url origin); slug=${slug%.git}
eq "cache: gh is asked once per branch and once for merged heads, again only with --fresh or ONETREE_PR_TTL=0; the state lives under ONETREE_CACHE" \
  "$c1 $m1 $c2 $c3 $c4 $([[ -f "$TMP/state/cache/pr/$(printf '%s' "$slug feature/feat-a" | cksum | cut -d' ' -f1)" ]] && echo cached)" "1 1 1 2 3 cached"
eq "golden: every PR lookup asks gh the same query" "$(grep -c -xF "pr list -R $TMP/origin --head feature/feat-a --state all --limit 1 --json state,headRefOid -q .[0] | \"\\(.state) \\(.headRefOid)\"" "$GH_LOG")" "$c4"
json_is "events: new is recorded" "$($ONETREE events --json --kind new)" '(length == 1) and (.[0] | .path == "'"$p"'" and .cmd == "new" and .repo == "main" and .branch == "feature/feat-a" and .resumed == false and (.t | type) == "number" and (.ts | test("Z$")))'

# ---- guard: a refusal is recorded, an allowed read is not
$ONETREE init --guard "$MAIN" >/dev/null 2>&1
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git stash"},"session_id":"s-1","transcript_path":"/x/.claude/projects/t.jsonl"}' "$MAIN" | $ONETREE guard 2>/dev/null || true
json_is "events: a block carries rule, tool, agent, session and command" "$($ONETREE events --json --kind guard)" '(length == 1) and (.[0] | .decision == "block" and .rule == "mutating git" and .tool == "Bash" and .agent == "claude" and .session == "s-1" and .command == "git stash" and .repo == "main" and .main == "'"$MAIN"'" and .cmd == "guard" and .pid == '"$$"')'
st=0; printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git status"}}' "$MAIN" | $ONETREE guard 2>/dev/null || st=$?
eq "guard lets a read pass, and does not record it" "$st $($ONETREE events --json --kind guard | jq length)" "0 1"
st=0; printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"npm test"},"agent":"pi"}' "$MAIN" | ONETREE_NO_EVENTS=1 $ONETREE guard 2>/dev/null || st=$?
eq "guard blocks npm test, and ONETREE_NO_EVENTS keeps the block out of the log (doctor probes use it)" "$st $($ONETREE events --json --kind guard | jq length)" "2 1"
printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"README.md"},"agent":"pi"}' "$MAIN" | $ONETREE guard 2>/dev/null || true
json_is "events: an Edit block names the file and the agent the payload declared" "$($ONETREE events --json --kind guard)" '(length == 2) and (.[1] | .tool == "Edit" and .agent == "pi" and .rule == "a write" and .file == "'"$MAIN"'/README.md" and .command == "")'
has "session mode: non-interactive sessions still receive a registered guarded checkout's safety notice" \
  "$(cd "$MAIN" && printf '{"session_id":"guarded-job","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$MAIN" | CLAUDE_CODE_SESSION_ATTENDED=0 ONETREE_SESSION_PID=424239 $ONETREE session)" \
  'is a guarded read-only mirror.*onetree new'
$ONETREE init --no-guard "$MAIN" >/dev/null 2>&1

# ---- agents: a process whose name says agent, a recorded session, and pruning
fake_agent claude
( cd "$p" && exec "$TMP/bin/claude" 60 ) & AG=$!
( cd "$p" && exec sleep 60 ) & SH=$!
sleep 0.5
json_is "agents: a process named claude in a worktree is listed and located; a plain sleep there is not a session" "$($ONETREE agents --json)" '(map(select(.pid == '"$AG"')) | length == 1) and (map(select(.pid == '"$AG"'))[0] | .agent == "claude" and .kind == "worktree" and .slug == "feat-a" and .repo == "main" and .path == "'"$p"'" and .session == null and (.started | type) == "number" and (.startedAt | test("Z$"))) and (map(select(.pid == '"$SH"')) | length == 0)'
has "agents (text) prints a table" "$($ONETREE agents)" "^$AG +claude +- +main +worktree +$p "
printf '{"session_id":"s-9","transcript_path":"/x/.codex/t.jsonl","cwd":"%s","hook_event_name":"SessionStart"}' "$MAIN" | ONETREE_SESSION_PID=$SH $ONETREE session >/dev/null
json_is "session hook records the agent process, and agents lists that session by its id though the process name says nothing" \
  "$(jq -n --argjson f "$(cat "$TMP/state/sessions/$SH.json")" --argjson a "$($ONETREE agents --json)" '{f:$f, a:$a}')" \
  '(.f | .pid == '"$SH"' and .session == "s-9" and .agent == "codex" and .cwd == "'"$MAIN"'" and (.recorded | type) == "number") and (.a | map(select(.pid == '"$SH"')) | length == 1 and .[0].agent == "codex" and .[0].session == "s-9" and .[0].kind == "worktree")'
kill $AG $SH 2>/dev/null; wait $AG $SH 2>/dev/null || true
eq "agents: dead processes disappear, and their session files are pruned" "$($ONETREE agents --json | jq 'map(select(.pid == '"$SH"' or .pid == '"$AG"')) | length') $([[ -f "$TMP/state/sessions/$SH.json" ]] && echo kept || echo pruned)" "0 pruned"
if $ONETREE session </dev/null >/dev/null 2>&1; then ok "session hook with no payload is silent and succeeds"; else bad "session hook with no payload is silent and succeeds"; fi

# ---- session mode: the installed clients do not put one common mode in the payload.
# Claude -p exports CLAUDE_CODE_SESSION_ATTENDED=0; Codex exec is identifiable only by the direct process command.
git clone -q origin.git session-unregistered 2>/dev/null
UNREG=$TMP/session-unregistered
interactive=$(cd "$UNREG" && printf '{"session_id":"interactive","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$UNREG" | CLAUDE_CODE_SESSION_ATTENDED=1 ONETREE_SESSION_PID=424240 $ONETREE session)
has "session mode: an interactive session in an unregistered repo is asked to onboard" "$interactive" 'is not set up for worktrees.*ask the user once whether to onboard it'
unreg_quiet=$(cd "$UNREG" && printf '{"session_id":"claude-print","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$UNREG" | CLAUDE_CODE_SESSION_ATTENDED=0 ONETREE_SESSION_PID=424241 $ONETREE session)
outside_quiet=$(cd "$TMP" && printf '{"session_id":"claude-outside","transcript_path":"/x/.claude/t.jsonl","cwd":"%s"}' "$TMP" | CLAUDE_CODE_SESSION_ATTENDED=0 ONETREE_SESSION_PID=424242 $ONETREE session)
eq "session mode: claude -p is silent in an unregistered repo and outside a repo" "$unreg_quiet|$outside_quiet" "|"
json_is "session mode: a silent non-interactive hook still records the session" "$(cat "$TMP/state/sessions/424241.json")" '.session == "claude-print" and .agent == "claude" and .cwd == "'"$UNREG"'"'
codex_unreg=$(cd "$UNREG" && printf '{"session_id":"codex-exec","transcript_path":null,"cwd":"%s"}' "$UNREG" | PATH="$TMP/fakeps:$PATH" ONETREE_SESSION_PID=424243 $ONETREE session)
codex_outside=$(cd "$TMP" && printf '{"session_id":"codex-outside","transcript_path":null,"cwd":"%s"}' "$TMP" | PATH="$TMP/fakeps:$PATH" ONETREE_SESSION_PID=424244 $ONETREE session)
eq "session mode: codex exec ancestry is silent in an unregistered repo and outside a repo" "$codex_unreg|$codex_outside" "|"
has_all "rules: scope is registered repos only, and scheduled or non-interactive jobs receive no workflow instruction" "$($ONETREE rules)" \
  'protocol below applies only inside a repo where `onetree info` says' \
  'Not onboarded yet \(interactive sessions only\)' \
  'if `onetree info` says' \
  'Never tell a scheduled or non-interactive job to' \
  'onboard, make a worktree, or stop because of onetree'

# a hook-recorded session whose cwd is outside every registered repo. empty kind/main/path must stay empty:
# bash read treats tab as whitespace and used to slide the elapsed time into kind.
fake_agent pi-out
( cd "$TMP" && exec "$TMP/bin/pi-out" 60 ) & OUT=$!
sleep 0.5
printf '{"session_id":"s-out","transcript_path":"/x/.pi/t.jsonl","cwd":"%s","hook_event_name":"SessionStart"}' "$TMP" | ONETREE_SESSION_PID=$OUT $ONETREE session >/dev/null
json_is "agents: a session outside every repo keeps empty location fields" "$($ONETREE agents --json)" '(map(select(.pid == '"$OUT"')) | length == 1) and (map(select(.pid == '"$OUT"'))[0] | .agent == "pi" and .kind == null and .repo == null and .main == null and .path == null and .slug == null and .cwd == "'"$TMP"'" and .exe != "" and (.command | length) > 0 and (.started | type) == "number" and (.startedAt | test("Z$")))'
kill $OUT 2>/dev/null || true; wait $OUT 2>/dev/null || true

# ---- Codex Desktop: the inferred session is the cua-repl.mjs controller, not every cua_node helper
mkdir -p "$TMP/cua_node/bin" "$TMP/bin"
printf '%s\n' '#!/usr/bin/perl' 'sleep 60;' > "$TMP/sleeper"
chmod +x "$TMP/sleeper"
cp "$TMP/sleeper" "$TMP/cua_node/bin/node_repl"
cp "$TMP/sleeper" "$TMP/cua_node/bin/node"
cp "$TMP/sleeper" "$TMP/bin/node"
cp "$TMP/sleeper" "$TMP/bin/node_repl"
fake_agent codex
fake_agent pi
fake_agent claude
ctrl=/x/@oai/cua-repl/bin/cua-repl.mjs
( cd "$p" && exec "$TMP/cua_node/bin/node" "$ctrl" ) & CA=$!
( cd "$p" && exec "$TMP/cua_node/bin/node" "$ctrl" ) & CB=$!
( cd "$p" && exec "$TMP/cua_node/bin/node_repl" ) & H1=$!
( cd "$p" && exec "$TMP/cua_node/bin/node" /x/artifact-template-picker/server.mjs ) & H2=$!
( cd "$p" && exec "$TMP/bin/node" "$p/app.js" ) & ND=$!
( cd "$p" && exec "$TMP/bin/node_repl" ) & NR=$!
( cd "$p" && exec "$TMP/bin/codex" 60 ) & CX=$!
( cd "$p" && exec "$TMP/bin/pi" 60 ) & PI=$!
( cd "$p" && exec "$TMP/bin/claude" 60 ) & CL=$!
( cd "$MAIN" && exec "$TMP/cua_node/bin/node" "$ctrl" ) & CC=$!
sleep 0.5
ag=$($ONETREE agents --json)
json_is "agents: two pre-hook Desktop controllers in one cwd are two sessions; one in another cwd is its own row" "$ag" '(map(select(.pid == '"$CA"' or .pid == '"$CB"')) | length == 2 and all(.agent == "codex" and .session == null and .kind == "worktree" and .path == "'"$p"'")) and (map(select(.pid == '"$CC"')) | length == 1 and .[0].agent == "codex" and .[0].kind == "main" and .[0].session == null and .[0].path == "'"$MAIN"'")'
json_is "agents: a Desktop thread's helpers and unrelated node in the repo are not sessions" "$ag" 'map(select(.pid == '"$H1"' or .pid == '"$H2"' or .pid == '"$ND"' or .pid == '"$NR"')) | length == 0'
json_is "agents: processes named codex, pi and claude are still listed next to Desktop controllers" "$ag" '(map(select(.pid == '"$CX"')) | length == 1 and .[0].agent == "codex" and .[0].session == null) and (map(select(.pid == '"$PI"')) | length == 1 and .[0].agent == "pi") and (map(select(.pid == '"$CL"')) | length == 1 and .[0].agent == "claude")'
printf '{"session_id":"s-desk-a","transcript_path":"/x/.codex/t.jsonl","cwd":"%s","hook_event_name":"SessionStart"}' "$p" | ONETREE_SESSION_PID=$CA $ONETREE session >/dev/null
printf '{"session_id":"s-desk-b","transcript_path":"/x/.codex/t.jsonl","cwd":"%s","hook_event_name":"SessionStart"}' "$p" | ONETREE_SESSION_PID=$CB $ONETREE session >/dev/null
json_is "agents: two hook-recorded Desktop sessions in one cwd remain two rows" "$($ONETREE agents --json)" '(map(select(.pid == '"$CA"' or .pid == '"$CB"')) | length == 2) and (map(select(.pid == '"$CA"'))[0].session == "s-desk-a") and (map(select(.pid == '"$CB"'))[0].session == "s-desk-b")'
kill $CA $CB $H1 $H2 $ND $NR $CX $PI $CL $CC 2>/dev/null; wait $CA $CB $H1 $H2 $ND $NR $CX $PI $CL $CC 2>/dev/null || true

# ---- gc verdicts
json_is "gc --dry-run --json: a fresh worktree is kept as young" "$($ONETREE gc --dry-run --json "$MAIN")" '.[0].slug == "feat-a" and .[0].gc == {action:"keep", code:"young", reason:"no merged PR and younger than 24h"}'
# a fresh worktree's head is a main commit, so any PR cut from main later contains it: that says nothing about the worktree
later=$(git -C "$p" commit-tree -p "$(git -C "$p" rev-parse HEAD)" -m later "$(git -C "$p" rev-parse 'HEAD^{tree}')")
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GH_LOG"' "case \"\$*\" in *'--state merged'*) echo $later ;; esac" > "$TMP/bin/gh"
json_is "gc: a fresh worktree stays young when a later merged PR contains its head" "$($ONETREE gc --dry-run --json --fresh "$MAIN")" '.[0].slug == "feat-a" and .[0].gc.code == "young"'
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GH_LOG"' 'exit 0' > "$TMP/bin/gh"
# dsh runs every session in one server process outside the worktree; a session it has loaded holds its session.lock open (issue #35)
git -C "$MAIN" config onetree.stale 0   # old enough to go, so only a working session keeps it
DS=$TMP/dsh-home/sessions; for s in held cold; do mkdir -p "$DS/--proj--/session-$s"; : > "$DS/--proj--/session-$s/session.lock"; done
( exec 8<"$DS/--proj--/session-held/session.lock"; sleep 60 ) & HOLD=$!; sleep 0.3
dsh_rec() { rm -rf "$ONETREE_SESSIONS/dsh"; [[ -z "$1" ]] || printf '{"session_id":"session-%s","agent":"dsh","cwd":"%s","dsh_sessions":"%s","archived":%s,"opened":%s}' "$1" "$2" "$DS" "$3" "${4:-[]}" | $ONETREE session >/dev/null 2>&1 || true
  $ONETREE gc --dry-run --json "$MAIN" | jq -r '.[] | select(.slug == "feat-a") | .gc.code'; }
eq "gc: a dsh session keeps its worktree, and every worktree it opened, while its lock is open and it is not archived; a record alone, or an archived session, keeps nothing" \
  "$(dsh_rec) $(dsh_rec held "$p" false) $(dsh_rec held "$p/src" false) $(dsh_rec held "$TMP" false "[\"$p\"]") $(dsh_rec held "$p" true) $(dsh_rec cold "$TMP" false "[\"$p\"]")" "in-integration live live live in-integration in-integration"
# the plugin starts several writes of one record at once; each merges into the last, under a lock; archived changes only when sent
rm -rf "$ONETREE_SESSIONS/dsh"; mkdir -p "$ONETREE_SESSIONS/dsh/session-lk.json.lock"
printf '{"session_id":"session-lk","agent":"dsh","cwd":"%s","dsh_sessions":"%s","archived":true}' "$p" "$DS" | $ONETREE session >/dev/null 2>&1 & LKW=$!
sleep 0.5; lk_held=$([[ -f "$ONETREE_SESSIONS/dsh/session-lk.json" ]] && echo written || echo waited)
rmdir "$ONETREE_SESSIONS/dsh/session-lk.json.lock" 2>/dev/null || true; wait $LKW || true
printf '{"session_id":"session-lk","agent":"dsh","opened":["%s"]}' "$p" | $ONETREE session >/dev/null 2>&1 || true
eq "dsh: a record write waits for the lock, merges into the last one, and leaves archived alone unless it sends it" \
  "$lk_held $(jq -c '[.cwd == "'"$p"'", .opened == ["'"$p"'"], .archived]' "$ONETREE_SESSIONS/dsh/session-lk.json")" "waited [true,true,true]"
dsh_rec cold "$TMP/gone" false >/dev/null
eq "gc: a dsh record whose lock is not open and whose folder is gone is dropped" "$(ls "$ONETREE_SESSIONS/dsh" | wc -l | tr -d ' ')" "0"
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null || true; rm -rf "$ONETREE_SESSIONS/dsh"; git -C "$MAIN" config --unset onetree.stale
has "gc --dry-run (text): the keep line gc has always logged" "$($ONETREE gc --dry-run "$MAIN")" "^keep $TMP/worktrees/main/feat-a: no merged PR and younger than 24h\$"
echo dirt > "$p/dirt"
json_is "gc: dirty worktree kept with code dirty" "$($ONETREE gc --dry-run --json "$MAIN")" '.[0].gc.code == "dirty" and .[0].dirty == 1'
rm "$p/dirt"
( cd "$p" && echo work > work.txt && git add work.txt && git commit -qm work && git push -q -u origin feature/feat-a 2>/dev/null )
$ONETREE init --stale 0 "$MAIN" >/dev/null 2>&1
json_is "gc: pushed, unmerged branch kept as not-merged" "$($ONETREE gc --dry-run --json "$MAIN")" '.[0].gc.code == "not-merged" and .[0].unpushed == 0'
( cd "$MAIN" && git merge -q --no-ff -m merge feature/feat-a && git push -q origin main )
eq "golden: gc --dry-run --json of a single-remote clone matches the recorded rows (merged into integration: would remove; unguarded main: never parked)" "$($ONETREE gc --dry-run --json "$MAIN" | golden)" '{"path":"<TMP>/worktrees/main/feat-a","repo":"main","main":"<TMP>/main","kind":"worktree","slug":"feat-a","branch":"feature/feat-a","detached":false,"head":"<SHA>","dirty":0,"unpushed":0,"pr":{"state":"NONE","head":null},"lock":null,"gc":{"action":"would-remove","code":"in-integration","reason":"feature/feat-a, pr=NONE"}}
{"path":"<TMP>/main","repo":"main","kind":"main","park":{"action":"none","code":"unguarded","reason":"not guarded, never parked"}}'
has "gc --dry-run (text) says would remove" "$($ONETREE gc --dry-run "$MAIN")" "^would remove $TMP/worktrees/main/feat-a \(feature/feat-a, pr=NONE\)\$"
if [[ -f "$MAIN/.git/onetree-fetched" ]]; then ok "cache: gc stamps the main after fetching"; else bad "cache: gc stamps the main after fetching"; fi

# ---- info, doctor, snapshot (worktree still present)
json_is "info --json: values, and the layer each came from" "$($ONETREE info --json "$MAIN")" '.repo == "main" and .registered == true and .guard == false and .integration == "main" and .root == "'"$TMP"'/worktrees" and .worktreeDir == "'"$TMP"'/worktrees/main" and .branchPrefix == "feature/" and .copy == [".env", ".env.local"] and .keep == [] and .keepSource == "'"$MAIN"'" and .bootstrap == null and .stale == 0 and .committedFile == false
  and .sources == {guard:"local", integration:"remote-head", root:"local", branchPrefix:"default", copy:"default", keep:"default", keepSource:"default", bootstrap:"default", stale:"local"}'
has "info (text) prints the effective values" "$($ONETREE info "$MAIN")" '^registered    yes$'
json_is "doctor --json: shape" "$(doctor_json)" '(.checks | length) > 0 and (.ok + .failed) == (.checks | length) and .repos == ["main"] and (.checks | all(has("name") and has("ok")))'
has "doctor (text) ends with its summary" "$($ONETREE doctor || true)" '^[0-9]+ ok, [0-9]+ failed\. registered repos: main $'
json_is "snapshot: envelope, the repo with info, park and gc verdicts, the doctor, agents, and the last 24h of events oldest first" "$($ONETREE snapshot --all)" \
  '.schema == 1 and (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.host | length) > 0 and (.onetree.bin | endswith("/bin/onetree")) and (.repos | length) == 1
   and (.repos[0] | .info.repo == "main" and .main.kind == "main" and .main.park.action == "none" and (.worktrees | length) == 1 and .worktrees[0].slug == "feat-a" and .worktrees[0].gc.action == "would-remove")
   and (.doctor.checks | length) > 0 and (.agents | type) == "array" and (.agents | map(select(.repo == "main")) | length == 0) and (.events | map(.kind)) == ["new", "guard", "guard"]'
eq "snapshot: keeps the doctor report in the cache; [repo] --fresh runs everything again and agrees" \
  "$([[ -f "$TMP/state/cache/doctor.json" ]] && echo cached) $($ONETREE snapshot --fresh "$MAIN" | jq -c '[.schema, (.repos | length), .repos[0].worktrees[0].gc.action, ((.doctor.checks | length) > 0)]')" 'cached [1,1,"would-remove",true]'
json_is "events: dry runs and snapshots record nothing" "$($ONETREE events --json)" 'length == 3'

# ---- the keep-file rule: a listed gitignored file that differs from keepSource's copy keeps a worktree gc would otherwise remove
git -C "$MAIN" config onetree.keep inventory.ini
printf 'inventory.ini\n' > "$MAIN/.git/info/exclude"; echo main > "$MAIN/inventory.ini"; echo mine > "$p/inventory.ini"
eq "gc: a keep file that differs from the keepSource copy keeps the worktree, with the code keep-file" "$($ONETREE gc --dry-run --json "$MAIN" | jq -c '.[0].gc | [.action, .code]')" '["keep","keep-file"]'
rm -f "$p/inventory.ini" "$MAIN/inventory.ini"; git -C "$MAIN" config --unset onetree.keep; : > "$MAIN/.git/info/exclude"

# ---- a branch reused by name keeps what was never pushed: a worktree removed by hand left feature/kept one commit ahead of origin
k=$(ONETREE_NO_EVENTS=1 $ONETREE new kept "$MAIN")
( cd "$k" && git commit -q --allow-empty -m pushed && git push -q origin feature/kept 2>/dev/null && git commit -q --allow-empty -m "local only" )
git -C "$MAIN" worktree remove "$k"
k=$(ONETREE_NO_EVENTS=1 $ONETREE new kept "$MAIN")
eq "new: a local branch ahead of its remote copy is checked out as it is, not reset to the remote" "$(git -C "$k" log -1 --format=%s)" "local only"
ONETREE_NO_EVENTS=1 $ONETREE rm kept "$MAIN" --force >/dev/null 2>&1; git -C "$TMP/origin.git" branch -q -D feature/kept

# ---- park says when a guarded main cannot fast-forward, instead of reporting it parked on main
git clone -q origin.git diverged 2>/dev/null; DV=$TMP/diverged
git -C "$DV" commit -q --allow-empty -m "committed in main, never pushed"
$ONETREE init --guard --root "$TMP/dv-worktrees" "$DV" >/dev/null 2>&1
( cd "$MAIN" && git commit -q --allow-empty -m upstream && git push -q origin main )
eq "park: a main with a commit the remote lacks is left with the code diverged, and the text names the count" \
  "$(ONETREE_NO_EVENTS=1 $ONETREE gc --json "$DV" | jq -c '.[] | select(.park) | .park | [.action, .code]') $(ONETREE_NO_EVENTS=1 $ONETREE park "$DV" 2>&1 | grep -cE '^park diverged: main has 1 commit\(s\) origin/main lacks, so it cannot fast-forward$')" '["leave","diverged"] 1'
$ONETREE unregister "$DV" >/dev/null; chmod -R u+w "$DV"

# ---- park never overwrites an ignored file that the integration branch now tracks: git would, by default
git init -q --bare -b main ig.git; git clone -q ig.git igmain 2>/dev/null; IG=$TMP/igmain
( cd igmain && echo gen.json > .gitignore && echo a > a && git add . && git commit -qm init && git push -q origin main \
  && git switch -q -c feature/f && echo b > b && git add b && git commit -qm f && git switch -q main && git merge -q feature/f \
  && echo tracked > gen.json && git add -f gen.json && git commit -qm track && git push -q origin main && git switch -q feature/f )
echo mine > "$IG/gen.json"
$ONETREE init --guard --root "$TMP/ig-worktrees" "$IG" >/dev/null 2>&1
sw=$(ONETREE_NO_EVENTS=1 $ONETREE park "$IG" 2>&1 || true); sw="$sw | $(git -C "$IG" branch --show-current) $(cat "$IG/gen.json")"
$ONETREE init --no-guard "$IG" >/dev/null 2>&1
( cd "$IG" && rm gen.json && git switch -q main && git reset -q --hard HEAD~1 && echo mine > gen.json )   # on main now, one commit behind origin
$ONETREE init --guard "$IG" >/dev/null 2>&1
ff=$(ONETREE_NO_EVENTS=1 $ONETREE park "$IG" 2>&1 || true); ff="$ff | $(git -C "$IG" rev-list --count HEAD..origin/main) $(cat "$IG/gen.json")"
eq "park: a switch or a fast-forward that would overwrite an ignored file is refused, naming it, and the file is kept" "$sw / $ff" \
  "park igmain: switching feature/f -> main would overwrite gen.json | feature/f mine / park igmain: fast-forwarding main would overwrite gen.json | 1 mine"
mkdir -p "$TMP/slowgit"; printf '#!/bin/sh\ncase " $* " in *" fetch "*) sleep 2 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$TMP/slowgit/git"; chmod +x "$TMP/slowgit/git"   # holds park's unlock window open
PATH=$TMP/slowgit:$PATH ONETREE_NO_EVENTS=1 $ONETREE park "$IG" >/dev/null 2>&1 & pk=$!
for _ in $(seq 50); do [[ -w "$IG" ]] && break; sleep 0.1; done; w=$([[ -w "$IG" ]] && echo unlocked)
kill -TERM "$pk"; wait "$pk" 2>/dev/null || true
eq "park: killed while main is unlocked, it locks main again and frees the park lock" "$w $([[ -w "$IG" ]] && echo w || echo ro) $(ONETREE_NO_EVENTS=1 $ONETREE park "$IG" 2>&1 | grep -c 'park lock held')" "unlocked ro 0"
if ! command -v flock >/dev/null; then   # the lock macOS gets: a symlink made with its holder in one step
  PL=$(git -C "$IG" rev-parse --path-format=absolute --git-dir)/onetree-park.lock
  rm -rf "$PL"; ln -s "$$ 1" "$PL" 2>/dev/null || true   # held by this live shell since 1970
  held=$(ONETREE_NO_EVENTS=1 $ONETREE park "$IG" 2>&1 | grep -c 'park lock held' || true)
  rm -rf "$PL"; /bin/sh -c : & dead=$!; wait "$dead" || true   # a pid that exited by itself: killing a fresh job can hit the shell's copy before exec, which runs this suite's EXIT trap
  mkdir -p "$PL" && printf '%s 1\n' "$dead" > "$PL/holder"   # a dead holder, in the directory form the lock also honours
  taken=$(ONETREE_NO_EVENTS=1 $ONETREE park "$IG" 2>&1 | grep -c 'park lock held' || true)
  eq "park lock: a live holder is never taken over, however old; a dead holder's lock is, and freed after" "$held $taken $([[ -L "$PL" || -e "$PL" ]] && echo left || echo freed)" "1 0 freed"
fi
$ONETREE unregister "$IG" >/dev/null; chmod -R u+w "$IG"

# ---- a real gc removes it: in the JSON, on disk, in the event log
gc=$($ONETREE gc --json "$MAIN")
eq "gc --json: removed, the directory and the merged local branch gone" "$(jq -c '[.[0].gc.action, .[0].gc.code, .[1].park.code]' <<<"$gc") $([[ -d "$p" ]] && echo dir || echo nodir) $(git -C "$MAIN" show-ref -q --verify refs/heads/feature/feat-a && echo branch || echo nobranch)" '["remove","in-integration","unguarded"] nodir nobranch'
json_is "events: the removal is recorded, and the gc run summarised" "$($ONETREE events --json)" '(map(select(.kind == "gc")) | length == 1 and (.[0] | .action == "remove" and .code == "in-integration" and .path == "'"$p"'" and .branch == "feature/feat-a" and .cmd == "gc"))
  and (map(select(.kind == "gc-run")) | length == 1 and (.[0] | .removed == 1 and .kept == 0 and .parked == 0 and .fastForwarded == 0 and (.seconds | type) == "number" and .target == "'"$MAIN"'"))'
eq "events: --since with -n, a future --since, and -n 0 for everything" "$($ONETREE events --json --since 1h -n 1 | jq -c 'map(.kind)') $($ONETREE events --json --since $(( $(date +%s) + 3600 )) | jq length) $($ONETREE events --json -n 0 | jq length)" '["gc-run"] 0 5'
has "events (text) shows the removal with its code and path" "$($ONETREE events --kind gc)" "^[0-9T:Z-]+ +gc +gc +remove +in-integration +$p "

# ---- review checkouts: detached at origin/<branch>, holding nothing of their own, so gc can let them go
$ONETREE init --stale 24 "$MAIN" >/dev/null 2>&1
q=$($ONETREE new feat-b "$MAIN")
( cd "$q" && echo b > b.txt && git add b.txt && git commit -qm "feat b" && git push -q -u origin feature/feat-b 2>/dev/null )
rp=$($ONETREE review feature/feat-b "$MAIN")
eq "review prints the checkout path and records the branch it was made from" "$rp $(head -1 "$MAIN/.git/worktrees/review-feature-feat-b/onetree-review" 2>/dev/null)" "$TMP/worktrees/main/review-feature-feat-b feature/feat-b"
rj() { $ONETREE gc --dry-run --json --fresh "$MAIN" | jq -c '.[] | select(.slug == "review-feature-feat-b")'; }
json_is "a review checkout is detached, holds nothing of its own, has the PR of the branch it reviews, and is kept while young" "$(rj)" '.detached == true and .branch == null and .unpushed == 0 and .pr.state == "NONE" and .gc.code == "young"'

# GitHub's squash merge, then the branch is deleted on origin: the review checkout's commit now lives on no remote ref
( cd "$MAIN" && git merge -q --squash feature/feat-b >/dev/null && git commit -qm "squash feat-b" && git push -q origin main )
git -C "$TMP/origin.git" branch -q -D feature/feat-b
$ONETREE rm feat-b "$MAIN" --force >/dev/null 2>&1
git -C "$MAIN" fetch -q -p origin
$ONETREE init --stale 0 "$MAIN" >/dev/null 2>&1
json_is "a squash-merged, deleted branch no longer strands its review checkout, and the row still reports its commit as on no remote" "$(rj)" '.gc.action == "would-remove" and .gc.code == "review" and .unpushed == 1'
eq "ls and gc agree on unpushed for the same worktree" "$($ONETREE ls --json "$MAIN" | jq -c 'map(select(.slug == "review-feature-feat-b"))[0].unpushed')" "1"
has "gc (text) names the branch a review checkout came from" "$($ONETREE gc --dry-run --fresh "$MAIN")" "^would remove $rp \(feature/feat-b \(review\), pr=NONE\)\$"
( cd "$rp" && echo r > review-note.txt && git add review-note.txt && git commit -qm "a reviewer's commit" )
json_is "a commit made in a review checkout keeps it, with the commit counted as unpushed" "$(rj)" '.gc.action == "keep" and .gc.code == "not-merged" and .unpushed == 2'
git -C "$rp" reset -q --hard HEAD~1

# a detached worktree onetree review did not make may hold real work: gc still keeps it
loose=$TMP/worktrees/main/loose
git -C "$MAIN" worktree add -q --detach "$loose" "$(git -C "$rp" rev-parse HEAD)"
json_is "a detached worktree that is not a review checkout is still kept" "$($ONETREE gc --dry-run --json --fresh "$MAIN" | jq -c '.[] | select(.slug == "loose")')" '.gc.action == "keep" and .gc.code == "not-merged" and .unpushed == 1'
git -C "$MAIN" worktree remove --force "$loose"
gc=$($ONETREE gc --json --fresh "$MAIN")
eq "gc removes the review checkout from disk, and records it with the code review" "$(jq -c 'map(select(.slug == "review-feature-feat-b")) | map([.gc.action, .gc.code])' <<<"$gc") $([[ -d "$rp" ]] && echo dir || echo nodir) $($ONETREE events --json --kind gc | jq '[.[] | select(.code == "review")] | length')" '[["remove","review"]] nodir 1'

# ---- CLOSED unmerged worktrees: gc may drop them once every commit is on origin and the stale window has passed
# gh answers CLOSED for those three branches (state is what gc keys on; the sha is unused for CLOSED).
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
echo "$*" >> "$GH_LOG"
branch=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--head" ]; then branch=$a; fi
  prev=$a
done
case "$branch" in
  feature/closed-a|feature/closed-b|feature/closed-c) echo "CLOSED deadbeef" ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"

$ONETREE init --stale 24 "$MAIN" >/dev/null 2>&1
ca=$($ONETREE new closed-a "$MAIN")
( cd "$ca" && echo closed > c.txt && git add c.txt && git commit -qm closed && git push -q -u origin feature/closed-a )
json_is "gc: a young CLOSED worktree is kept as young" "$($ONETREE gc --dry-run --json --fresh "$MAIN" | jq -c '.[] | select(.slug == "closed-a")')" '.gc.action == "keep" and .gc.code == "young" and .pr.state == "CLOSED" and .unpushed == 0'
$ONETREE init --stale 0 "$MAIN" >/dev/null 2>&1
cb=$($ONETREE new closed-b "$MAIN")   # pushed, then one more commit that lives only here
( cd "$cb" && printf 'b\n' > closed-b-work.txt && git add closed-b-work.txt && git commit -qm 'closed-b work' && git push -q -u origin feature/closed-b )
git -C "$cb" commit --allow-empty -qm extra
cc=$($ONETREE new closed-c "$MAIN")   # pushed, then its origin branch deleted
( cd "$cc" && echo c > c2.txt && git add c2.txt && git commit -qm c && git push -q -u origin feature/closed-c )
git -C "$TMP/origin.git" branch -q -D feature/closed-c
git -C "$MAIN" fetch -q -p origin
json_is "gc: past the stale window a fully pushed CLOSED worktree would go; one with unpushed commits, or whose origin branch was deleted, is kept" "$($ONETREE gc --dry-run --json --fresh "$MAIN")" \
  '(map(select(.slug == "closed-a"))[0] | .gc.action == "would-remove" and .gc.code == "pr-closed" and .unpushed == 0)
   and (map(select(.slug == "closed-b"))[0] | .gc.action == "keep" and .gc.code == "not-merged" and .unpushed == 1 and .pr.state == "CLOSED")
   and (map(select(.slug == "closed-c"))[0] | .gc.action == "keep" and .gc.code == "not-merged" and (.unpushed | tonumber) > 0)'
has "gc (text) names pr-closed" "$($ONETREE gc --dry-run --fresh "$MAIN")" "^would remove $ca \\(feature/closed-a, pr=CLOSED\\)$"
gc=$($ONETREE gc --json --fresh "$MAIN")
eq "gc: removes the pushed CLOSED worktree and its local branch, keeps the origin branch and the worktrees holding unique commits, records pr-closed" \
  "$(jq -c 'map(select(.slug == "closed-a"))[0].gc | [.action, .code]' <<<"$gc") $([[ -d "$ca" ]] && echo dir || echo nodir) $(git -C "$MAIN" show-ref -q --verify refs/heads/feature/closed-a && echo branch || echo nobranch) $(git -C "$TMP/origin.git" show-ref -q --verify refs/heads/feature/closed-a && echo origin-kept) $([[ -d "$cb" && -d "$cc" ]] && echo others-kept) $($ONETREE events --json --kind gc | jq '[.[] | select(.code == "pr-closed")] | length')" \
  '["remove","pr-closed"] nodir nobranch origin-kept others-kept 1'

# ==== part 2
# ---- command-position parser: classify the command word, not a regex over the line
$ONETREE init --guard "$MAIN" >/dev/null 2>&1
ptree=$($ONETREE new parser-onetree "$MAIN")
mkdir -p "$TMP/gitlog"; printf '#!/bin/sh\ncase "$*" in *onetree.guarded*) echo x >> "%s" ;; esac\nexec %s "$@"\n' "$TMP/guarded.log" "$(command -v git)" > "$TMP/gitlog/git"; chmod +x "$TMP/gitlog/git"
jq -nc --arg cwd "$MAIN" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"git stash"}}' | PATH=$TMP/gitlog:$PATH ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null 2>&1 || true
eq "guard: one read of the guarded list per call, the cost every agent tool call pays" "$(wc -l < "$TMP/guarded.log" | tr -d ' ')" 1
guard_table "parser: in a mirror each simple command is judged by its command word (quotes and echo are data; newlines, subshells and onetree chains do not hide a mutation)" "$MAIN" \
  block 'git stash'                       allow 'echo git stash' \
  allow "git -C $ptree status"             block 'bash -c "git stash"' \
  block '/bin/chmod u+w README.md'        allow "grep 'a|b'" \
  allow 'cd /tmp && git stash'            block '(cd /tmp && echo ok); git stash' \
  block "$(printf 'echo hi\ngit stash')"  allow "$(printf 'git log --oneline\ngit status')" \
  block "$(printf "echo it's fine\ngit stash")" \
  block 'bash tests/run.sh'               block 'sh ./deploy.sh' \
  allow 'onetree ls'                           block 'onetree ls && git stash'
guard_table "parser: from a worktree, a mirror path is judged as the mirror (git -C, scripts, npm --prefix, sed -i, find -exec chmod); a heredoc body is data" "$ptree" \
  block "git -C $MAIN stash"              allow 'bash tests/run.sh' \
  allow "$(printf "cat > notes.md <<'EOF'\nrm -rf %s/src\nEOF" "$MAIN")" \
  block "node $MAIN/script.js"            block "$MAIN/scripts/deploy.sh" \
  block "npm --prefix $MAIN run build"    block "sed -i '' s/a/b/ $MAIN/README.md" \
  block "find $MAIN -exec chmod u+w {} +" allow 'find . -exec chmod u+w {} +' \
  block "echo x | tee $MAIN/README.md"
guard_table "parser: an interpreter is judged by the script it runs (the first word that is no option or option's value), npm by its subcommand and --prefix; the script's own arguments are data" "$ptree" \
  allow "python3 tools/x.py --repo $MAIN" block "python3 -u $MAIN/x.py" \
  block "node -r ./a.js $MAIN/script.js"  block "python3.12 $MAIN/x.py" \
  block "npm --prefix=$MAIN run build"    allow "npm run build -- --out $MAIN/dist"
guard_table "parser: in a mirror an option before the script or the npm subcommand hides neither; code on the command line and a version probe are judged as before" "$MAIN" \
  block 'python3 -u manage.py runserver'  block 'node --inspect server.js' \
  block 'npm --silent run build'          allow 'npm view react version' \
  block "python3 -c 'print(1)'"           allow 'python3 --version'
guard_table "parser: a build tool asked only for its version or help runs nothing; a target, ci, run, a second argument or a redirect is still judged" "$MAIN" \
  allow 'make --version'                  allow 'npm --version && node -v && pnpm --version && yarn -v && bun --version && uv --version && python3 --version && make -h' \
  block 'make build'                      block 'make' \
  block 'npm ci'                          block 'npm run build' \
  block 'make --version build'            block 'make --version > README.md'
guard_table "parser: git and onetree commands have their redirects judged too; GIT_DIR and --git-dir name the repo git acts on" "$MAIN" \
  block 'git log > notes.txt'             block 'onetree ls > README.md' \
  allow 'git log > /dev/null'             allow "git log > $TMP/log.txt" \
  block "cd /tmp && GIT_DIR=$MAIN/.git git stash"  block "git --git-dir=$MAIN/.git -C /tmp stash" \
  allow "GIT_DIR=$MAIN/.git git log -1"
guard_table "parser: a wrapper and its options are skipped (timeout, nice -n, env -u, sudo -u, exec, xargs); backticks and \"\$(…)\" run commands; update-ref and branch -f move refs" "$MAIN" \
  block 'timeout 5 git stash'              block 'nice -n 5 git stash' \
  block 'env -u FOO git stash'            block 'sudo -u root git stash' \
  block 'exec git stash'                  block 'echo x | xargs git stash' \
  block 'echo `git stash`'                block 'echo "$(git stash)"' \
  block 'git update-ref refs/heads/main HEAD~1'  block 'git branch -f main HEAD~1' \
  block 'exec -a x git stash'              block "xargs -d '\\n' git stash" \
  block 'stdbuf -o L git stash'            block '/usr/bin/time -f label git stash' \
  block "env -S 'git stash'"               block 'git branch --color=never -f victim HEAD~1' \
  block 'git worktree --force remove x'    allow 'git worktree list && git branch --list && timeout -s KILL 5s git log' \
  block 'git branch escaped HEAD'          block 'git branch -c main copied' \
  block 'git tag escaped'                  block 'git tag -a v9 -m x' \
  block 'git symbolic-ref HEAD refs/heads/x'  block 'git add .' \
  allow 'git tag -l && git tag --contains HEAD && git tag -n3 && git branch -avv && git branch --sort=-committerdate && git symbolic-ref HEAD' \
  allow 'timeout 5 git log'               allow 'echo "$(git log -1) done" && git status' \
  allow 'echo `date`'                     allow 'echo "a`date`b" && git log'
guard_table "parser: a git verb writes unless it is known to read (remote, config, notes, an alias); reads still pass" "$MAIN" \
  block 'git remote set-url origin https://example.invalid/r.git'  block 'git config core.hooksPath /tmp/h' \
  block 'git notes add -m x'              block 'git co main' \
  block 'git update-index --assume-unchanged README.md'  block 'git sparse-checkout set src' \
  block 'git reflog expire --all'         block 'git stash pop' \
  allow 'git remote -v && git remote get-url origin && git config --get user.name && git config core.bare && git config --global x.y z' \
  allow 'git stash list && git reflog && git notes list && git worktree list && git fetch -q origin && git --version'
guard_table "parser: an unquoted heredoc's \$(…) and backticks run, so they are judged where they run; a quoted heredoc stays data" "$MAIN" \
  block "$(printf 'cat <<EOF\n$(git branch -D x)\nEOF')"     block "$(printf 'cat <<EOF\nnote `git stash`\nEOF')" \
  block "$(printf 'cat <<EOF\n$(git stash)\nEOF\ncd /tmp')" \
  allow "$(printf "cat <<'EOF'\n\$(git branch -D x)\nEOF")"  allow "$(printf 'cat <<EOF\nplain $HOME text\nEOF\ngit log -1')"
guard_table "parser: shell keywords and braces open a block, the command is inside it; a for or case header is words" "$MAIN" \
  block 'if true; then git branch -D topic; fi'  block '{ git branch -D topic; }' \
  block 'while true; do git stash; done'  block 'f() { git stash; }; f' \
  block 'case x in x) git stash;; esac'   block '! git stash' \
  allow 'for f in a b; do echo $f; done'  allow 'if [ -f README.md ]; then cat README.md; fi'
guard_table "parser: fail closed in a mirror: a program given a writing git command may run it; text tools and reads pass" "$MAIN" \
  block 'watch -n 5 git stash'            block 'flock /tmp/l git reset --hard' \
  block 'find . -name x -exec git checkout -- {} \;'  block 'parallel git stash ::: a' \
  allow 'echo git stash'                  allow 'man git stash' \
  allow 'watch -n 5 git status'           allow 'brew install git curl'
guard_table "parser: fetch into a local branch and git's own --output are writes; a quoted operator is a word" "$MAIN" \
  block 'git fetch origin +main:refs/heads/topic'  block 'git fetch . HEAD:topic' \
  block 'git diff --output=.git/config'   block 'git diff --output README.md' \
  allow 'git fetch -p origin && git fetch origin main:refs/remotes/origin/main'  allow "git diff --output=$TMP/x.patch" \
  allow "rg '>' README.md"                allow "grep -n ';' README.md && grep '|' README.md"
guard_table "parser: env -C and each git -C name the folder the command runs in" "$TMP" \
  block "env -C $MAIN git branch -D topic"  block "env --chdir=$MAIN git stash" \
  block "git -C $MAIN -C . branch -D topic" \
  allow "git -C $MAIN -C $TMP branch -D topic"  allow "env -C $TMP git stash"
guard_table "parser: cd's options and a cd inside if are followed, so what comes after is judged where it runs" "$TMP" \
  block "cd -- $MAIN && git branch -D topic"  block "if cd $MAIN; then git branch -D topic; fi" \
  block "cd -P $MAIN && git stash" \
  allow "cd $MAIN && git status && cd $TMP && git stash"  allow 'cd && ls'
guard_table "parser: in a mirror a quoted command line handed to a program is judged, and so is any real git command among its words" "$MAIN" \
  block "flock $TMP/repo.lock -c 'git branch -D topic'"  block "watch 'git branch -D topic'" \
  block 'find . -maxdepth 0 -exec git read-tree --empty \;' \
  allow 'find . -maxdepth 0 -exec git -C . status \;'  allow "gh issue create --title x --body 'run git stash pop first'" \
  allow "jq '.a | .b' package.json"       allow "awk '{ print \$1 }' README.md"
guard_table "parser: in a mirror a shell reading its commands from stdin is refused (the guard can't see them); cd - goes back; find -exec grep's words are data" "$MAIN" \
  block "$(printf "bash <<'EOF'\ngit branch -D topic\nEOF")"  block "echo 'git stash' | bash" \
  block 'bash -s'                         allow 'bash --version' \
  block 'cd /tmp && cd - && git branch -D topic'  allow 'cd /tmp && cd - && git status' \
  allow "find . -type f -exec grep -n 'git reset' {} +"  block 'find . -exec git stash \;'
guard_table "parser: a cd that may not run leaves both folders possible; a subshell's cd stays in it; gh checkout and outer redirects of bash -c are writes" "$MAIN" \
  block "$(printf 'if test -d %s/no-such; then cd %s/no-such; fi\ngit branch -D topic' "$TMP" "$TMP")" \
  block "$(printf 'if test -d %s; then cd %s; fi\ngit branch -D topic' "$TMP" "$TMP")" \
  block "cd $TMP/no-such; git branch -D topic"  block "cd $TMP && (cd /) && cd - && git branch -D topic" \
  block 'gh pr checkout 123'              block 'gh pr co 123' \
  block "bash -c 'git status' > .git/HEAD"  block "eval 'git status' > .git/HEAD" \
  allow "cd $TMP && git stash"            allow 'gh pr view 123 && gh pr list'
guard_table "parser: git config --file is judged by the file it writes" "$TMP" \
  block "git config --file $MAIN/.git/config user.email bot@example.com"  block "git config -f $MAIN/.git/config core.hooksPath /tmp/h" \
  allow "git config --file $TMP/other.cfg user.email bot@example.com"
guard_table "parser: a quote spans lines, as in the shell, so a multi-line body is one word; a quote left open is read line by line" "$MAIN" \
  allow "$(printf "printf '%%s\\\\n' 'first line\ngit reset\nlast line'")" \
  allow "$(printf "gh issue create --title x --body 'Steps:\ngit stash\ngit reset --hard'")" \
  block "$(printf "echo it's fine\ngit stash")"
guard_table "parser: cd - from outside comes back outside" "$TMP" \
  allow "cd $MAIN && cd - && git stash"
guard_table "parser: a listing option's separate value is not a branch or tag to create" "$MAIN" \
  allow "git branch --format '%(refname:short)'"  allow 'git tag --sort -creatordate' \
  block 'git branch --sort=-committerdate escaped'

# ---- self-protection: an agent cannot switch the guard off or rewrite onetree's settings, wherever it runs the command
git init -q "$TMP/unknown-repo"
guard_table "self-protection: uninstall, and unregister or init --no-guard of a guarded repo, are refused from anywhere; onboarding another repo and the rest of onetree pass" "$TMP" \
  block~"^onetree guard \(turning the guard off: onetree uninstall\): an agent may not turn the guard off or change onetree's settings; this would change onetree for every repo on this machine\. If the user wants it, they run the command themselves in a terminal\." 'onetree uninstall' \
  block 'bash -c "onetree uninstall"'          block '/usr/local/bin/onetree uninstall' \
  block~"\(turning the guard off: onetree unregister\): .*this would change the guarded repo main \($MAIN\)" "onetree unregister $MAIN" \
  block 'onetree unregister main'              block~'\(turning the guard off: onetree init --no-guard\)' "onetree init --no-guard $MAIN" \
  allow "onetree init --no-guard $TMP/unknown-repo"  allow "onetree init --guard $TMP/unknown-repo" \
  allow 'onetree ls'                           allow "onetree info $MAIN"
guard_table "production self-protection: an agent cannot erase or rewrite the local marker, but unrelated settings in the unregistered checkout still pass" "$PROD" \
  block~'changing onetree settings: git config onetree\.\*' 'git config --unset onetree.production' \
  block 'git config onetree.production false'  block 'git config onetree.devClone /tmp/elsewhere' \
  block 'git config --remove-section onetree'  block "git -C $PROD config --unset onetree.production" \
  block "GIT_DIR=$PROD/.git git config --unset onetree.production" \
  block "git config -f $PROD/.git/config --unset onetree.production" \
  block~'production checkout production' "echo x >> $PROD/.git/config" \
  block "sed -i.bak 's/production = true/production = false/' $PROD/.git/config" \
  block "rm -rf $PROD/.git"                 block "mv $PROD/.git $PROD/git-metadata" \
  block "Write:$PROD/.git/config" \
  block "Patch:*** Begin Patch\n*** Update File: $PROD/.git/config\n@@\n-a\n+b\n*** End Patch\n" \
  allow 'git config --get onetree.production'  allow 'git config onetree.guard false' \
  allow 'git config user.name operator'
guard_table "self-protection in the mirror: init ending on --no-guard is refused, init ending on --guard or adding writable state passes; git config may read onetree.* but not write it" "$MAIN" \
  block 'onetree unregister'                   block 'onetree init --guard --no-guard' \
  allow 'onetree init --no-guard --guard'      allow 'onetree init --writable-add .env' \
  block~'\(changing onetree settings: git config onetree\.\*\): .*this would change the guarded repo main' 'git config onetree.guard false' \
  block 'git config --remove-section onetree'  block 'git config --edit' \
  block 'git -c core.pager=cat config onetree.guard false' \
  allow 'git config onetree.guard'             allow 'git config --get onetree.guard' \
  allow 'git config --list'                    allow 'git config get onetree.guard' \
  allow 'git config --get-regexp onetree'
guard_table "self-protection from a worktree: it shares the mirror's .git/config, so onetree.* writes there are refused; other keys and new worktrees pass" "$ptree" \
  block 'onetree unregister'                   block 'git config --unset onetree.guard' \
  block 'git config set onetree.guard false'   allow 'git config user.name me' \
  allow 'onetree new other-task'
guard_table "self-protection outside every repo: git config into a guarded repo or onetree's config file is refused, ~/.gitconfig and an unknown repo pass; onetree's config file can be read, not written, moved or removed" "$TMP" \
  block "git -C $MAIN config --local onetree.writable src/"  block "git --git-dir=$MAIN/.git config onetree.guard false" \
  block "GIT_DIR=$MAIN/.git git config onetree.guard false"  block "git config -f $TMP/config --unset-all onetree.guarded" \
  block "git config --file=$TMP/config onetree.guard false"  allow 'git config --global onetree.guard false' \
  allow "git -C $TMP/unknown-repo config onetree.guard false" \
  block~"\(changing onetree settings: onetree's config file\): .*this would change onetree for every repo" "Edit:$TMP/config" \
  block "Write:$TMP/config"                    block "echo > $TMP/config" \
  block "echo x >> $TMP/config"                block "rm $TMP/config" \
  block "rm -rf $TMP"                          block "mv $TMP/config $TMP/config.bak" \
  block "sed -i.bak 's/a/b/' $TMP/config"      block "perl -pi -e 's/a/b/' $TMP/config" \
  block "cp /dev/null $TMP/config"             block "tee $TMP/config" \
  block "truncate -s0 $TMP/config"             block "onetree info > $TMP/config" \
  block "git status > $TMP/config"             block "bash -c 'rm $TMP/config'" \
  block "cd $TMP && rm config" \
  allow "cat $TMP/config"                      allow "cp $TMP/config $TMP/config-copy" \
  allow "sed 's/a/b/' $TMP/config"             allow "Write:$TMP/notes.md"
guard_table "self-protection: every file selector git config honours is judged: -f<path> attached, GIT_CONFIG, and GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM with --global / --system; reading through them passes" "$TMP" \
  block "git config -f$TMP/config --remove-section onetree"              block "GIT_CONFIG=$TMP/config git config --remove-section onetree" \
  block "env GIT_CONFIG=$TMP/config git config onetree.guard false"      block "GIT_CONFIG_GLOBAL=$TMP/config git config --global --remove-section onetree" \
  block "GIT_CONFIG_SYSTEM=$TMP/config git config --system onetree.guard false" \
  allow "GIT_CONFIG=$TMP/config git config --get onetree.repo"           allow 'git config --global user.name me'
guard_table "self-protection: a section rename is judged at both ends, so another section cannot be renamed into onetree (a key set elsewhere, renamed, then init would turn the guard off)" "$ptree" \
  allow 'git config other.guard false'         block 'git config --rename-section other onetree' \
  block 'git config rename-section other onetree'  block 'git config --rename-section other onetree.sub' \
  block 'git config --rename-section onetree other'  allow 'git config --rename-section other renamed' \
  allow 'onetree init'
ln -s "$TMP/config" "$TMP/config-alias"; ln "$TMP/config" "$TMP/config-hard"
guard_table "self-protection: writing through a symlink or hard link to onetree's config file is writing it; removing or replacing the other link is not" "$TMP" \
  block "echo > $TMP/config-alias"             block "Write:$TMP/config-alias" \
  block "git config -f $TMP/config-alias onetree.guard false"  block "echo x >> $TMP/config-hard" \
  block "cp /dev/null $TMP/config-hard"        allow "rm $TMP/config-alias" \
  allow "rm $TMP/config-hard"                  allow "ln -sf $TMP/notes.md $TMP/config-alias" \
  allow "cat $TMP/config-alias"
mkdir -p "$TMP/dots"; cp "$TMP/config" "$TMP/dots/onetree-config"; ln -s "$TMP/dots/onetree-config" "$TMP/config-link"
ocfg=$ONETREE_CONFIG; export ONETREE_CONFIG=$TMP/config-link
guard_table "self-protection: when the configured config file is itself a symlink, both its name and the file it points at are protected" "$TMP" \
  block "echo > $TMP/config-link"              block "echo > $TMP/dots/onetree-config" \
  block "rm $TMP/config-link"                  block "rm $TMP/dots/onetree-config" \
  block "rm -rf $TMP/dots"                     allow "cat $TMP/config-link"
export ONETREE_CONFIG=$ocfg
guard_table "self-protection: apply_patch is judged by the files it names, from a worktree or anywhere else: onetree's config file (deleted, updated, moved onto, or written through a link) and mirror files are refused" "$ptree" \
  block~"\(changing onetree settings: onetree's config file\)" "Patch:*** Begin Patch\n*** Delete File: $TMP/config\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** Update File: $TMP/config\n@@\n-a\n+b\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** Update File: $TMP/config-alias\n@@\n-a\n+b\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** Update File: notes.txt\n*** Move to: $TMP/config\n*** End Patch\n" \
  block~'onetree guard \(a write\)' "Patch:*** Begin Patch\n*** Update File: $MAIN/README.md\n@@\n-hi\n+ho\n*** End Patch\n" \
  block "$(printf 'apply_patch "*** Begin Patch\n*** Delete File: %s/config\n*** End Patch"' "$TMP")" \
  allow "Patch:*** Begin Patch\n*** Add File: notes.md\n+hi\n*** End Patch\n" \
  allow "Patch:*** Begin Patch\n*** Delete File: $TMP/config-alias\n*** End Patch\n"
guard_table "self-protection: a move destination is written, so moving onto a link to onetree's config file is refused; a shell apply_patch is judged where it runs: after cd, inside bash -c, from a heredoc" "$ptree" \
  block "Patch:*** Begin Patch\n*** Update File: notes.txt\n*** Move to: $TMP/config-alias\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** Update File: notes.txt\n*** Move to: $TMP/config-hard\n*** End Patch\n" \
  block "$(printf 'cd %s && apply_patch "*** Begin Patch\n*** Delete File: config\n*** End Patch"' "$TMP")" \
  block "$(printf 'bash -c "cd %s && apply_patch '"'"'*** Begin Patch\n*** Delete File: config\n*** End Patch'"'"'"' "$TMP")" \
  block "$(printf "cd %s && apply_patch <<'EOF'\n*** Begin Patch\n*** Delete File: config\n*** End Patch\nEOF" "$TMP")" \
  allow "$(printf 'cd %s && apply_patch "*** Begin Patch\n*** Add File: config\n+x\n*** End Patch"' "$ptree")"
p_add='*** Begin Patch\n*** Add File: notes-two.txt\n+x\n*** End Patch'; p_cfg='*** Begin Patch\n*** Add File: config\n+y\n*** End Patch'; p_del='*** Begin Patch\n*** Delete File: config\n*** End Patch'
guard_table "self-protection: each shell apply_patch is judged with its own patch where it runs, so two harmless patches in two directories pass, and a protected target in either one is refused" "$ptree" \
  allow "$(printf "cd %s && apply_patch \"$p_add\"; cd %s && apply_patch \"$p_cfg\"" "$TMP" "$ptree")" \
  block "$(printf "cd %s && apply_patch \"$p_add\"; cd %s && apply_patch \"$p_del\"" "$ptree" "$TMP")" \
  block "$(printf "cd %s && apply_patch \"$p_del\"; cd %s && apply_patch \"$p_add\"" "$TMP" "$ptree")" \
  allow "$(printf "cd %s && apply_patch <<'A'\n$p_add\nA\ncd %s && apply_patch <<'B'\n$p_cfg\nB" "$TMP" "$ptree")" \
  block "$(printf "cd %s && apply_patch <<'A'\n$p_add\nA\ncd %s && apply_patch <<'B'\n$p_del\nB" "$ptree" "$TMP")"
guard_table "apply_patch through the shell from the mirror: cd into a worktree first and its relative paths are the worktree's; without the cd they are the mirror's" "$MAIN" \
  allow "$(printf 'cd %s && apply_patch "*** Begin Patch\n*** Update File: README.md\n@@\n-hi\n+ho\n*** End Patch"' "$ptree")" \
  block "$(printf 'apply_patch "*** Begin Patch\n*** Update File: README.md\n@@\n-hi\n+ho\n*** End Patch"')"
guard_table "apply_patch through the shell behind env -S is still judged where its cd left it" "$TMP" \
  block "$(printf 'cd %s && env -S apply_patch "*** Begin Patch\n*** Update File: README.md\n@@\n-hi\n+ho\n*** End Patch"' "$MAIN")"
guard_table "self-protection: apply_patch outside every repo is judged the same way" "$TMP" \
  block "Patch:*** Begin Patch\n*** Delete File: config\n*** End Patch\n"   allow "Patch:*** Begin Patch\n*** Add File: scratch.md\n+hi\n*** End Patch\n"
n0=$($ONETREE events --json -n 0 --kind guard | jq length)
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"onetree init --no-guard"},"session_id":"s-2"}' "$ptree" | $ONETREE guard 2>/dev/null || true
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"onetree uninstall"}}' "$TMP" | $ONETREE guard 2>/dev/null || true
json_is "events: a self-protection block names the guarded repo it would change; one that changes every repo leaves main and repo empty" "$($ONETREE events --json -n 0 --kind guard | jq --argjson n "$n0" '.[$n:]')" '(length == 2) and (.[0] | .rule == "turning the guard off: onetree init --no-guard" and .main == "'"$MAIN"'" and .repo == "main" and .session == "s-2" and .cwd == "'"$ptree"'") and (.[1] | .rule == "turning the guard off: onetree uninstall" and .main == "" and .repo == "" and .path == "'"$TMP"'/config")'
$ONETREE rm --force parser-onetree "$MAIN" >/dev/null 2>&1 || true
$ONETREE init --no-guard "$MAIN" >/dev/null 2>&1

# ==== part 5
# ---- paths with spaces: repos_all / ls / new / gc must not word-split
SP="$TMP/my repo"
git clone -q origin.git "$SP" 2>/dev/null
( cd "$SP" && git checkout -q main )
$ONETREE init --no-guard --root "$TMP/worktrees" "$SP" >/dev/null 2>&1
spw=$($ONETREE new space-feat "$SP")
eq "a repo path with a space: ls has one main row, new prints the path, gc judges the worktree" \
  "$($ONETREE ls --json "$SP" | jq -c '[map(select(.kind == "main")) | length, .[0].path]') | $spw | $($ONETREE gc --dry-run --json --fresh "$SP" | jq 'map(select(.slug == "space-feat")) | length')" \
  "[1,\"$SP\"] | $TMP/worktrees/my repo/space-feat | 1"
cdcmd=$(ONETREE_HOST=codex-cli $ONETREE new space-feat "$SP" 2>&1 >/dev/null | grep -o '`cd [^`]*&&`' | tr -d '`' || true)
eq "a path with a space: the next step's cd command is quoted, so it lands in the worktree as printed" "$(eval "$cdcmd pwd -P" 2>/dev/null)" "$(cd "$spw" && pwd -P)"
$ONETREE rm --force space-feat "$SP" >/dev/null 2>&1 || true

# ==== part 2
# ---- dsh: process name, session payload, install surface
fake_agent dsh
( cd "$MAIN" && exec "$TMP/bin/dsh" 60 ) & DSHP=$!
sleep 0.3
a=$($ONETREE agents --json | jq -r 'map(select(.pid == '"$DSHP"'))[0].agent')
kill $DSHP 2>/dev/null; wait $DSHP 2>/dev/null || true
printf '{"session_id":"s-dsh","transcript_path":"/x/.dsh/t.jsonl","cwd":"%s"}' "$MAIN" | ONETREE_SESSION_PID=$$ $ONETREE session >/dev/null
eq "dsh: a process named dsh is listed, and a .dsh transcript is agent dsh" "$a $(jq -c '[.agent, .session]' "$TMP/state/sessions/$$.json")" 'dsh ["dsh","s-dsh"]'
n1=$(doctor_json | jq '[.checks[] | select(.name | test("\\.dsh"))] | length')
mkdir -p "$HOME/.dsh"   # install writes the rules block here when the directory exists; doctor then checks for it
n2=$(doctor_json | jq '[.checks[] | select(.name | test("\\.dsh/AGENTS.md"))] | length')
rmdir "$HOME/.dsh"
eq "doctor: a rules check for ~/.dsh only when ~/.dsh exists" "$n1 $n2" "0 1"

# ---- Codex hook trust: the expected hashes come from Codex's own algorithm, which reproduced every hash a real Codex had saved
mkdir -p "$HOME/.codex"
jq -n '{hooks: {SessionStart: [{hooks: [{type: "command", command: "/opt/x/notify.sh"}]}, {hooks: [{type: "command", command: "/opt/onetree/bin/onetree session", timeout: 10}]}],
  PreToolUse: [{matcher: "Edit|Write|MultiEdit|NotebookEdit|Bash|apply_patch", hooks: [{type: "command", command: "/opt/onetree/bin/onetree guard", timeout: 20}]}]}}' > "$HOME/.codex/hooks.json"
trust_cfg() { printf '[hooks.state."%s:session_start:1:0"]\ntrusted_hash = "%s"\n\n[hooks.state."%s:pre_tool_use:0:0"]\ntrusted_hash = "%s"\n' "$HOME/.codex/hooks.json" "$1" "$HOME/.codex/hooks.json" "$2" > "$HOME/.codex/config.toml"; }
codex_trust_ok() { doctor_json | jq -c '[.checks[] | select(.name | startswith("Codex trusts onetree")) | .ok]'; }
trust_cfg sha256:cee7b3e8d9a14f17d6e3b12c483447c0cf6418ba03e793c3aed853809670cde0 sha256:042a33cfcabf4e4af9b491323a7ecd929ac54d3ff085783c76ac171cdeb736e4; t1=$(codex_trust_ok)
trust_cfg sha256:cee7b3e8d9a14f17d6e3b12c483447c0cf6418ba03e793c3aed853809670cde0 sha256:32dd23be706e7fb1480d711fc2a4caaf3e379dec4268ca4961e1472d160b9efb; t2=$(codex_trust_ok)   # approved as /opt/old/bin/onetree guard, before it moved
rm "$HOME/.codex/config.toml"; t3=$(codex_trust_ok)
rm -rf "$HOME/.codex"
eq "doctor: Codex trusts onetree's hooks only while every saved hash matches; a guard approved at another path, or never approved, fails" "$t1 $t2 $t3" "[true] [false] [false]"
has_all "rules: they name dsh, and the read-only exception names the remote from onetree info" "$($ONETREE rules)" 'Claude, Codex, pi, dsh' 'git show <remote>/<branch>:<path>'

# ==== part 3
# ---- forks: origin is my fork, upstream the canonical repo. The integration branch (nodejs) is neither remote's HEAD,
# the fork lags the canonical repo, and PRs live on the canonical repo. URLs look like GitHub's; insteadOf maps them to local bare repos.
git init -q --bare -b master canonical.git
git clone -q canonical.git seed 2>/dev/null
( cd seed && echo base > app.txt && git add app.txt && git commit -qm base && git push -q origin master \
  && git switch -q -c nodejs && echo n1 > n.txt && git add n.txt && git commit -qm n1 && git push -q origin nodejs )
git clone -q --bare canonical.git fork.git 2>/dev/null
git -C fork.git branch -q main master && git -C fork.git symbolic-ref HEAD refs/heads/main
( cd seed && for i in 2 3 4; do echo "n$i" >> n.txt; git commit -qam "n$i"; done; git push -q origin nodejs )   # the fork is now 3 behind
git config --global url."$TMP/canonical.git".insteadOf "https://github.com/acme/app.git"
git config --global url."$TMP/fork.git".insteadOf "git@github-dev:dev/app.git"   # an ssh host alias, like a second GitHub account
git clone -q git@github-dev:dev/app.git fork-clone 2>/dev/null
FK=$TMP/fork-clone
git -C "$FK" remote add upstream https://github.com/acme/app.git && git -C "$FK" fetch -q upstream && git -C "$FK" remote set-head upstream -a >/dev/null
git -C "$FK" switch -q -c nodejs --track origin/nodejs   # the main checkout sits on the fork's lagging copy
CANON_NODEJS=$(git -C canonical.git rev-parse nodejs); FORK_NODEJS=$(git -C fork.git rev-parse nodejs)

# a gh that answers from JSON files the way gh would (--limit, then -q), and logs each call with the token it was given
export GH_DATA=$TMP/ghdata; mkdir -p "$GH_DATA"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
echo "$* tok=${GH_TOKEN:-}" >> "$GH_LOG"
if [ "$1 $2" = "auth token" ]; then user=""; [ "$3" = "--user" ] && user=$4; echo "tok-${user:-active}"; exit 0; fi
[ -n "$GH_FAIL" ] && { echo "GraphQL: Could not resolve to a Repository" >&2; exit 1; }
head=""; q="."; limit=100; prev=""
for a in "$@"; do case "$prev" in --head) head=$a ;; -q) q=$a ;; --limit) limit=$a ;; esac; prev=$a; done
f="$GH_DATA/merged.json"; [ -n "$head" ] && f="$GH_DATA/head-$(echo "$head" | tr / _).json"
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi | jq -r ".[0:$limit] | $q"
GH
chmod +x "$TMP/bin/gh"
jq -n '[range(7) | {baseRefName:"nodejs", headRefOid:"aaaa"}] + [range(2) | {baseRefName:"master", headRefOid:"bbbb"}]' > "$GH_DATA/merged.json"

out=$($ONETREE init --no-guard --root "$TMP/worktrees" "$FK" 2>&1) || true
json_is "fork: base is upstream by the upstream convention, push is origin (an ssh alias still yields owner/repo), integration is the base's HEAD" "$($ONETREE info --json "$FK")" \
  '.remotes.base == {name:"upstream", source:"upstream-convention", slug:"acme/app"} and .remotes.push == {name:"origin", source:"default", slug:"dev/app"} and .integration == "master" and .sources.integration == "remote-head"'
has_all "fork: init's info names both remotes and why" "$out" '^remote +upstream \(upstream-convention\) acme/app$' '^pushRemote +origin \(default\) dev/app$'
has "fork: init says most merged PRs went elsewhere, with the counts" "$out" '^onetree: warning: 7 of the last 9 merged PRs on acme/app went into nodejs, 2 into master; integration is master \(upstream/HEAD\)\. If PRs target nodejs: onetree init --integration nodejs$'
# the shape of a real repo: the most common base is not a majority, because PRs also merge into staging and development
jq -n '[range(21) | {baseRefName:"nodejs", headRefOid:"aaaa"}] + [range(14) | {baseRefName:"staging", headRefOid:"cccc"}]
       + [range(14) | {baseRefName:"development", headRefOid:"dddd"}] + [{baseRefName:"master", headRefOid:"bbbb"}]' > "$GH_DATA/merged.json"
out=$(ONETREE_PR_TTL=0 $ONETREE init "$FK" 2>&1 >/dev/null) || true
has "fork: the hint fires on the most common base, not only a majority, and names the others" "$out" '^onetree: warning: 21 of the last 50 merged PRs on acme/app went into nodejs, 1 into master \(others: (staging 14, development 14|development 14, staging 14)\); integration is master \(upstream/HEAD\)\. If PRs target nodejs: onetree init --integration nodejs$'
jq -n '[range(2) | {baseRefName:"nodejs", headRefOid:"aaaa"}] + [{baseRefName:"master", headRefOid:"bbbb"}]' > "$GH_DATA/merged.json"
out=$(ONETREE_PR_TTL=0 $ONETREE init "$FK" 2>&1 >/dev/null) || true
if grep -q 'merged PRs' <<<"$out"; then bad "fork: no hint from fewer than three merged PRs" "$out"; else ok "fork: no hint from fewer than three merged PRs"; fi
out=$(ONETREE_PR_TTL=0 GH_FAIL=1 $ONETREE init "$FK" 2>&1 >/dev/null) || true
has "fork: when gh cannot see the base repo, init says so and how to pick an account" "$out" '^onetree: note: gh could not list pull requests on acme/app \(as gh.s active account; if another `gh auth login` account can see it: onetree init --gh-user <login>\)'
out=$($ONETREE init --integration nodejs "$FK" 2>&1) || true
eq "fork: --integration is recorded locally, and the warning stops once it matches where PRs merge" "$(grep -c 'merged PRs' <<<"$out") $($ONETREE info --json "$FK" | jq -c '[.integration, .sources.integration]')" '0 ["nodejs","local"]'

# explicit keys, a committed .onetree that names remotes, an upstream that is the same repo, git's own remote.pushDefault
$ONETREE init --remote origin "$FK" >/dev/null 2>&1
eq "fork: onetree.remote overrides the convention, and PR lookups follow it" "$($ONETREE info --json "$FK" | jq -c .remotes.base) $([[ $(gh_calls 'pr list -R dev/app') -gt 0 ]] && echo asked-dev)" '{"name":"origin","source":"local","slug":"dev/app"} asked-dev'
git -C "$FK" config --unset onetree.remote
FORK_CALLS=$(gh_calls '-R dev/app')   # from here on the base is upstream again
s1=0; $ONETREE init --remote nope "$FK" >/dev/null 2>&1 || s1=$?
s2=0; $ONETREE init --file --push-remote origin "$FK" >/dev/null 2>&1 || s2=$?
s3=0; $ONETREE init --file --gh-user dev-org "$FK" >/dev/null 2>&1 || s3=$?
eq "fork: init refuses a remote that does not exist, and a remote name or a gh login in the committed .onetree" "$s1 $s2 $s3" "1 1 1"
printf '[onetree]\n\tremote = origin\n\tghUser = someone\n' > "$FK/.onetree"
eq "fork: a committed .onetree cannot pick remotes or the gh account; info warns and doctor fails its check" \
  "$($ONETREE info --json "$FK" | jq -c '[.remotes.base.name, .remotes.ghUser.login, .remotes.ignoredFromFile]') $($ONETREE info "$FK" 2>&1 >/dev/null | grep -c '^onetree: warning: the committed \.onetree sets remote; ignored') $(doctor_json | jq -c '[.checks[] | select(.name | test("committed .onetree of .*fork-clone"))] | map(.ok)')" \
  '["upstream",null,["remote","ghUser"]] 1 [false]'
rm -f "$FK/.onetree"
git -C "$FK" config remote.pushDefault upstream
json_is "fork: git's remote.pushDefault picks the push remote when onetree.pushRemote is unset" "$($ONETREE info --json "$FK")" '.remotes.push == {name:"upstream", source:"remote.pushDefault", slug:"acme/app"}'
git -C "$FK" config --unset remote.pushDefault
git clone -q git@github-dev:dev/app.git same-clone 2>/dev/null
git -C same-clone remote add upstream https://github.com/DEV/app.git   # the same repo, spelled differently
json_is "fork: an upstream that is the same repo as origin is not a fork" "$($ONETREE info --json "$TMP/same-clone")" '.remotes.base == {name:"origin", source:"default", slug:"dev/app"}'

# new: cut from the base, track it, push to the fork
fa=$($ONETREE new fork-a "$FK")
eq "fork: new cuts from upstream/nodejs, not the fork's lagging origin/nodejs" "$(git -C "$fa" rev-parse HEAD) $([[ "$CANON_NODEJS" != "$FORK_NODEJS" ]] && echo fork-lags)" "$CANON_NODEJS fork-lags"
eq "fork: the new branch tracks upstream/nodejs and pushes to origin" "$(git -C "$FK" config branch.feature/fork-a.remote) $(git -C "$FK" config branch.feature/fork-a.merge) $(git -C "$FK" config branch.feature/fork-a.pushRemote)" "upstream refs/heads/nodejs origin"
json_is "fork: ls measures behind against upstream/nodejs, and a fresh worktree has nothing unpushed against the base" "$($ONETREE ls --json "$FK")" '.[0].kind == "main" and .[0].behind == 3 and .[0].integration == "nodejs" and .[1].slug == "fork-a" and .[1].unpushed == 0'
( cd "$fa" && echo a > a.txt && git add a.txt && git commit -qm a )
u1=$($ONETREE ls --json "$FK" | jq '.[1].unpushed')
( cd "$fa" && git push -q 2>/dev/null ) || true   # bare: no remote, no refspec
eq "fork: a commit is unpushed; a bare git push lands it on the fork, never on the canonical repo; then nothing is unpushed" \
  "$u1 $(git -C fork.git show-ref -q --verify refs/heads/feature/fork-a && echo on-fork) $(git -C canonical.git show-ref -q --verify refs/heads/feature/fork-a && echo on-canonical || echo not-canonical) $($ONETREE ls --json --fresh "$FK" | jq '.[1].unpushed')" \
  "1 on-fork not-canonical 0"
eq "fork: gh is asked about the canonical repo, never about the fork" "$([[ $(gh_calls 'pr list -R acme/app') -gt 0 ]] && echo asked-canonical) $(gh_calls '-R dev/app')" "asked-canonical $FORK_CALLS"

# a fork PR's branch name is not unique: someone else's PR with the same head name must not count
jq -n --arg sha "$(git -C "$fa" rev-parse HEAD)" '[{state:"OPEN", headRefOid:"1111111111111111111111111111111111111111", headRepositoryOwner:{login:"someone"}},
                                                  {state:"MERGED", headRefOid:$sha, headRepositoryOwner:{login:"Dev"}}]' > "$GH_DATA/head-feature_fork-a.json"
eq "fork: the PR state is the one whose head lives in the fork's owner (case-insensitive), asked for with head owners" \
  "$($ONETREE ls --json --fresh "$FK" | jq -c '.[1].pr') $(grep -F 'pr list -R acme/app --head feature/fork-a' "$GH_LOG" | tail -1 | grep -c -- '--limit 30 --json state,headRefOid,headRepositoryOwner')" \
  "{\"state\":\"MERGED\",\"head\":\"$(git -C "$fa" rev-parse HEAD)\"} 1"
json_is "fork: gc removes a worktree whose PR merged on the canonical repo" "$($ONETREE gc --dry-run --json --fresh "$FK" | jq -c '.[] | select(.slug == "fork-a")')" '.gc.action == "would-remove" and .gc.code == "pr-merged"'

# merged into the canonical integration branch with no PR: gc sees it there, though the fork's nodejs never moved
fb=$($ONETREE new fork-b "$FK")
( cd "$fb" && echo b > b.txt && git add b.txt && git commit -qm b && git push -q upstream HEAD:nodejs 2>/dev/null )
$ONETREE init --stale 0 "$FK" >/dev/null 2>&1
eq "fork: gc marks a worktree merged once its head is on upstream/nodejs, though origin/nodejs lacks it" \
  "$($ONETREE gc --dry-run --json --fresh "$FK" | jq -c '.[] | select(.slug == "fork-b") | .gc | [.action, .code]') $(git -C "$FK" merge-base --is-ancestor "$(git -C "$fb" rev-parse HEAD)" origin/nodejs && echo on-origin || echo not-on-origin)" \
  '["would-remove","in-integration"] not-on-origin'

# review: the base first, then the push remote, and say which
rv=$($ONETREE review feature/fork-a "$FK" 2>"$TMP/review.err") || true
eq "fork: review checks out a branch only the fork has, and says which remote it used" "$(git -C "$rv" rev-parse HEAD) $(grep -c '^onetree: reviewing origin/feature/fork-a$' "$TMP/review.err")" "$(git -C fork.git rev-parse feature/fork-a) 1"
if out=$($ONETREE review feature/nope "$FK" 2>&1); then bad "fork: review of a missing branch fails"; else has "fork: review of a missing branch fails, naming both remotes" "$out" '^onetree: feature/nope is on neither upstream nor origin$'; fi

# park: a guarded fork mirror on nodejs fast-forwards from the base, not from the lagging fork
$ONETREE init --guard "$FK" >/dev/null 2>&1
out=$($ONETREE park "$FK" 2>&1) || true
eq "fork: park pulls the integration branch from upstream, and says it fast-forwarded" "$(git -C "$FK" rev-parse HEAD) $(grep -cE '^fast-forwarded fork-clone nodejs to [0-9a-f]{7}$' <<<"$out")" "$(git -C canonical.git rev-parse nodejs) 1"
json_is "doctor: the fork's remotes resolve" "$(doctor_json)" '.checks | map(select(.name | test("remotes of .*fork-clone resolve \\(base upstream, push origin\\)"))) | .[0].ok == true'
$ONETREE init --no-guard "$FK" >/dev/null 2>&1

# the gh account: onetree.ghUser makes onetree's gh calls for this repo use that account's token, without switching gh's active account
$ONETREE init --gh-user dev-org "$FK" >/dev/null 2>&1
$ONETREE ls --json --fresh "$FK" >/dev/null
eq "fork: with ghUser, gh runs with that account's token, and info shows the account" "$(grep -F 'pr list -R acme/app --head feature/fork-b' "$GH_LOG" | tail -1 | grep -c 'tok=tok-dev-org$') $($ONETREE info --json "$FK" | jq -c .remotes.ghUser)" '1 {"login":"dev-org","source":"local"}'
has_all "fork: the snippet reads the integration branch from upstream, says where to push and where the PR opens, with the account" "$($ONETREE snippet "$FK")" \
  'read `upstream/nodejs` via `git fetch upstream` \+ `git show`' \
  'push the branch to `origin` \(a bare `git push -u` does\) and open the PR on `acme/app` into `nodejs`' \
  'GH_TOKEN=\$\(gh auth token --user dev-org\) gh pr create --repo acme/app --base nodejs --head dev:<branch>'
$ONETREE rm --force fork-a "$FK" >/dev/null 2>&1 || true; $ONETREE rm --force fork-b "$FK" >/dev/null 2>&1 || true; $ONETREE rm --force review-feature-fork-a "$FK" >/dev/null 2>&1 || true

# ==== part 4
# ---- writable local state in a guarded mirror. The lock covers what git tracks or would track; what git ignores is the working state
# of the repo's tools (node_modules, husky's .husky/_, tsc's build info, .env) and stays writable; onetree.writable names local state to create
git init -q --bare -b main w.git
git clone -q w.git wmain 2>/dev/null
WM=$TMP/wmain
( cd wmain && mkdir -p .claude src .husky dist && echo c > .claude/collab.json && echo a > src/a.ts && echo h > .husky/pre-push && echo k > dist/keep.js \
  && printf '.env\nnode_modules\ndist/\n.tsbuildinfo\n*.log\n.eslintcache\nlogs/*\n!logs/keep.txt\n' > .gitignore \
  && printf '{\n  "compilerOptions": {\n    // "tsBuildInfoFile": "./commented.tsbuildinfo",\n    "incremental": true,\n    "tsBuildInfoFile": "./.tsbuildinfo"\n  }\n}\n' > tsconfig.json \
  && echo hi > README.md && echo t > tracked.txt && git add . && git add -f dist/keep.js && git commit -qm init && git push -q origin main )
printf '.claude/standup/\n' >> "$WM/.git/info/exclude"   # how the /standup skill's notes are kept out of git in the real repo
mkdir -p "$WM/node_modules/pkg" "$WM/.husky/_" "$WM/logs"; echo m > "$WM/node_modules/pkg/index.js"; echo '*' > "$WM/.husky/_/.gitignore"; echo s > "$WM/.husky/_/husky.sh"
printf 'A=1\n' > "$WM/.env"; echo l > "$WM/src/x.log"; echo n > "$WM/dist/new.js"; echo note > "$WM/notes.txt"
$ONETREE init --no-guard --root "$TMP/worktrees" "$WM" >/dev/null 2>&1
modes() { local f r=""; for f in "$@"; do if [[ -w "$WM/$f" ]]; then r+="$f:w "; else r+="$f:ro "; fi; done; printf '%s' "$r"; }
wl() { $ONETREE info --json "$WM" | jq -c '.writable.paths'; }
wrong=""
for c in 'README.md|README\.md is tracked' '.claude/|\.claude/ holds tracked files' 'notes.txt|notes\.txt is not ignored by git.*--exclude-writable.*stays read-only' \
         '../x|must be a path inside the repo' '.git/|must be a path inside the repo'; do
  if out=$($ONETREE init --writable "${c%%|*}" "$WM" 2>&1); then wrong+=" accepted ${c%%|*};"; elif ! grep -qE -- "${c#*|}" <<<"$out"; then wrong+=" ${c%%|*}: $out;"; fi
done
eq "writable: init refuses a tracked file, a directory holding tracked files, an unignored path (naming both fixes), a path out of the repo, .git; nothing is stored" "${wrong:-none} $(wl)" "none []"
echo s > "$WM/scratch.txt"
$ONETREE init --writable "scratch.txt" --exclude-writable "$WM" >/dev/null 2>&1
eq "writable: --exclude-writable adds an unignored path to .git/info/exclude, and then accepts it" "$(grep -cxF '/scratch.txt' "$WM/.git/info/exclude") $($ONETREE info --json "$WM" | jq -c .writable)" '1 {"paths":["scratch.txt"],"source":"local"}'

echo change >> "$WM/tracked.txt"   # a real leftover, next to an untracked unignored notes.txt
st=0; out=$($ONETREE init --guard --writable "./.env .claude/standup/ logs/" "$WM" 2>&1) || st=$?
eq "writable: init --guard locks (verified) and stores the list normalised; the ignored set, listed entries (a missing one created) and the now-excluded scratch.txt stay writable" \
  "$st $($ONETREE info --json "$WM" | jq -c '[.guard, .writable.paths, .lockIgnored]') $(modes node_modules node_modules/pkg/index.js .husky/_ .husky/_/husky.sh .env .tsbuildinfo src/x.log dist/new.js .claude/standup logs scratch.txt)" \
  '0 [true,[".env",".claude/standup/","logs/"],false] node_modules:w node_modules/pkg/index.js:w .husky/_:w .husky/_/husky.sh:w .env:w .tsbuildinfo:w src/x.log:w dist/new.js:w .claude/standup:w logs:w scratch.txt:w '
eq "writable: what git tracks or would track is locked" "$(modes . README.md src src/a.ts .husky .husky/pre-push .claude .claude/collab.json dist dist/keep.js tracked.txt notes.txt)" \
  ".:ro README.md:ro src:ro src/a.ts:ro .husky:ro .husky/pre-push:ro .claude:ro .claude/collab.json:ro dist:ro dist/keep.js:ro tracked.txt:ro notes.txt:ro "
eq "writable: tsc's build info and the eslint cache are created empty in the locked root (not a commented-out path), and init says so" \
  "$(wc -c < "$WM/.tsbuildinfo" | tr -d ' ') $(wc -c < "$WM/.eslintcache" | tr -d ' ') $([[ -e "$WM/commented.tsbuildinfo" ]] && echo made || echo none) $(grep -c '^onetree: created \.tsbuildinfo empty: its tool cannot create it in a locked directory, but rewrites it in place$' <<<"$out")" "0 0 none 1"
has_all "writable: on a dirty main init's warning names onetree carry, a tracked change is a leftover, an untracked unignored file gets both fixes" "$out" \
  'is guarded but dirty; move the work into a worktree with `onetree carry <slug>`' \
  '^onetree:   leftover   M tracked\.txt$' \
  '^onetree:   leftover  \?\? notes\.txt \(untracked and not ignored, so locked: commit it from a worktree \(onetree carry <slug> --untracked moves it\), or keep it local: onetree init --writable-add notes\.txt --exclude-writable\)$'
eq "writable: info and the session hint say gitignored local state stays writable" \
  "$($ONETREE info "$WM" | grep -cE '^writable +gitignored paths, and listed: \.env \.claude/standup/ logs/$') $(cd "$WM" && $ONETREE session </dev/null | grep -cE 'Gitignored local state \(dependencies, caches, \.env, agent settings\) stays writable here, without a worktree; an ignored file in a locked directory takes in-place writes only\.$')" "1 1"
json_is "doctor: the mirror's only writable entries are local state, the listed ones are untracked and ignored, no tool cache is missing" "$(doctor_json)" \
  '[.checks[] | select(.name | test("wmain (has no user-writable|has no tool cache missing)|writable paths of .*wmain"))] | length == 3 and all(.ok)'
ln -s "$WM/README.md" "$TMP/readme-link"   # outside the mirror, pointing into it
guard_table "writable guard: writes into ignored or listed local state pass (Edit, Write, redirects, tee, cp, and inside a writable directory mkdir, sed -i, perl -i), and so do file commands writing outside the mirror" "$WM" \
  allow "onetree info 2>&1 | tee $TMP/outside.log"   allow "cp README.md $TMP/copy" \
  allow "mkdir -p $TMP/out && touch $TMP/out/f && mv $TMP/out/f $TMP/out/g && rm $TMP/out/g" \
  allow 'cat .env | tee' \
  allow 'Edit:.claude/standup/x.md'       allow "Write:$WM/.env" \
  allow 'Edit:node_modules/pkg/index.js'  allow 'Write:node_modules/new.js' \
  allow 'Write:.tsbuildinfo'              allow "Edit:$WM/src/x.log" \
  allow 'echo hi >> .claude/standup/x.md' allow "printf 'A=2\n' > .env" \
  allow 'cat .env | tee -a .claude/standup/x.md'      allow 'cp README.md .claude/standup/' \
  allow 'mkdir -p .claude/standup/sub && mkdir -p node_modules/sub/dir && echo y > node_modules/sub/f.js' \
  allow "sed -i.bak 's/hi/ho/' .claude/standup/x.md" allow "perl -pi -e 's/a/b/' .claude/standup/x.md" \
  allow "$(printf "cat > .claude/standup/n.md <<'EOF'\nnotes\nEOF")"
guard_table "writable guard: writes to what git tracks or would track are refused (.. resolved, new unignored files, every redirect), and so are writers a locked directory defeats" "$WM" \
  block 'Edit:.claude/standup/../collab.json'   block 'Edit:node_modules/../README.md' \
  block 'Write:logs/keep.txt'                   block 'Write:src/new.ts' \
  block 'Edit:notes.txt' \
  block~'Gitignored local state \(dependencies, caches, \.env, local settings\) stays writable here; tracked files, and new files git would track, do not\.$' 'Edit:README.md' \
  block~'onetree guard \(a new file in a locked directory\).*git ignores src/new\.log, but its directory is locked, so nothing can create it here; .*`onetree init --writable-add src/new\.log` creates it once\.$' 'Write:src/new.log' \
  block~'an output redirect' 'echo x > .claude/standup/../collab.json'   block~'an output redirect' 'echo x > logs/keep.txt' \
  block~'an output redirect' 'echo x > .env > README.md'                 block~'a new file in a locked directory' 'echo x > src/new.log' \
  block~'mutating git' 'git commit -qm x'                                block~'a file-changing command' 'mv .claude/standup/x.md README.md' \
  block~'a file-changing command' 'rm .env'                              block 'rm -rf node_modules' \
  block~'an in-place rewrite of a file whose directory is locked' "sed -i.bak 's/A/B/' .env" \
  block~'an in-place rewrite of a file whose directory is locked' "perl -pi -e 's/A/B/' .env" \
  block~'a file-changing command' "perl -pi -e 's/a/b/' README.md" \
  block~'a file-changing command' "mv README.md $TMP/moved"   block~'a file-changing command' "cp $TMP/copy README.md" \
  block~'a file-changing command' 'tee README.md'              block~'a file-changing command' "echo x | tee $TMP/readme-link" \
  block~'a file-changing command' 'npx something'
# what the filesystem lets through, outside the guard: husky rewriting its shims, npm emptying node_modules, tsc rewriting its build info
( cd "$WM" && printf 'A=2\n' > .env && printf 'B=3\n' >> .env && printf 'info' > .tsbuildinfo \
  && rm .husky/_/husky.sh && echo new > .husky/_/husky.sh && rm -rf node_modules/pkg && mkdir node_modules/pkg2 && echo x > node_modules/pkg2/i.js \
  && cd .claude/standup && printf 'x\n' > f.md && sed -i.bak 's/x/y/' f.md && perl -pi -e 's/y/z/' f.md && printf 'w\n' > t && mv t f2.md ) 2>/dev/null || true
eq "fs: an ignored file in a locked directory takes in-place writes; inside an ignored or listed directory every writer works" \
  "$(tr '\n' ' ' < "$WM/.env")$(cat "$WM/.tsbuildinfo") $(cat "$WM/.husky/_/husky.sh") $(cat "$WM/node_modules/pkg2/i.js") $(cat "$WM/.claude/standup/f.md") $(cat "$WM/.claude/standup/f2.md")" "A=2 B=3 info new x z w"
r=""
if ( cd "$WM" && sed -i.bak 's/A=2/A=4/' .env ) 2>/dev/null; then r+="sed-ok "; else r+="sed-fails "; fi
st=0; ( cd "$WM" && perl -pi -e 's/A=2/A=5/' .env ) 2>/dev/null || st=$?; r+="perl-exit-$st-$(head -1 "$WM/.env") "
if ( cd "$WM" && printf 'A=6\n' > .env.tmp && mv .env.tmp .env ) 2>/dev/null; then r+="mv-ok "; else r+="mv-fails "; fi
if ( echo x > "$WM/src/new.ts" ) 2>/dev/null; then r+="create-ok "; else r+="create-fails "; fi
if ( printf 'x\n' > "$WM/README.md" ) 2>/dev/null; then r+="tracked-ok"; else r+="tracked-fails"; fi
eq "fs: in a locked directory sed -i fails, perl -i fails silently (exit 0, unchanged; so the guard refuses both), write-then-mv and new files fail, tracked files are read-only" \
  "$r" "sed-fails perl-exit-0-A=2 mv-fails create-fails tracked-fails"
$ONETREE gc "$WM" >/dev/null 2>&1 || true
eq "gc on a dirty guarded main: the relock keeps local state writable, and the uncommitted change survives (gc used to switch -f it away)" \
  "$(modes .env .claude/standup node_modules .claude)$(tail -1 "$WM/tracked.txt") $(git -C "$WM" status --porcelain tracked.txt)" ".env:w .claude/standup:w node_modules:w .claude:ro change  M tracked.txt"
: > "$WM/.git/onetree-switching"   # the marker park leaves while it switches: this time it is a switch onetree started and did not finish
out=$($ONETREE park "$WM" 2>&1) || true
eq "a switch onetree started and did not finish is repaired, and its marker cleared" "$(grep -c '^onetree: repairing half-applied switch on wmain onto main$' <<<"$out") $([[ -e "$WM/.git/onetree-switching" ]] && echo left || echo gone) [$(git -C "$WM" status --porcelain tracked.txt)]" "1 gone []"
# --writable-add / --writable-remove edit the list instead of replacing it
printf 'tmp/\n' >> "$WM/.git/info/exclude"
out=$($ONETREE init --writable-add "tmp/ ./.env" "$WM" 2>&1)
eq "writable-add: appends what is new, once; prints the list; creates a missing entry under the locked root" "$(wl) $(grep -c '^writable: \.env \.claude/standup/ logs/ tmp/$' <<<"$out") $(modes tmp)" '[".env",".claude/standup/","logs/","tmp/"] 1 tmp:w '
out=$($ONETREE init --writable-remove ".env logs" "$WM" 2>&1); out2=$($ONETREE init --writable-remove ".env" "$WM" 2>&1)
eq "writable-remove: drops entries (d matches d/) and prints the list; removing an absent one is a no-op with a note" "$(wl) $(grep -c '^writable: \.claude/standup/ tmp/$' <<<"$out") $(grep -c 'note: \.env was not in the writable list' <<<"$out2")" '[".claude/standup/","tmp/"] 1 1'
s1=0; out=$($ONETREE init --writable-add "README.md" "$WM" 2>&1) || s1=$?
s2=0; out2=$($ONETREE init --writable ".env" --writable-add "tmp/" "$WM" 2>&1) || s2=$?
eq "writable-add: validated like --writable and never mixed with it; a refused edit leaves the list" "$s1 $(grep -c 'README\.md is tracked' <<<"$out") $s2 $(grep -c 'use one or the other' <<<"$out2") $(wl)" '1 1 1 1 [".claude/standup/","tmp/"]'
# onetree.lockIgnored: locking the ignored set too, and back
$ONETREE init --lock-ignored "$WM" >/dev/null 2>&1
st=0; jq -nc --arg cwd "$WM" '{tool_name:"Edit",cwd:$cwd,tool_input:{file_path:"src/x.log"}}' | ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null 2>&1 || st=$?
eq "lockIgnored: ignored paths are locked too and only listed ones stay writable; the guard and info agree" \
  "$(modes node_modules node_modules/pkg2/i.js .husky/_ .env src/x.log .claude/standup)$st $($ONETREE info "$WM" | grep -cE '^writable +\.claude/standup/ tmp/ \(onetree\.lockIgnored: listed paths only\)$')" \
  "node_modules:ro node_modules/pkg2/i.js:ro .husky/_:ro .env:ro src/x.log:ro .claude/standup:w 2 1"
$ONETREE init --no-lock-ignored "$WM" >/dev/null 2>&1
eq "lockIgnored off: the lock of the ignored set is undone" "$(modes node_modules node_modules/pkg2/i.js .husky/_ .env src/x.log README.md)" \
  "node_modules:w node_modules/pkg2/i.js:w .husky/_:w .env:w src/x.log:w README.md:ro "
$ONETREE init --no-guard "$WM" >/dev/null 2>&1

# ==== part 5
# ---- sessions follow their worktree. A host fixes a session's folder at launch; after onetree new only the Claude app can follow, so onetree
# tells each agent how to work there, and the guard names the session's own worktree. Processes stand in for agents by their argv
mkdir -p "$HOME/.claude"   # Claude is installed: a guarded mirror keeps the Claude app's own worktree folder creatable
git clone -q origin.git cw-main 2>/dev/null; CW=$TMP/cw-main
$ONETREE init --guard --root "$TMP/cw-worktrees" "$CW" >/dev/null 2>&1
( exec -a claude sleep 60 ) & HC=$!
( exec -a "codex app-server --listen stdio://" sleep 60 ) & HX=$!
( exec -a codex sleep 60 ) & HY=$!
( exec -a pi sleep 60 ) & HP=$!
( exec -a "node --import tsx/esm /src/deepseek-harness/apps/cli/src/bin.ts web" sleep 60 ) & HD=$!   # dsh run from its source checkout
sleep 0.3
hw=$($ONETREE new host-a "$CW" 2>/dev/null)
wrong=""
while IFS='|' read -r pid envs re; do   # onetree new again on that worktree, as each agent: stdout stays the path, stderr names the next step
  err=$(env $envs ONETREE_SESSION_PID="$pid" $ONETREE new host-a "$CW" 2>&1 >"$TMP/host-out") || true
  got="$(cat "$TMP/host-out")|$(grep '^onetree: next' <<<"$err" || echo none)"
  [[ "${got%%|*}" == "$hw" && "${got#*|}" =~ $re ]] || wrong+=" [$pid $envs => $got]"
done <<EOF
$HC|CLAUDE_CODE_ENTRYPOINT=claude-desktop|change_directory. with $hw .*the app's file pane, diff, terminal and PR card
$HC|CLAUDE_CODE_ENTRYPOINT=cli|prefix every command with .cd $hw &&. and edit by absolute path. Do not call .EnterWorktree.
$HX|X=1|open a new thread on $hw
$HY|X=1|type ./cd $hw.
$HY|CLAUDE_CODE_ENTRYPOINT=claude-desktop|type ./cd $hw.
$HP|X=1|onetree's pi extension runs this session's commands in $hw
$HD|X=1|pass .workdir. $hw to every bash call
$$|DSH_SESSION_ID=s-dsh-env|pass .workdir. $hw to every bash call
$$|X=1|^none$
EOF
eq "new: stdout is the path, and the next step fits the agent that ran it (Claude app, Claude CLI, Codex app, Codex CLI, a Codex started from a Claude app shell, pi, dsh run from its source checkout, a dsh shell command known only by DSH_SESSION_ID); a person gets none" "$wrong" ""
chmod u-w "$CW/.git"; sb=$($ONETREE new sandboxed "$CW" 2>&1 || true); chmod u+w "$CW/.git"
eq "new: where the main's .git cannot be written (a sandboxed agent session) it says so and how to start a session for the task, and makes nothing" \
  "$(grep -c "cannot write $CW/.git, so no worktree can be made from here.*onetree launch --task sandboxed <agent>" <<<"$sb") $([[ -e "$TMP/cw-worktrees/cw-main/sandboxed" ]] && echo made || echo none)" "1 none"
# a sandbox refuses writes the mode bits allow, so new tries each place it writes before git does anything (#24): the
# folder the worktree goes in, and the global config, which it writes only when the guarded list changes
mkdir -p "$TMP/rocfg"; cp "$ONETREE_CONFIG" "$TMP/rocfg/config"; chmod a-w "$TMP/rocfg/config" "$TMP/rocfg"
git clone -q origin.git ro-unreg 2>/dev/null
ro_new() { { ONETREE_CONFIG=$TMP/rocfg/config "$@" >/dev/null; } 2>&1 && echo made || true; }
chmod u-w "$TMP/cw-worktrees/cw-main"
nr=$(ro_new $ONETREE new sb-root "$CW"); nd=$(DSH_SESSION_ID=s-dsh-sb ro_new $ONETREE new sb-root "$CW")
chmod u+w "$TMP/cw-worktrees/cw-main"
nc=$(ro_new $ONETREE new sb-cfg "$CW"); nu=$(ro_new $ONETREE new sb-unreg "$TMP/ro-unreg")
chmod u+w "$TMP/rocfg" "$TMP/rocfg/config"
eq "new: tries every place it writes first, and names the one it cannot write: the worktree folder (dsh is told to call onetree_new), the global config only when it must change; nothing is made" \
  "$(grep -c "cannot write $TMP/cw-worktrees/cw-main, so no worktree can be made from here" <<<"$nr") $(grep -c "cannot write $TMP/cw-worktrees/cw-main, so no worktree can be made from inside dsh's sandbox\. call the .onetree_new. tool with slug sb-root" <<<"$nd") $(git -C "$CW" show-ref -q --verify refs/heads/feature/sb-root && echo branch || echo no-branch) | $(tail -1 <<<"$nc") $([[ -d "$TMP/cw-worktrees/cw-main/sb-cfg" ]] && echo there) | $(grep -c "cannot write $TMP/rocfg/config" <<<"$nu")" \
  "1 1 no-branch | made there | 1"
hc_out=$(jq -nc --arg cwd "$MAIN" '{name: "hc-a", cwd: $cwd}' | ONETREE_HOST=claude-app $ONETREE hook-create 2>"$TMP/hc-err")
eq "hook-create: Claude's worktree in a registered repo is onetree's, and a hook prints no next step" "$hc_out $(grep -c '^onetree: next' "$TMP/hc-err")" "$TMP/worktrees/main/hc-a 0"
b1=$(CLAUDE_CODE_SESSION_ID=s-bind ONETREE_SESSION_PID=$HC $ONETREE new bind-1 "$CW" 2>/dev/null)
b2=$(CLAUDE_CODE_SESSION_ID=s-bind ONETREE_SESSION_PID=$HC $ONETREE new bind-2 "$CW" 2>/dev/null)
bp=$(ONETREE_SESSION_PID=$HP $ONETREE new bind-pi "$CW" 2>/dev/null)
bx=$(CODEX_THREAD_ID=t-app ONETREE_SESSION_PID=$HX $ONETREE new bind-app "$CW" 2>/dev/null)   # one app-server serves every thread: found by thread id alone
aw=$(cd "$CW" && CLAUDE_CODE_SESSION_ID=s-auto ONETREE_HOST=claude-cli $ONETREE auto codex 2>/dev/null)
json_is "auto: a worktree the wrapper makes for a new agent is not bound to the session that ran the wrapper" "$($ONETREE events --json --kind new | jq -c 'map(select(.path == "'"$aw"'")) | .[0]')" \
  '.host == "" and .session == "" and .pid == null'
json_is "new: the event records which agent session made the worktree" "$($ONETREE events --json --kind new | jq -c 'map(select(.path == "'"$b2"'")) | .[0]')" \
  '.agent == "claude" and .host == "claude-cli" and .session == "s-bind" and .pid == '"$HC"' and (.pidStart | length) > 0'
refusal() { { jq -nc --arg cwd "$CW" --arg s "$1" '{tool_name: "Bash", cwd: $cwd, session_id: $s, tool_input: {command: "git stash"}}' | ONETREE_SESSION_PID=$2 ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null; } 2>&1 || true; }
g1=$(refusal s-bind "$HC"); g2=$(refusal "" "$HP"); g3=$(refusal s-other $$); g4=$(refusal t-app "$HX")
eq "guard: a refusal names the newest worktree of the session (found by session id, else by its pid), or says how to make one" \
  "$(grep -c "already has a worktree, $b2: do it there" <<<"$g1") $(grep -c "already has a worktree, $bp: do it there" <<<"$g2") $(grep -c 'Work in a worktree instead: run `onetree new <slug> cw-main`' <<<"$g3") $(grep -c "already has a worktree, $bx: do it there" <<<"$g4")" "1 1 1 1"
jq -nc --arg cwd "$CW" '{name: "agent-aa31dba2ed770a65d", cwd: $cwd}' | CLAUDE_CODE_SESSION_ID=s-bind ONETREE_SESSION_PID=$HC ONETREE_HOST=claude-cli $ONETREE hook-create >/dev/null 2>&1
sa=$({ jq -nc --arg cwd "$CW" '{tool_name: "Bash", cwd: $cwd, session_id: "s-bind", agent_id: "aa31dba2ed770a65d", tool_input: {command: "git stash"}}' | ONETREE_SESSION_PID=$HC ONETREE_HOST=claude-cli ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null; } 2>&1 || true)
eq "subagents: an isolated subagent's worktree is never its parent session's, and a refused subagent is told to cd, not to move the session" \
  "$(grep -c "already has a worktree, $b2: do it there" <<<"$(refusal s-bind "$HC")") $(grep -c 'a subagent stays in the folder' <<<"$sa") $(grep -c 'EnterWorktree. with path' <<<"$sa")" "1 1 0"
bd=$(DSH_SESSION_ID=s-dsh-bind $ONETREE new bind-dsh "$CW" 2>/dev/null)
gd=$({ jq -nc --arg cwd "$CW" '{tool_name: "Bash", cwd: $cwd, session_id: "s-dsh-bind", agent: "dsh", tool_input: {command: "git stash"}}' | ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null; } 2>&1 || true)
eq "dsh: a worktree made from a dsh shell command is bound to its session by DSH_SESSION_ID, and a refusal its plugin asks for names that worktree with dsh's next step, whatever process dsh runs as" \
  "$(grep -c "already has a worktree, $bd: do it there. To work there, pass .workdir. $bd to every bash call" <<<"$gd")" "1"
git -C "$CW" remote add blocked "$TMP/origin.git"; : > "$CW/.git/refs/remotes/blocked"   # a file where a remote's refs folder must be made
cg=0; cgo=$($ONETREE codex-grants "$bd" 2>"$TMP/cg-err") || cg=$?; git -C "$CW" remote remove blocked; rm -f "$CW/.git/refs/remotes/blocked"
eq "codex-grants: a folder it must list that cannot be made is a failure that names it, with the rest still listed" \
  "$cg $(grep -c "cannot prepare $CW/.git/refs/remotes/blocked" "$TMP/cg-err") $(grep -c "^$CW/.git/objects$" <<<"$cgo")" "1 1 1"
# what the dsh plugin sends: the session's working directory as cwd. s-dsh-web made no worktree: no record says $bd is its own
dsh_hint() { (cd "$CW" && jq -nc --arg cwd "$1" '{session_id: "s-dsh-web", cwd: $cwd, agent: "dsh"}' | ONETREE_HOST=claude-cli $ONETREE session); }   # the payload says dsh, whatever the process looks like
gm=$({ jq -nc --arg cwd "$bd" --arg wd "$CW" '{tool_name: "Bash", cwd: $cwd, session_id: "s-dsh-web", agent: "dsh", tool_input: {command: "git stash", workdir: $wd}}' | ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null; } 2>&1 || true)
eq "dsh: the session hint and a refusal go by the working directory the plugin sends, not by who made a worktree: in the main checkout (make one, then pass workdir), and inside a worktree of it (this session works there, named with its branch; a call sent back to the main checkout is told to leave workdir out)" \
  "$(dsh_hint "$CW" | grep -c 'call the `onetree_new` tool with slug <slug>: .*, then pass `workdir` <path> to every bash call') $(dsh_hint "$bd" | grep -c "this session works in a worktree of it, $bd, on the branch feature/bind-dsh:.*There, leave .workdir. out of bash calls.*this session works in $bd,") $(grep -c "already has a worktree, $bd: do it there. To work there, leave .workdir. out of bash calls.*this session works in $bd," <<<"$gm")" "1 1 1"
gt=$({ jq -nc --arg cwd "$CW" '{tool_name: "Bash", cwd: $cwd, session_id: "s-dsh-none", agent: "dsh", tool_input: {command: "git stash"}}' | ONETREE_NO_EVENTS=1 $ONETREE guard >/dev/null; } 2>&1 || true)
eq "dsh: a refusal for a session with no worktree says to call the onetree_new tool (dsh's sandbox cannot run onetree new), then pass workdir" \
  "$(grep -c 'Work in a worktree instead: call the `onetree_new` tool with slug <slug>: .*, then pass `workdir` <path> to every bash call' <<<"$gt")" "1"
kill $HC $HX $HY $HP $HD 2>/dev/null; wait $HC $HX $HY $HP $HD 2>/dev/null || true
eq "session hint and rules: each host is told its own way in" \
  "$(cd "$CW" && ONETREE_HOST=claude-app $ONETREE session </dev/null | grep -c 'call `change_directory` with <path>') $(cd "$CW" && ONETREE_HOST=codex-cli $ONETREE session </dev/null | grep -c 'type `/cd <path>`') $($ONETREE rules | grep -cE '`change_directory` with the path|`/cd <worktree>`') $($ONETREE snippet "$CW" | grep -c 'Claude desktop app: call `change_directory`')" "1 1 2 1"
ln -s "$b1" "$TMP/b1-link"
guard_table "guard: from the mirror, apply_patch with absolute worktree paths and commands with a workdir in the worktree pass; mirror paths, a patch naming no file, and a workdir in the mirror are refused" "$CW" \
  allow "Patch:*** Begin Patch\n*** Update File: $b1/README.md\n@@\n-hi\n+ho\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** Update File: README.md\n@@\n-hi\n+ho\n*** End Patch\n" \
  block "Patch:*** Begin Patch\n*** End Patch\n" \
  allow "Wd:$b1:npm test"      allow "Wd:~/${b1#"$HOME"/}:npm test"      allow "Wd:$TMP/b1-link:npm test" \
  block "Wd:.:npm test"        block "Wd:../cw-main:npm test"
guard_table "guard: a workdir in the mirror is refused from a worktree too" "$b1" \
  allow "npm test"             block "Wd:$CW:npm test"
added=$(cd "$CW" && git worktree add -q -b claude/app-x .claude/worktrees/app-x origin/main 2>&1 && echo added || true)
{ mkdir -p "$CW/.claude/worktrees/forged" && echo "gitdir: $CW/.git" > "$CW/.claude/worktrees/forged/.git"; } 2>/dev/null || true
git clone -q origin.git cw-locked 2>/dev/null; $ONETREE init --guard --lock-ignored --root "$TMP/cw-worktrees" "$TMP/cw-locked" >/dev/null 2>&1
added2=$(cd "$TMP/cw-locked" && git worktree add -q --detach .claude/worktrees/app-y origin/main 2>&1 && echo added || true)
json_is "app worktrees: in a guarded mirror, lockIgnored too, the Claude app can still add its own under .claude/worktrees; git status stays clean and doctor finds nothing writable" \
  "$(jq -nc --arg a "$added" --arg b "$added2" --arg s "$(git -C "$CW" status --porcelain)$(git -C "$TMP/cw-locked" status --porcelain)" --argjson d "$(doctor_json)" '{a:$a, b:$b, s:$s, d:$d}')" \
  '.a == "added" and .b == "added" and .s == "" and ([.d.checks[] | select(.name | test("cw-(main|locked) has no user-writable"))] | length == 2 and all(.ok))'
guard_table "guard: a worktree git lists inside the mirror is not the mirror; a forged .git file pointing at the mirror is" "$CW" \
  allow "Write:$CW/.claude/worktrees/app-x/f.txt"   allow "cd .claude/worktrees/app-x && git switch -c app-y" \
  block "cd .claude/worktrees/forged && git switch -c evil"   block "Write:$CW/README.md"
git clone -q origin.git hc-unreg 2>/dev/null; UN=$TMP/hc-unreg
hu=$(jq -nc --arg cwd "$UN" '{name: "x/y", cwd: $cwd}' | $ONETREE hook-create 2>"$TMP/hc-err2")
eq "hook-create: an unregistered repo gets Claude's plain worktree on claude/<name>, stays unregistered, and the agent is told to ask about onboarding" \
  "$hu $(git -C "$hu" branch --show-current) $($ONETREE repos | grep -c hc-unreg) $(grep -c 'not managed by onetree.*Ask the user once whether to onboard' "$TMP/hc-err2")" "$UN/.claude/worktrees/x-y claude/x-y 0 1"
git -C "$UN" worktree add -q --detach "$UN/.claude/worktrees/det" origin/main
jq -nc --arg p "$UN/.claude/worktrees/det" '{worktree_path: $p}' | $ONETREE hook-remove >/dev/null 2>&1 || true
eq "hook-remove: Claude asked, so a clean detached worktree at a remote ref goes at once, as onetree rm takes it" "$([[ -d "$UN/.claude/worktrees/det" ]] && echo kept || echo gone)" "gone"

# ---- pi and dsh: their sessions cannot change folder, so the pi extension carries a session's commands into the worktree it made, and
# the dsh plugin guards each call and gives a session announced in a main checkout its worktree and working directory. Both run in fake hosts under node (tests/agents.mjs), calling onetree as installed
if [[ -n "$NODE" ]] && "$NODE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  mkdir -p "$HOME/.local/bin"; cp "$ONETREE" "$HOME/.local/bin/onetree"
  $ONETREE render pi > "$TMP/ext.ts"; $ONETREE render dsh > "$TMP/plugin.mjs"
  git clone -q origin.git pi-other 2>/dev/null
  ag=$("$NODE" --experimental-strip-types --no-warnings "$(dirname "$ONETREE")/../tests/agents.mjs" "$TMP/ext.ts" "$TMP/plugin.mjs" "$CW" "$TMP/pi-other" 2>"$TMP/agents.err" || true)
  [[ -n "$ag" ]] || ag=$(jq -nc --arg e "$(head -c 600 "$TMP/agents.err")" '{harness: $e}')
  json_is "pi: a session that ran onetree new follows its worktree (commands run there, relative paths resolve there, the session keeps it); absolute mirror paths are still refused" "$ag" \
    '.pi.before.blocked and .pi.entries == [{type: "custom", customType: "onetree-worktree", data: {path: .pi.worktree}}]
     and .pi.bash.input.command == ("cd '"'"'" + .pi.worktree + "'"'"' && echo hi > notes.md") and (.pi.bash.blocked | not)
     and .pi.write.input.path == (.pi.worktree + "/src/a.ts") and (.pi.write.blocked | not) and .pi.absolute.blocked and .pi.read.input.path == (.pi.worktree + "/README.md")'
  json_is "pi: /resume restores the session's worktree; without onetree every call is refused" "$ag" \
    '.piResumed.input.command == ("cd '"'"'" + .pi.worktree + "'"'"' && ls") and .piMissing.blocked and (.piMissing.reason | test("ENOENT|unavailable"))'
  json_is "pi: a worktree of a trusted main is trusted; the main itself, a review checkout and an untrusted main's worktree are left to pi" "$ag" \
    '.trust == ["yes", "undecided", "undecided", "undecided"]'
  json_is "dsh: calls take the guard's shapes (a bash workdir too) and are judged where they run; without onetree a call is denied" "$ag" \
    '.dsh.shapes == [{tool_name: "Bash", tool_input: {command: "ls", workdir: "w"}}, {tool_name: "Write", tool_input: {file_path: "f"}}, {tool_name: "Edit", tool_input: {file_path: "f"}}, {tool_name: "Write", tool_input: {file_path: "f"}}, null, null]
     and .dsh.verdicts == ["deny", "allow", "deny", "allow", "allow"] and .dshMissing == "deny"'
  json_is "dsh: a session whose folder is a worktree has that worktree and its git folders opened in its sandbox, once (a tool call, then the announcement), and nothing else happens to it: no worktree made, no move, no message" "$ag" \
    '(.dshGrants | map(.[0]) | unique) == ["dsh-wt"] and (.dshGrants | map(.[1] | if test("/\\.git/") then sub("^.*/\\.git/"; "") else sub("^.*/cw-main/"; "ROOT:") end) | sort) == (["ROOT:pi-follow", "objects", "worktrees/pi-follow", "refs/heads/feature", "logs/refs/heads/feature", "refs/remotes/origin", "logs/refs/remotes/origin"] | sort)
     and .dshInTree == {made: 0, moves: [], injected: []}'
  json_is "dsh: a session announced in a guarded main checkout gets a worktree with no step of its own: one made by the plain auto (named by the time), opened in its sandbox with its git folders, its working directory moved there, and one message of the plugin's own naming the worktree, its branch and the read-only main checkout" "$ag" \
    '.dshAuto | .made == 1 and (.tree | test("/cw-main/dsh-[0-9]{6}-[0-9]{6}(-[0-9]+)?$")) and .moves == 1 and .granted and .gitDirs == 6 and (.branch | test("^feature/dsh-"))
     and (.injected | length == 1 and .[0].role == "user" and .[0].plugin == "onetree") and (.branch as $b | .tree as $t | .injected[0].text | contains("this session works in a worktree of it, " + $t + ", on the branch " + $b) and test("guarded read-only mirror") and test("rename it before the first push"))'
  json_is "dsh: a new session is shown at once: the worktree is made after its announcement returns, and its first tool call waits for it and runs there" "$ag" \
    '.dshQuick == {movedAtCreate: 0, plain: "allow", moves: 1}'
  json_is "dsh: the guard is sent the session's working directory, so after the move a plain command passes and the same command with workdir in the main checkout is refused" "$ag" \
    '.dshAuto.plain == "allow" and .dshAuto.inMain == "deny"'
  json_is "dsh: a resumed session (announced again as a new session object, its working directory already in the worktree) gets no new worktree and no move, and is granted again" "$ag" \
    '.dshResume == {made: 1, moves: 1, regranted: true, plain: "allow"}'
  json_is "dsh: a fork (the same working directory under another session id, no subagent) shares the worktree: none made, not moved, its own grants" "$ag" \
    '.dshFork == {made: 1, moves: 1, granted: true, gitDirs: 6}'
  json_is "dsh: a subagent dsh left in the folder of its header is put in its parent's working directory and granted there, with no worktree of its own; one whose parent is not known stays where it is, also without one" "$ag" \
    '.dshAuto.tree as $t | .dshChild == {made: 1, moved: [["dsh-child", $t]], granted: true, gitDirs: 6, orphan: 0}'
  json_is "dsh: when the working directory moves to another worktree during a session, that worktree is opened and recorded for gc on the next tool call" "$ag" \
    '.dshElsewhere == {before: false, after: true, recorded: true}'
  json_is "dsh: gc's record of a session holds its worktree and dsh's sessions folder; archiving marks it and unarchiving clears the mark, keeping the folder" "$ag" \
    '.dshRecord == {cwd: true, sessions: true, marks: [false, true, false], keptCwd: true}'
  json_is "dsh: a resumed session whose worktree cannot be opened again is told so and why, holds no partial grant, and is not refused by the plugin (the sandbox is the enforcement); the first call after the grants can be made opens everything" "$ag" \
    '.dshResumeClosed | .tree as $t | (.injected | length == 1) and (.injected[0] | contains("sandbox could not be opened for the worktree this session works in, " + $t + " (`onetree codex-grants` failed)") and contains("tries again before each tool call"))
     and .bash == "allow" and .newGrants == 0 and .after == "allow" and .granted == 7'
  json_is "dsh: when auto fails the session stays where it is, with no grant and no move, is told what failed and what to do by hand, and is still guarded; announced again once auto works, it gets its worktree, grants and move" "$ag" \
    '.dshFails | .made == 0 and .moves == [] and .grants == [] and .plain == "deny" and (.injected | length == 1) and (.injected[0].text | test("could not make a worktree for this session \\(error: bootstrap failed; rolled back new worktree\\), so it stays in .*cw-main, the read-only main checkout") and test("call the `onetree_new` tool with slug <slug>: .*, then pass `workdir`"))
     and .retry == {moves: 1, granted: 1, gitDirs: 6}'
  json_is "dsh: a session is moved only into a worktree its sandbox is open to: while codex-grants fails or lists nothing, or the sandbox refuses one directory, it is not moved, holds no partial grant and is told once where the worktree was made, why it was not moved and that it is tried again; the next tool call tries again, and then it is granted everything once and moved into that same worktree" "$ag" \
    '.dshClosed | [.fails, .empty, .refused] | all(.before.moves == 0 and .before.grants == 0 and .before.plain == "deny" and .before.read == "allow" and (.before.injected | length == 1)
       and (.before.injected[0] | test("^onetree: a worktree for this session was made at .*/cw-main/dsh-[0-9]{6}-[0-9]{6}(-[0-9]+)?, but the session was not moved into it \\(dsh.s sandbox could not be opened for it: (`onetree codex-grants` failed|`onetree codex-grants` listed no git folders for it|the sandbox refuses .*/objects)\\), so it stays in .*/cw-main, the read-only main checkout\\. onetree tries again before each tool call\\.$"))
       and .after == "allow" and .made == 1 and .moves == 1 and .granted == 1 and .gitDirs == 6 and .all == 7)'
  json_is "dsh: the onetree_new tool makes another worktree outside the sandbox: opened in the session's sandbox, recorded for gc with the session's own, bound to the session, the same one for the same slug, and the session stays where it works; a bad slug is refused" "$ag" \
    '.dshTool == {made: 1, same: true, moved: 0, cwd: true, granted: true, opened: true, bound: true, next: true, bad: "slug: letters, digits, . _ - only, starting with a letter or digit"}'
  json_is "dsh: a worktree a call names (bash workdir, a file tool's path) is opened when it is of the session's repository, never one of another repository" "$ag" \
    '.dshNamed == {before: {own: false, foreign: false}, after: {own: true, foreign: false}}'
  json_is "dsh: when onetree new fails, the tool says what failed and opens nothing" "$ag" \
    '.dshToolFails == {error: "onetree could not make the worktree: error: cannot reach origin", grants: 0}'
  json_is "dsh: a profile with no sandbox policy has nothing to open, and its session is moved into the worktree all the same" "$ag" \
    '.dshNoSandbox == {moves: 1, grants: 0, plain: "allow"}'
  json_is "dsh: a profile without the sandbox policy and the working-directory service gets the guard and the hint only: no worktree is made, the session is told how to work in one, a plain command is judged in the main checkout and one with workdir in a worktree passes" "$ag" \
    '.dshBare | .made == 0 and (.injected | length == 1) and (.injected[0].text | test("call the `onetree_new` tool with slug <slug>: .*, then pass `workdir` <path> to every bash call")) and .plain == "deny" and .inTree == "allow"'
elif [[ -n "${CI:-}" ]]; then bad "pi and dsh: node 22 or newer is required in CI"
else printf 'skip  pi and dsh: node 22 or newer is unavailable\n'; fi
gw=$($ONETREE new grants-a "$CW" 2>/dev/null); git -C "$CW" worktree add -q -b plain "$TMP/plain-tree" origin/main
grants() { $ONETREE codex-grants "$1" | grep -v '^--add-dir$' | sed "s#^$CW/.git#G#" | tr '\n' ' '; }
eq "codex-grants: objects, the worktree's git dir, its branch's namespace and the remotes' tracking refs; never .git, refs, refs/heads, config or hooks; a main checkout gets none" \
  "$(grants "$gw")| $(grants "$TMP/plain-tree")| $(grants "$CW")" \
  "G/objects G/worktrees/grants-a G/refs/heads/feature G/logs/refs/heads/feature G/refs/remotes/origin G/logs/refs/remotes/origin | G/objects G/worktrees/plain-tree G/refs/remotes/origin G/logs/refs/remotes/origin | "
mkdir -p "$HOME/.pi/agent" "$HOME/.dsh" "$TMP/vbin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/vbin/pi"; printf '#!/bin/sh\nexec sleep 30\n' > "$TMP/vbin/dsh"; chmod +x "$TMP/vbin/pi" "$TMP/vbin/dsh"
t0=$SECONDS; starts=$(PATH="$TMP/vbin:$PATH" doctor_json | jq -c '[.checks[] | select(.name | test("^(pi|dsh) on PATH starts")) | .ok]')
eq "doctor: an installed agent whose client does not start, or hangs, fails within its time limit, since its wrapper cannot start it either" \
  "$starts $(( SECONDS - t0 < 25 ))" "[true,false] 1"
rm -rf "$HOME/.pi" "$HOME/.dsh"

# ---- launch: where an agent starts, from any shell or program. Fake clients print their argv and cwd
mkdir -p "$TMP/lbin" "$TMP/plain-dir"
for a in claude codex pi; do cat > "$TMP/lbin/$a" <<'SH'
#!/bin/sh
jq -nc --arg cwd "$(pwd -P)" '{argv: $ARGS.positional, cwd: $cwd}' --args -- "$@"
SH
chmod +x "$TMP/lbin/$a"; done
launched() { local d=$1; shift; (cd "$d" && PATH="$TMP/lbin:$PATH" $ONETREE launch "$@" 2>/dev/null) || echo '{}'; }
json_is "launch: in a guarded mirror an agent starts in a fresh worktree onetree makes (codex with its commit grants; claude never through its own --worktree, and when Claude trusts the checkout its worktree root is recorded as trusted once, with no record when it does not); print and exec modes and other folders run as typed; --task names the worktree, print mode too" \
  "$(jq -nc --argjson a "$(launched "$CW" codex --model x)" --argjson b "$(launched "$CW" codex exec hi)" --argjson c "$(launched "$TMP/plain-dir" pi hi)" \
      --argjson d "$(launched "$CW" --task job-1 pi -p go)" --argjson f "$(launched "$CW" claude hi)" --argjson ft "$(jq -c '.projects // {}' "$HOME/.claude.json" 2>/dev/null || echo null)" \
      --argjson e "$(jq -n --arg p "$CW" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"; launched "$CW" claude hi; launched "$CW" claude again >/dev/null)" \
      --argjson et "$(jq -c '.projects' "$HOME/.claude.json"; rm -f "$HOME/.claude.json")" \
      '{a:$a, b:$b, c:$c, d:$d, e:$e, et:$et, f:$f, ft:$ft}')" \
  '(.a.cwd | startswith("'"$TMP"'/cw-worktrees/cw-main/codex-")) and .a.argv[0] == "--add-dir" and .a.argv[12:] == ["--model", "x"]
   and .b == {argv: ["exec", "hi"], cwd: "'"$CW"'"} and .c == {argv: ["hi"], cwd: "'"$TMP"'/plain-dir"}
   and .d == {argv: ["-p", "go"], cwd: "'"$TMP"'/cw-worktrees/cw-main/job-1"}
   and (.e.cwd | startswith("'"$TMP"'/cw-worktrees/cw-main/claude-")) and .e.argv == ["hi"]
   and .et["'"$CW"'"].hasTrustDialogAccepted and .et["'"$TMP"'/cw-worktrees/cw-main"].hasTrustDialogAccepted
   and (.et | del(.["'"$CW"'"], .["'"$TMP"'/cw-worktrees/cw-main"]) | keys | all(startswith("'"$TMP"'/cw-worktrees/cw-main/claude-")))
   and (.f.cwd | startswith("'"$TMP"'/cw-worktrees/cw-main/claude-")) and .f.argv == ["hi"] and .ft == null'
jq -n --arg p "$CW" '{projects: {($p): {hasTrustDialogAccepted: true}}, numStartups: 7}' > "$HOME/.claude.json"
tw=$($ONETREE new trust-wt "$CW" 2>/dev/null); tn=$($ONETREE new trust-no "$MAIN" 2>/dev/null)
eq "new: a worktree of a checkout Claude trusts is recorded as trusted by its own path (the desktop app moves a session there without asking), the rest of Claude's file is kept, and a checkout Claude does not trust gets no record" \
  "$(jq -c --arg w "$tw" --arg n "$tn" '[.projects[$w].hasTrustDialogAccepted, (.projects | has($n)), .numStartups]' "$HOME/.claude.json")" '[true,false,7]'
rm -f "$HOME/.claude.json"

# ---- gc leaves other tools' worktrees to them; an unmarked worktree under onetree's root is still onetree's
git -C "$CW" worktree add -q --detach "$TMP/codex-home/worktrees/ab12/cw-main" origin/main
echo '{}' > "$(git -C "$TMP/codex-home/worktrees/ab12/cw-main" rev-parse --path-format=absolute --git-dir)/codex-thread.json"
git -C "$CW" worktree add -q --detach "$TMP/elsewhere" origin/main
git -C "$CW" worktree add -q -b feature/legacy "$TMP/cw-worktrees/cw-main/legacy" origin/main
git -C "$CW" worktree add -q --detach "$TMP/cw-worktrees/cw-main/cx-in-root" origin/main   # a root that overlaps the Codex app's
echo '{}' > "$(git -C "$TMP/cw-worktrees/cw-main/cx-in-root" rev-parse --path-format=absolute --git-dir)/codex-thread.json"
evp=$($ONETREE new ev-old "$CW" 2>/dev/null); $ONETREE rm --force ev-old "$CW" >/dev/null 2>&1   # an event still names this path
git -C "$CW" worktree add -q --detach "$evp" origin/main; echo '{}' > "$(git -C "$evp" rev-parse --path-format=absolute --git-dir)/codex-thread.json"
json_is "gc: worktrees the Codex app, the Claude app or another tool made are kept as foreign, naming the maker, even under onetree's root or at a path an old event names; an unmarked one under the root otherwise is onetree's" \
  "$($ONETREE gc --dry-run --json "$CW" | jq -c 'map(select(.path | test("/(ab12/cw-main|app-x|elsewhere|legacy|cx-in-root|ev-old)$")) | {key: (.path | split("/") | last), value: [.gc.code, .gc.reason]}) | from_entries')" \
  '.["cw-main"] == ["foreign", "made by the Codex app, which removes it itself"] and .["app-x"] == ["foreign", "made by the Claude app, which removes it itself"]
   and .elsewhere == ["foreign", "made by a tool other than onetree, which removes it itself"] and .legacy[0] != "foreign"
   and .["cx-in-root"][1] == "made by the Codex app, which removes it itself" and .["ev-old"][1] == "made by the Codex app, which removes it itself"'
st=0; $ONETREE rm elsewhere "$CW" >/dev/null 2>&1 || st=$?
eq "gc: the legacy worktree now carries onetree's marker, and onetree rm still removes a foreign one when asked" \
  "$([[ -f "$(git -C "$TMP/cw-worktrees/cw-main/legacy" rev-parse --path-format=absolute --git-dir)/onetree" ]] && echo marked) $st $([[ -d "$TMP/elsewhere" ]] && echo kept || echo gone)" "marked 0 gone"

# ---- resume: the sessions that made a repo's worktrees, and the way back to one after gc removed it
rp=$(CLAUDE_CODE_SESSION_ID=s-res ONETREE_HOST=claude-cli $ONETREE new res-a "$CW" 2>/dev/null)
$ONETREE rm res-a "$CW" --force >/dev/null 2>&1
mkdir -p "$HOME/.claude/projects/p"; printf '{"cwd":"%s"}\n' "$rp" > "$HOME/.claude/projects/p/s-res.jsonl"
rl=$(cd "$CW" && $ONETREE resume); rr=$(cd "$CW" && $ONETREE resume s-res)
eq "resume: lists the sessions that made this repo's worktrees; recreates a removed one and says how to resume the session there" \
  "$(grep -cE "claude-cli +s-res +$rp +removed" <<<"$rl") $([[ -d "$rp" ]] && echo back) $(grep -cF "resume: cd $rp && claude --resume s-res" <<<"$rr")" "1 back 1"
sp2=$(CLAUDE_CODE_SESSION_ID=s-sp ONETREE_HOST=claude-cli $ONETREE new sp-res "$SP" 2>/dev/null)
spcmd=$(cd "$SP" && $ONETREE resume s-sp | sed -n 's/^resume: \(cd .* &&\) claude --resume s-sp$/\1/p')
eq "resume: a path with a space is quoted, so the printed command lands in the worktree" "$(eval "$spcmd pwd -P" 2>/dev/null)" "$(cd "$sp2" && pwd -P)"

# ---- dependencies: clone main's node_modules only when it is what the worktree's lockfile asks for
# a fake npm: `ci` installs what package-lock.json lists, minus optional packages (like a platform package for another OS), and
# records it in node_modules/.package-lock.json the way npm does; FAKE_NPM_FAIL empties node_modules first and fails, as npm ci does
export NPM_LOG=$TMP/npm.log
cat > "$TMP/bin/npm" <<'NPM'
#!/bin/sh
echo "npm $* @ $PWD" >> "$NPM_LOG"
case "$1" in
  ci)
    mkdir -p node_modules && find node_modules -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    [ -n "$FAKE_NPM_FAIL" ] && { echo "npm error code E401" >&2; exit 1; }
    jq '{name, lockfileVersion, packages: (.packages | del(.[""]) | with_entries(select(.value.optional != true)))}' package-lock.json > node_modules/.package-lock.json
    for k in $(jq -r '.packages | del(.[""]) | to_entries[] | select(.value.optional != true) | .key' package-lock.json); do
      mkdir -p "$k" && jq --arg k "$k" '.packages[$k] | {version}' package-lock.json > "$k/package.json"
    done ;;
esac
exit 0
NPM
chmod +x "$TMP/bin/npm"
lockfile() {  # "name@version[#integrity][!resolved][?]"… -> a package-lock.json; a trailing ? marks an optional package
  local a n v o i r args=()
  for a in "$@"; do
    o=false; [[ "$a" == *'?' ]] && { o=true; a=${a%'?'}; }
    r=; [[ "$a" == *'!'* ]] && { r=${a#*!}; a=${a%%!*}; }
    i=; [[ "$a" == *'#'* ]] && { i=${a#*#}; a=${a%%#*}; }
    n=${a%@*}; v=${a#*@}; args+=("node_modules/$n" "$v" "$o" "$i" "$r")
  done
  printf '%s\n' "${args[@]}" | jq -R . | jq -s '{name:"app", lockfileVersion:3, packages:({"":{name:"app"}} + ([range(0; length; 5) as $k | {key:.[$k], value:({version:.[$k+1]}
    + (if .[$k+2] == "true" then {optional:true} else {} end) + (if .[$k+3] != "" then {integrity:.[$k+3]} else {} end) + (if .[$k+4] != "" then {resolved:.[$k+4]} else {} end))}] | from_entries))}'
}
push_lock() { local c; c=$(mktemp -d); git clone -q "$TMP/n.git" "$c/x" 2>/dev/null; ( cd "$c/x" && lockfile "$@" > package-lock.json && git commit -qam lock && git push -q origin main ); rm -rf "$c"; }
ci_calls() { grep -c '^npm ci' "$NPM_LOG" 2>/dev/null || true; }
deps_check() { doctor_json | jq -c '[.checks[] | select(.name | test("guarded main .*nmain dependencies match its lockfile"))] | map([.ok, (.name | sub(".*\\(npm, "; "") | sub("\\)$"; ""))])'; }
git init -q --bare -b main n.git
git clone -q n.git nmain 2>/dev/null
NM=$TMP/nmain
( cd nmain && printf '{"name":"app"}\n' > package.json && lockfile a@1.0.0 'b@2.0.0#sha512-b1' 'g@1.0.0!git+ssh://git@x/g.git#c1' 'opt@1.0.0?' > package-lock.json \
  && printf 'node_modules\n' > .gitignore && git add . && git commit -qm init && git push -q origin main && npm ci --ignore-scripts )
$ONETREE init --no-guard --root "$TMP/worktrees" "$NM" >/dev/null 2>&1
c0=$(ci_calls); n1=$($ONETREE new deps-fresh "$NM" 2>"$TMP/new.err")
eq "deps: a main whose node_modules matches the lockfile is cloned with no install; an optional package may be missing" \
  "$(( $(ci_calls) - c0 )) $(jq -r .version "$n1/node_modules/a/package.json") $($ONETREE info "$NM" | grep -cE '^deps +npm, current: 3 installed, 1 optional not installed$')" "0 1.0.0 1"
rm -rf "$NM/node_modules/b"   # npm still records it
c0=$(ci_calls); $ONETREE new deps-gone "$NM" >/dev/null 2>"$TMP/new.err"
eq "deps: a package npm recorded whose directory is gone counts as missing, so no clone" "$(( $(ci_calls) - c0 )) $(grep -cF '(stale: 1 missing, 0 at another version or source, of 4 in package-lock.json)' "$TMP/new.err")" "1 1"
( cd "$NM" && npm ci --ignore-scripts )
push_lock a@1.0.0 'b@2.0.0#sha512-b2' 'g@1.0.0!git+ssh://git@x/g.git#c2' 'opt@1.0.0?'   # same versions: a republished tarball, a git dependency's new commit
git -C "$NM" pull -q --ff-only origin main
c0=$(ci_calls); $ONETREE new deps-source "$NM" >/dev/null 2>"$TMP/new.err"
eq "deps: the same version from another source (integrity; resolved for a git dependency) is stale, so no clone" "$(( $(ci_calls) - c0 )) $(grep -cF '(stale: 0 missing, 2 at another version or source, of 4 in package-lock.json)' "$TMP/new.err")" "1 1"
( cd "$NM" && npm ci --ignore-scripts )
push_lock a@1.0.0 'b@2.0.0#sha512-b2' 'g@1.0.0!git+ssh://git@x/g.git#c2' c@3.0.0 'opt@1.0.0?'   # the 13 Oct failure: a fast-forward added a package main never installed
git -C "$NM" pull -q --ff-only origin main
c0=$(ci_calls); n2=$($ONETREE new deps-missing "$NM" 2>"$TMP/new.err")
eq "deps: a required package missing from main installs fresh, with one line naming the drift; info says stale; doctor leaves an unguarded main to you" \
  "$(( $(ci_calls) - c0 )) $([[ -d "$n2/node_modules/c" ]] && echo has-c) $(grep -cE "^onetree: not cloning $NM/node_modules \(stale: 1 missing, 0 at another version or source, of 5 in package-lock\.json\); installing fresh: npm ci --ignore-scripts$" "$TMP/new.err") $($ONETREE info --json "$NM" | jq -c .deps) $(deps_check)" \
  '1 has-c 1 {"manager":"npm","state":"stale","detail":"1 missing, 0 at another version or source, of 5 in package-lock.json"} []'
( cd "$NM" && npm ci --ignore-scripts )
push_lock a@1.1.0 'b@2.0.0#sha512-b2' 'g@1.0.0!git+ssh://git@x/g.git#c2' c@3.0.0 'opt@1.0.0?'
git -C "$NM" pull -q --ff-only origin main
c0=$(ci_calls); n3=$($ONETREE new deps-version "$NM" 2>"$TMP/new.err")
eq "deps: a version mismatch is stale too, and installs fresh" "$(( $(ci_calls) - c0 )) $(jq -r .version "$n3/node_modules/a/package.json") $(grep -cF '(stale: 0 missing, 1 at another version or source' "$TMP/new.err")" "1 1.1.0 1"
( cd "$NM" && npm ci --ignore-scripts && rm node_modules/.package-lock.json )
c0=$(ci_calls); $ONETREE new deps-unknown "$NM" >/dev/null 2>"$TMP/new.err"
eq "deps: no record of what npm installed is unknown, and unknown never clones" "$(( $(ci_calls) - c0 )) $(grep -cF '(unknown: no node_modules/.package-lock.json, so npm did not record what it installed); installing fresh' "$TMP/new.err")" "1 1"
st=0; FAKE_NPM_FAIL=1 $ONETREE new deps-fail "$NM" >/dev/null 2>"$TMP/new.err" || st=$?
eq "deps: a failing install rolls the new worktree and its branch back, and says why" \
  "$st $([[ -e "$TMP/worktrees/nmain/deps-fail" ]] && echo left || echo gone) $(git -C "$NM" show-ref -q --verify refs/heads/feature/deps-fail && echo branch || echo nobranch) $(grep -c 'npm error code E401' "$TMP/new.err")" "1 gone nobranch 1"
for s in deps-fresh deps-gone deps-source deps-missing deps-version deps-unknown; do $ONETREE rm --force "$s" "$NM" >/dev/null 2>&1 || true; done
# (a): park keeps a guarded main's dependencies current: a fresh install in a scratch directory, swapped in only once it is right,
# and only while nothing works in main (a git hook there would see node_modules mid-swap); an agent session merely sitting there is no work
( cd "$NM" && npm ci --ignore-scripts )
$ONETREE init --guard "$NM" >/dev/null 2>&1
push_lock a@1.1.0 'b@2.0.0#sha512-b2' 'g@1.0.0!git+ssh://git@x/g.git#c2' c@3.0.0 d@4.0.0 'opt@1.0.0?'
fake_agent claude   # made in part 1 too; this part has its own $TMP
( cd "$NM" && exec sleep 30 ) & BZ=$!
( cd "$NM" && exec "$TMP/bin/claude" 30 ) & IDLE=$!
sleep 0.5
c0=$(ci_calls); out=$($ONETREE park "$NM" 2>&1) || true
eq "deps: park fast-forwards a guarded main but defers the refresh while something works there, installing nothing" \
  "$(grep -cE '^fast-forwarded nmain main to [0-9a-f]{7}$' <<<"$out") $(grep -cE '^deps nmain: deferred: 1 process\(es\) working in main \(sleep\); retried at the next park$' <<<"$out") $(( $(ci_calls) - c0 )) $([[ -d "$NM/node_modules/d" ]] && echo has-d || echo no-d)" "1 1 0 no-d"
kill $BZ 2>/dev/null; wait $BZ 2>/dev/null || true
out=$($ONETREE park "$NM" 2>&1) || true   # the idle agent session is still there
has "deps: with only an agent session sitting in main, park reinstalls the stale node_modules and says so" "$out" '^deps nmain: reinstalled node_modules from package-lock\.json \(was: 1 missing, 0 at another version or source, of 6 in package-lock\.json\)$'
kill $IDLE 2>/dev/null; wait $IDLE 2>/dev/null || true
eq "deps: the new node_modules has the new package, the root is locked again, no scratch is left, doctor says current, events record it" \
  "$(jq -r .version "$NM/node_modules/d/package.json") $([[ -w "$NM" ]] && echo w || echo ro) $([[ -e "$NM/.git/onetree-deps" ]] && echo scratch-left || echo clean) $(deps_check) $($ONETREE events --json --kind deps | jq -c 'map(.action)')" \
  '4.0.0 ro clean [[true,"current: 5 installed, 1 optional not installed"]] ["deferred","refreshed"]'
push_lock a@1.1.0 'b@2.0.0#sha512-b2' 'g@1.0.0!git+ssh://git@x/g.git#c2' c@3.0.0 d@4.0.0 e@5.0.0 'opt@1.0.0?'
out=$(FAKE_NPM_FAIL=1 $ONETREE park "$NM" 2>&1) || true
eq "deps: a failed refresh says so, leaves the old node_modules intact, and doctor reports the drift with the counts" \
  "$(grep -c '^deps nmain: npm ci --ignore-scripts failed: npm error code E401; node_modules left as it was, onetree park retries$' <<<"$out") $(jq -r .version "$NM/node_modules/d/package.json") $([[ -d "$NM/node_modules/e" ]] && echo e || echo no-e) $(deps_check)" \
  '1 4.0.0 no-e [[false,"stale: 1 missing, 0 at another version or source, of 7 in package-lock.json"]]'
# a swap that can neither place the fresh tree nor put the previous one back (say, something recreated node_modules meanwhile):
# both trees are kept, the message says where, doctor fails, and later refreshes leave them alone. An mv on PATH fails those two moves.
mkdir -p "$TMP/mvfail"; printf '%s\n' '#!/bin/sh' 'case "$1" in */onetree-deps/*) exit 1 ;; esac' 'exec /bin/mv "$@"' > "$TMP/mvfail/mv"; chmod +x "$TMP/mvfail/mv"
out=$(PATH=$TMP/mvfail:$PATH $ONETREE park "$NM" 2>&1) || true
eq "deps: a swap that cannot finish keeps the previous node_modules in the scratch directory and names it; doctor fails" \
  "$(grep -cF "deps nmain: could not swap the fresh node_modules in, nor put the previous one back: it is at $NM/.git/onetree-deps/old, the fresh one at $NM/.git/onetree-deps/node_modules; move one to $NM/node_modules, then onetree park" <<<"$out") $(jq -r .version "$NM/.git/onetree-deps/old/d/package.json") $(doctor_json | jq -c '[.checks[] | select(.name | test("nmain has no node_modules stranded"))] | map(.ok)')" \
  '1 4.0.0 [false]'
out=$($ONETREE park "$NM" 2>&1) || true
eq "deps: until you move it back, a refresh leaves the stranded tree alone and says so" "$(grep -cF "deps nmain: an earlier swap could not finish: the previous node_modules is at $NM/.git/onetree-deps/old" <<<"$out") $([[ -d "$NM/.git/onetree-deps/old/d" ]] && echo kept)" "1 kept"
chmod u+w "$NM"; mv "$NM/.git/onetree-deps/old" "$NM/node_modules"; chmod a-w "$NM"; rm -rf "$NM/.git/onetree-deps"   # what the message tells you to do
c0=$(ci_calls); FAKE_NPM_FAIL=1 $ONETREE gc "$NM" >/dev/null 2>&1 || true; d=$(( $(ci_calls) - c0 ))
mkdir -p "$NM/.git/onetree-deps.lock" "$NM/.git/onetree-deps/node_modules"; echo "$$ 0" > "$NM/.git/onetree-deps.lock/holder"; : > "$NM/.git/onetree-deps/node_modules/theirs"   # another refresh, alive, mid-install
c1=$(ci_calls); $ONETREE park "$NM" >/dev/null 2>&1 || true
eq "deps: while another refresh holds the lock, a second one installs nothing and leaves the shared scratch alone" "$(( $(ci_calls) - c1 )) $([[ -e "$NM/.git/onetree-deps/node_modules/theirs" ]] && echo kept)" "0 kept"
rm -rf "$NM/.git/onetree-deps"; echo "999999 0" > "$NM/.git/onetree-deps.lock/holder"   # its holder died
c2=$(ci_calls); out=$($ONETREE park "$NM" 2>&1) || true
eq "deps: a lock whose holder died is reported with the command to clear it, never taken over" "$(( $(ci_calls) - c2 )) $(grep -cF "a dependency refresh died holding $NM/.git/onetree-deps.lock; once no onetree gc or park is running, rm -rf $NM/.git/onetree-deps.lock" <<<"$out") $([[ -d "$NM/.git/onetree-deps.lock" ]] && echo kept)" "0 1 kept"
rm -rf "$NM/.git/onetree-deps.lock"   # what the message tells you to do
out=$($ONETREE park "$NM" 2>&1) || true
eq "deps: gc does not retry a refresh that failed on this lockfile; onetree park does, and it lands" "$d $(grep -c '^deps nmain: reinstalled node_modules' <<<"$out") $(jq -r .version "$NM/node_modules/e/package.json")" "0 1 5.0.0"
$ONETREE init --no-guard "$NM" >/dev/null 2>&1

# ==== part 6
# ---- carry: a dirty main's uncommitted work moves into a new worktree, and only then is main restored and locked
git init -q --bare -b main c.git
git clone -q c.git cmain 2>/dev/null
CM=$TMP/cmain
( cd cmain && echo one > README.md && echo old > old.txt && mkdir -p src && echo s > src/keep.ts && git add . && git commit -qm init && git push -q origin main )
$ONETREE init --no-guard --root "$TMP/worktrees" "$CM" >/dev/null 2>&1
dirty_main() { ( cd "$CM" && echo two >> README.md && rm -f old.txt && echo added > added.txt && git add added.txt && echo notes > notes.md ) 2>/dev/null; }
main_state() { git -C "$CM" diff HEAD --binary; git -C "$CM" status --porcelain; }
dirty_main
before=$(git -C "$CM" diff HEAD --binary)
out=$($ONETREE init --guard --carry carry-a "$CM" 2>&1)
ca=$TMP/worktrees/cmain/carry-a
eq "carry: the tracked changes land in the new worktree uncommitted and identical, its index otherwise intact, and carry says what moved" \
  "$(git -C "$ca" diff HEAD --binary | cmp -s - <(printf '%s\n' "$before") && echo same) $(git -C "$ca" rev-list --count HEAD ^origin/main) $(git -C "$ca" status --porcelain | tr '\n' ' ')$(grep -cE "^onetree: carried 3 tracked path\(s\) from $CM into $ca \(feature/carry-a, cut from [0-9a-f]{7}\); main is back at HEAD$" <<<"$out")" \
  "same 0  M README.md  A added.txt  D old.txt 1"
eq "carry: main ends with no tracked change, guarded and locked; an untracked file stays, and init says how to move it" \
  "$(git -C "$CM" status --porcelain) $($ONETREE info --json "$CM" | jq -r .guard) $([[ -w "$CM/README.md" ]] && echo w || echo ro) $(grep -cE 'leftover  \?\? notes\.md .*onetree carry <slug> --untracked' <<<"$out")" "?? notes.md true ro 1"
cb=$($ONETREE carry carry-b "$CM" --untracked 2>/dev/null)
eq "carry --untracked: an untracked file moves too, main ends clean, and each carry is an event" "$(cat "$cb/notes.md") [$(git -C "$CM" status --porcelain)] $($ONETREE events --json --kind carry | jq -c 'map([.tracked, .untracked])')" "notes [] [[3,0],[0,1]]"
# failures midway: main must end exactly as it was, and the half-made worktree must go
$ONETREE init --no-guard "$CM" >/dev/null 2>&1; dirty_main; chmod 000 "$CM/notes.md"
before=$(main_state)
st=0; out=$($ONETREE carry carry-c "$CM" --untracked 2>&1) || st=$?
chmod 644 "$CM/notes.md"
eq "carry: when a copy fails midway, main is exactly as it was, the half-made worktree and its branch are gone, and carry says so" \
  "$st $([[ "$(main_state)" == "$before" ]] && echo untouched) $([[ -e "$TMP/worktrees/cmain/carry-c" ]] && echo left || echo gone) $(git -C "$CM" show-ref -q --verify refs/heads/feature/carry-c && echo branch || echo nobranch) $(grep -cE "^onetree: carry: copying the untracked files failed .*; removed $TMP/worktrees/cmain/carry-c again, and $CM is as it was$" <<<"$out")" \
  "1 untouched gone nobranch 1"
( cd "$CM" && printf '*.dat filter=up\n' > .gitattributes && echo OLD > x.dat && git add .gitattributes x.dat && git commit -qm dat -- .gitattributes x.dat && git push -q origin main ) 2>/dev/null
git -C "$CM" config filter.up.clean 'tr a-z A-Z'; git -C "$CM" config filter.up.smudge cat   # like LFS: what git diffs is not what is on disk
echo new > "$CM/x.dat"
st=0; out=$($ONETREE carry carry-f "$CM" 2>&1) || st=$?
eq "carry: equal diffs of unequal files (a clean filter, like LFS) stop it, naming the file; main untouched" \
  "$st $(cat "$CM/x.dat") $([[ -e "$TMP/worktrees/cmain/carry-f" ]] && echo left || echo gone) $(grep -c 'x\.dat differs after the copy' <<<"$out")" "1 new gone 1"
git -C "$CM" checkout -q -- x.dat
before=$(main_state)
$ONETREE init --bootstrap false "$CM" >/dev/null 2>&1
st=0; $ONETREE carry carry-d "$CM" >/dev/null 2>&1 || st=$?
eq "carry: a worktree that cannot be made leaves main as it was" "$st $([[ "$(main_state)" == "$before" ]] && echo untouched)" "1 untouched"
git -C "$CM" config --unset onetree.bootstrap
( cd "$CM" && echo staged > README.md && git add README.md && echo working > README.md )
before=$(main_state; git -C "$CM" diff --cached --binary)
st=0; out=$($ONETREE carry carry-g "$CM" 2>&1) || st=$?
eq "carry: a path whose staged version differs from both HEAD and the working copy stops it, naming the path; main and its index untouched" \
  "$st $([[ "$(main_state; git -C "$CM" diff --cached --binary)" == "$before" ]] && echo untouched) $([[ -e "$TMP/worktrees/cmain/carry-g" ]] && echo left || echo gone) $(grep -c '^onetree: carry: README.md in .* has a staged version' <<<"$out")" "1 untouched gone 1"
( cd "$CM" && git reset -q --hard && rm -f notes.md )
has "carry: a clean main has nothing to carry" "$($ONETREE carry carry-e "$CM" 2>&1)" '^onetree: carry: nothing to carry in '

# ---- a committed .onetree bootstrap runs inside the new worktree, after the built-in install: the only hook for a package.json that is not at the root
printf '[onetree]\n\tbootstrap = mkdir -p ui && echo "$ONETREE_MAIN" > ui/bootstrapped && echo added 1 package\n' > "$CM/.onetree"
bp=$($ONETREE new boot-nested "$CM" 2>/dev/null)
eq "bootstrap: the committed .onetree command runs in the worktree with ONETREE_MAIN set, its stdout kept off new's (the path)" "$bp $(cat "$bp/ui/bootstrapped" 2>/dev/null)" "$TMP/worktrees/cmain/boot-nested $CM"
eq "bootstrap: a configured hook emits no missing-dependency note" "$($ONETREE bootstrap "$bp" 2>&1)" "$(printf 'added 1 package\nbootstrapped %s from %s' "$bp" "$CM")"
rm -f "$CM/.onetree"
boot_status=0; boot_out=$($ONETREE bootstrap "$bp" 2>"$TMP/bootstrap.err") || boot_status=$?
eq "bootstrap: with no dependency step it still succeeds and prints one line" "$boot_status $boot_out" "0 bootstrapped $bp from $CM"
has "bootstrap: with no package.json, uv.lock or onetree.bootstrap it says no dependency step ran on stderr" "$(cat "$TMP/bootstrap.err")" '^onetree: no dependency step ran'
$ONETREE rm --force boot-nested "$CM" >/dev/null 2>&1 || true

# ==== part 3
# ---- review by PR number: GitHub serves pull/<n>/head on the base repo, also when the head lives in a contributor's fork
git init -q --bare -b main pb.git
git clone -q pb.git pmain 2>/dev/null
PM=$TMP/pmain
( cd pmain && echo base > app.txt && git add . && git commit -qm base && git push -q origin main )
git clone -q --bare pb.git contrib.git 2>/dev/null   # the contributor's fork, a separate repo
git clone -q contrib.git contrib 2>/dev/null
( cd contrib && git switch -q -c fix && echo fix >> app.txt && git commit -qam "fork fix" && git push -q origin fix )
git -C pb.git fetch -q "$TMP/contrib.git" "refs/heads/fix:refs/pull/7/head"   # what GitHub does when the fork opens PR #7
PR_SHA=$(git -C contrib.git rev-parse fix)
$ONETREE init --no-guard --root "$TMP/worktrees" "$PM" >/dev/null 2>&1
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
echo "$*" >> "$GH_LOG"
if [ "$1 $2" = "pr view" ]; then f="$GH_DATA/view-$3"; [ -f "$f" ] && { cat "$f"; exit 0; }; echo "no pull request" >&2; exit 1; fi
exit 0
GH
chmod +x "$TMP/bin/gh"
echo "OPEN $PR_SHA" > "$GH_DATA/view-7"
rp=$($ONETREE review 7 "$PM")
eq "review <n>: a detached checkout of the fork's PR head, named after the PR and recorded as #<n>; review pr:<n> is the same checkout" \
  "$rp $(git -C "$rp" rev-parse HEAD) $(git -C "$rp" symbolic-ref -q HEAD || echo detached) $(head -1 "$PM/.git/worktrees/review-pr-7/onetree-review") $($ONETREE review pr:7 "$PM")" \
  "$TMP/worktrees/pmain/review-pr-7 $PR_SHA detached #7 $TMP/worktrees/pmain/review-pr-7"
eq "review <n>: ls shows the PR's state and nothing unpushed; gc keeps it while the PR is open" \
  "$($ONETREE ls --json --fresh "$PM" | jq -c '.[] | select(.slug == "review-pr-7") | [.pr.state, .unpushed]') $($ONETREE gc --dry-run --json --fresh "$PM" | jq -c '.[] | select(.slug == "review-pr-7") | [.gc.action, .gc.code]')" \
  '["OPEN",0] ["keep","pr-open"]'
echo "MERGED $PR_SHA" > "$GH_DATA/view-7"
json_is "review <n>: gc removes it once the PR merged" "$($ONETREE gc --dry-run --json --fresh "$PM" | jq -c '.[] | select(.slug == "review-pr-7")')" '.gc.action == "would-remove" and .gc.code == "review" and (.gc.reason | startswith("#7 (review)"))'
echo "OPEN $PR_SHA" > "$GH_DATA/view-7"
git -C "$rp" commit -q --allow-empty -m "reviewer note"; own=$(git -C "$rp" rev-parse HEAD)
st=0; out=$($ONETREE review 7 "$PM" 2>&1) || st=$?
eq "review <n> again: a reviewer's commit that exists nowhere else is named and kept where it is" "$st $(grep -c 'has commits that exist nowhere else .*reviewer note' <<<"$out") $([[ "$(git -C "$rp" rev-parse HEAD)" == "$own" ]] && echo kept)" "1 1 kept"
git -C "$rp" checkout -q --detach "$PR_SHA"
echo gen.json >> "$PM/.git/info/exclude"; echo mine > "$rp/gen.json"   # the checkout's own ignored file; the PR's next push tracks that path
( cd contrib && echo tracked > gen.json && git add -f gen.json && git commit -qm "track gen" && git push -q origin fix )
git -C pb.git fetch -q "$TMP/contrib.git" "+refs/heads/fix:refs/pull/7/head"
st=0; out=$($ONETREE review 7 "$PM" 2>&1) || st=$?
eq "review <n> again: an ignored file of the checkout's own that the new head tracks is kept, and the move refused, naming it" "$st $(grep -c 'would overwrite gen.json' <<<"$out") $(cat "$rp/gen.json")" "1 1 mine"
rm -f "$rp/gen.json"; : > "$PM/.git/info/exclude"
st=0; $ONETREE rm review-pr-7 "$PM" >/dev/null 2>&1 || st=$?
eq "onetree rm: a clean review checkout goes without --force, though its PR is open and it is young, and its PR ref with it" "$st $([[ -d "$rp" ]] && echo left || echo gone) $(git -C "$PM" show-ref -q --verify refs/onetree/pr/7 && echo ref-left || echo ref-gone)" "0 gone ref-gone"
if out=$($ONETREE review 99 "$PM" 2>&1); then bad "review <n>: a number that is no PR fails"; else has "review <n>: a number that is no PR fails" "$out" 'could not fetch pull/99/head from origin'; fi
# onetree rm of other detached checkouts: on a remote ref it goes; a commit that lives only there, or a change, keeps it
git -C "$PM" worktree add -q --detach "$TMP/worktrees/pmain/det-a" origin/main
st=0; $ONETREE rm det-a "$PM" >/dev/null 2>&1 || st=$?
eq "onetree rm: a clean detached checkout at a remote ref goes without --force, recorded as on-remote" "$st $([[ -d "$TMP/worktrees/pmain/det-a" ]] && echo left || echo gone) $($ONETREE events --json --kind gc | jq -c 'map(select(.path | endswith("det-a")) | .code)')" '0 gone ["on-remote"]'
git -C "$PM" worktree add -q --detach "$TMP/worktrees/pmain/det-b" origin/main
( cd "$TMP/worktrees/pmain/det-b" && git commit -q --allow-empty -m local )
git -C "$PM" worktree add -q --detach "$TMP/worktrees/pmain/det-c" origin/main
echo dirt > "$TMP/worktrees/pmain/det-c/app.txt"
s1=0; $ONETREE rm det-b "$PM" >/dev/null 2>&1 || s1=$?; s2=0; $ONETREE rm det-c "$PM" >/dev/null 2>&1 || s2=$?
eq "onetree rm: a detached checkout with a commit on no remote, or a change, is kept" "$s1 $s2 $([[ -d "$TMP/worktrees/pmain/det-b" && -d "$TMP/worktrees/pmain/det-c" ]] && echo kept)" "1 1 kept"

# ==== part 6
# ---- ui: argument and requirement checks (the server itself is covered by ui/server.test.ts)
s1=0; o1=$($ONETREE ui --bogus 2>&1) || s1=$?
s2=0; o2=$(PATH=/usr/bin:/bin $ONETREE ui --no-open 2>&1) || s2=$?
eq "ui rejects an unknown option, and refuses without node 22+" "$s1 $(grep -c '^onetree: ui: unknown option --bogus$' <<<"$o1") $s2 $(grep -cE '^onetree: ui: node 22\+ is required' <<<"$o2")" "1 1 1 1"

# ==== part 7
# ---- generated zsh wrappers: non-interactive client commands stay in the caller's cwd, byte-for-byte at argv/stdin/stdout/stderr
if command -v zsh >/dev/null; then
git clone -q origin.git wrapper-main 2>/dev/null
WRAP_MAIN=$TMP/wrapper-main; WRAP_ORDINARY=$TMP/wrapper-ordinary; mkdir -p "$WRAP_ORDINARY"
$ONETREE init --guard --root "$TMP/wrapper-worktrees" "$WRAP_MAIN" >/dev/null 2>&1
mkdir -p "$HOME/.claude"
WRAP_INSTALL_BIN=$TMP/wrapper-install-bin; mkdir -p "$WRAP_INSTALL_BIN"
printf '%s\n' '#!/bin/sh' 'echo Linux' > "$WRAP_INSTALL_BIN/uname"
cat > "$WRAP_INSTALL_BIN/crontab" <<'SH'
#!/bin/sh
if [ "${1:-}" = -l ]; then [ ! -f "$HOME/fake-crontab" ] || cat "$HOME/fake-crontab"; exit 0; fi
t=$(cat); printf '%s\n' "$t" > "$HOME/fake-crontab"   # read all of stdin first, like crontab: the pipe is still reading the old file
SH
chmod +x "$WRAP_INSTALL_BIN/uname" "$WRAP_INSTALL_BIN/crontab"
mkdir -p "$HOME/.codex"   # onetree's guard group sits between two of the user's; Codex's trust key for it is its position
jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "/opt/a.sh"}]}, {matcher: "Bash", hooks: [{type: "command", command: "/opt/old/onetree guard", timeout: 20}]}, {matcher: "Bash", hooks: [{type: "command", command: "/opt/b.sh"}]}],
  SessionStart: [{hooks: [{type: "command", command: "/opt/my-audit"}, {type: "command", command: "/opt/old/onetree session"}]}, {hooks: [{type: "mcp_tool", server: "s", tool: "t"}]}]}}' > "$HOME/.codex/hooks.json"   # onetree's session handler shares a group with the user's
mkdir -p "$HOME/dotfiles" "$HOME/.claude"; printf '# my rules\n' > "$HOME/dotfiles/CLAUDE.md"; chmod 644 "$HOME/dotfiles/CLAUDE.md"; ln -sf "$HOME/dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
printf '# mine\n[ -f ~/.onetree-agents.zsh ] && source ~/.onetree-agents.zsh\n' > "$HOME/.zshrc"; echo old > "$HOME/.onetree-agents.zsh"   # the earlier name
inst1=$(PATH="$WRAP_INSTALL_BIN:$PATH" $ONETREE install)
eq "install: a line sourcing the wrappers' earlier name is repointed, not doubled; the old file goes; the user's lines stay" \
  "$(grep -c onetree-agents "$HOME/.zshrc") $(grep -c 'source ~/.onetree-agents\.sh$' "$HOME/.zshrc") $(grep -c '^# mine$' "$HOME/.zshrc") $([[ -e "$HOME/.onetree-agents.zsh" ]] && echo old-left || echo old-gone)" \
  "1 1 1 old-gone"
eq "install: a rules file that is a symlink into a dotfiles repo is written through, keeping the link and its mode" \
  "$([[ -L "$HOME/.claude/CLAUDE.md" ]] && echo link) $(stat -c %a "$HOME/dotfiles/CLAUDE.md" 2>/dev/null || stat -f %Lp "$HOME/dotfiles/CLAUDE.md") $(grep -c '^# my rules$' "$HOME/dotfiles/CLAUDE.md") $(grep -c 'Worktrees' "$HOME/dotfiles/CLAUDE.md")" "link 644 1 1"
rm -f "$HOME/.claude/CLAUDE.md"; cp "$HOME/dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"   # back to a plain file: the drift test below edits it in place
ino1=$(ls -i "$HOME/.codex/hooks.json" | awk '{print $1}')
PATH="$WRAP_INSTALL_BIN:$PATH" $ONETREE install >/dev/null
eq "install: onetree's Codex guard keeps its place among the user's hooks, a reinstall leaves the file alone, and install says Codex needs an approval" \
  "$(jq -c '[.hooks.PreToolUse[].hooks[].command]' "$HOME/.codex/hooks.json") $([[ "$(ls -i "$HOME/.codex/hooks.json" | awk '{print $1}')" == "$ino1" ]] && echo same-file) $(grep -c 'NOTE: Codex skips onetree.s hooks until you approve them' <<<"$inst1")" \
  "[\"/opt/a.sh\",\"$HOME/.local/bin/onetree guard\",\"/opt/b.sh\"] same-file 1"
json_is "install: onetree owns handlers, not groups: the user's handler sharing onetree's group stays, an MCP hook (no command) stays, and onetree's own group is added" "$(jq -c .hooks.SessionStart "$HOME/.codex/hooks.json")" \
  '. == [{hooks: [{type: "command", command: "/opt/my-audit"}]}, {hooks: [{type: "mcp_tool", server: "s", tool: "t"}]}, {hooks: [{type: "command", command: "'"$HOME"'/.local/bin/onetree session", timeout: 10}]}]'
mkdir -p "$HOME/.dsh"; printf -- '- id: webserver\n  config: {}\n' > "$HOME/.dsh/cordis.patch.yml"
PATH="$WRAP_INSTALL_BIN:$PATH" $ONETREE install >/dev/null; PATH="$WRAP_INSTALL_BIN:$PATH" $ONETREE install >/dev/null
eq "install (Linux): one hourly gc job in the crontab, however often install runs" "$(grep -c 'onetree gc --all' "$HOME/fake-crontab")" 1
eq "install: dsh gets onetree's plugin and one managed insert row, the user's own rows kept, however often install runs" \
  "$(grep -c 'id: onetree' "$HOME/.dsh/cordis.patch.yml") $(grep -c 'id: webserver' "$HOME/.dsh/cordis.patch.yml") $(grep -cF "name: '$HOME/.dsh/onetree-plugin.mjs'" "$HOME/.dsh/cordis.patch.yml") $(grep -cF "\"$HOME/.local/bin/onetree\"" "$HOME/.dsh/onetree-plugin.mjs")" "1 1 1 1"
rm -rf "$HOME/.dsh"
drift() { doctor_json | jq -c '[.checks[] | select(.name | test("^installed onetree is the one in|^shell wrappers are what this onetree writes|^claude has this onetree.s rules")) | .ok]'; }
d1=$(drift)
cp "$HOME/.onetree-agents.sh" "$TMP/wrappers.bak"; echo '# edited' >> "$HOME/.onetree-agents.sh"
cp "$HOME/.claude/CLAUDE.md" "$TMP/claude-md.bak"; sed -i.x 's/^- \*\*Shipping:\*\*/- **Shipping (old):**/' "$HOME/.claude/CLAUDE.md"
cp "$HOME/.local/bin/onetree" "$TMP/onetree.bak"; echo '# stale' >> "$HOME/.local/bin/onetree"
d2=$(drift)
cp "$TMP/wrappers.bak" "$HOME/.onetree-agents.sh"; cp "$TMP/claude-md.bak" "$HOME/.claude/CLAUDE.md"; cp "$TMP/onetree.bak" "$HOME/.local/bin/onetree"
eq "doctor: the installed onetree, the wrappers and the rules match what this onetree writes, and each drift is named" "$d1 $d2" "[true,true,true] [false,false,false]"
mv "$HOME/.local/bin/onetree" "$HOME/.local/bin/onetree.real"
cat > "$HOME/.local/bin/onetree" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WRAP_AUTO_LOG"
exec "$HOME/.local/bin/onetree.real" "$@"
SH
cat > "$TMP/fake-agent" <<'SH'
#!/bin/sh
jq -n --args '$ARGS.positional' -- "$@" > "$WRAP_LOG.argv"
pwd -P > "$WRAP_LOG.cwd"
printf '%s' "${GIT_CONFIG_PARAMETERS:-}" > "$WRAP_LOG.gitcfg"
cat > "$WRAP_LOG.stdin"
printf 'stdout:%s\n' "$(basename "$0")"
printf 'stderr:%s\n' "$(basename "$0")" >&2
exit "${WRAP_EXIT:-0}"
SH
chmod +x "$HOME/.local/bin/onetree" "$TMP/fake-agent"
for a in claude codex pi dsh; do ln -sf "$TMP/fake-agent" "$TMP/bin/$a"; done
export WRAP_AUTO_LOG=$TMP/wrapper-auto.log
: > "$WRAP_AUTO_LOG"
wrapper_run() { # cwd exit stdin agent argv...
  local cwd=$1 code=$2 input=$3; shift 3
  rm -f "$TMP/wrapper-log.argv" "$TMP/wrapper-log.cwd" "$TMP/wrapper-log.stdin" "$TMP/wrapper-out" "$TMP/wrapper-err"
  WRAP_STATUS=0
  printf '%s' "$input" | WRAP_LOG="$TMP/wrapper-log" WRAP_EXIT="$code" "${WRAP_SHELL:-zsh}" -c 'source "${WRAP_FILE:-$HOME/.onetree-agents.sh}"; cd "$1"; shift; "$@"' "${WRAP_SHELL:-zsh}" "$cwd" "$@" > "$TMP/wrapper-out" 2> "$TMP/wrapper-err" || WRAP_STATUS=$?
}
wrapper_json() {
  jq -nc --argjson argv "$(cat "$TMP/wrapper-log.argv" 2>/dev/null || echo null)" --arg cwd "$(cat "$TMP/wrapper-log.cwd" 2>/dev/null)" \
    --arg stdin "$(cat "$TMP/wrapper-log.stdin" 2>/dev/null)" --arg stdout "$(cat "$TMP/wrapper-out")" \
    --arg stderr "$(cat "$TMP/wrapper-err")" --argjson status "$WRAP_STATUS" \
    '{argv:$argv,cwd:$cwd,stdin:$stdin,stdout:$stdout,stderr:$stderr,status:$status}'
}

n0=$(git -C "$WRAP_MAIN" worktree list --porcelain | grep -c '^worktree ')
wrapper_run "$WRAP_MAIN" 23 'claude stdin' claude --model sonnet -p 'prompt says exec login --print --resume'
json_is "wrapper: claude -p passes exact argv, cwd, streams and status through from a guarded main" "$(wrapper_json)" \
  '.argv == ["--model","sonnet","-p","prompt says exec login --print --resume"] and .cwd == "'"$WRAP_MAIN"'" and .stdin == "claude stdin" and .stdout == "stdout:claude" and .stderr == "stderr:claude" and .status == 23'
wrapper_run "$WRAP_MAIN" 0 '' claude --permission-mode dontAsk --print 'exec login --resume are prompt text'
json_is "wrapper: claude --print is found after unrelated options in a guarded main" "$(wrapper_json)" \
  '.argv == ["--permission-mode","dontAsk","--print","exec login --resume are prompt text"] and .cwd == "'"$WRAP_MAIN"'" and .status == 0'
wrapper_run "$WRAP_MAIN" 19 'codex stdin' codex --model o3 exec --json 'prompt says login --print --resume'
json_is "wrapper: codex exec passes exact argv, cwd, streams and status through from a guarded main" "$(wrapper_json)" \
  '.argv == ["--model","o3","exec","--json","prompt says login --print --resume"] and .cwd == "'"$WRAP_MAIN"'" and .stdin == "codex stdin" and .stdout == "stdout:codex" and .stderr == "stderr:codex" and .status == 19'
wrapper_run "$WRAP_MAIN" 0 '' codex --config 'note="login"' exec resume --last 'prompt contains exec login --print --resume'
json_is "wrapper: codex exec resume is passed through after a global option" "$(wrapper_json)" \
  '.argv == ["--config","note=\"login\"","exec","resume","--last","prompt contains exec login --print --resume"] and .cwd == "'"$WRAP_MAIN"'"'
wrapper_run "$WRAP_MAIN" 0 '' codex --profile team login status
json_is "wrapper: codex login is passed through after a global option" "$(wrapper_json)" \
  '.argv == ["--profile","team","login","status"] and .cwd == "'"$WRAP_MAIN"'"'
wrapper_run "$WRAP_MAIN" 0 '' codex --image first.png --model o3 exec --help
json_is "wrapper: a following option ends Codex's variadic image values, so a real exec command still passes through" "$(wrapper_json)" \
  '.argv == ["--image","first.png","--model","o3","exec","--help"] and .cwd == "'"$WRAP_MAIN"'"'
wrapper_run "$WRAP_MAIN" 0 '' claude --resume=session-123
claude_resume_equals=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' claude --worktree=review-123
claude_worktree_equals=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' codex e 'alias prompt'
codex_exec_alias=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' codex --image=first.png exec --help
codex_image_equals=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' codex -ifirst.png exec --help
codex_image_attached=$(wrapper_json)
json_is "wrapper: existing Claude equals routes and Codex's exec alias and attached image forms pass through" \
  "$(jq -nc --argjson a "$claude_resume_equals" --argjson b "$claude_worktree_equals" --argjson c "$codex_exec_alias" --argjson d "$codex_image_equals" --argjson e "$codex_image_attached" '[ $a,$b,$c,$d,$e ]')" \
  'all(.cwd == "'"$WRAP_MAIN"'") and [.[].argv] == [["--resume=session-123"],["--worktree=review-123"],["e","alias prompt"],["--image=first.png","exec","--help"],["-ifirst.png","exec","--help"]]'

wrapper_run "$WRAP_ORDINARY" 0 '' claude -p ordinary
r1=$(wrapper_json)
wrapper_run "$WRAP_ORDINARY" 0 '' claude --model sonnet --print ordinary
r2=$(wrapper_json)
wrapper_run "$WRAP_ORDINARY" 0 '' codex exec ordinary
r3=$(wrapper_json)
wrapper_run "$WRAP_ORDINARY" 0 '' codex exec resume --last ordinary
r4=$(wrapper_json)
wrapper_run "$WRAP_ORDINARY" 0 '' codex login status
r5=$(wrapper_json)
json_is "wrapper: every print, exec, resume and login form also stays in an ordinary directory with exact argv" \
  "$(jq -nc --argjson a "$r1" --argjson b "$r2" --argjson c "$r3" --argjson d "$r4" --argjson e "$r5" '[ $a,$b,$c,$d,$e ]')" \
  'all(.cwd == "'"$WRAP_ORDINARY"'" and .status == 0) and [.[].argv] == [["-p","ordinary"],["--model","sonnet","--print","ordinary"],["exec","ordinary"],["exec","resume","--last","ordinary"],["login","status"]]'
n1=$(git -C "$WRAP_MAIN" worktree list --porcelain | grep -c '^worktree ')
eq "wrapper: pass-through never calls onetree auto or creates a worktree" "$(wc -l < "$WRAP_AUTO_LOG" | tr -d ' ') $n0 $n1" "0 1 1"

# Tokens that are prompt text, option values, or beyond -- are not mode flags. Existing Claude worktree/continue routing still passes through.
: > "$WRAP_AUTO_LOG"
wrapper_run "$WRAP_MAIN" 0 '' codex --model exec 'prompt says login --print --resume'
codex_relocated=$(wrapper_json); codex_gitcfg=$(cat "$TMP/wrapper-log.gitcfg")
wrapper_run "$WRAP_MAIN" 0 '' codex --image first.png exec --help
codex_image_value=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' codex -- exec
codex_after_dash=$(wrapper_json)
jq -n --arg p "$WRAP_MAIN" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"   # a trusted checkout: Claude still starts in onetree's worktree, never through -w
wrapper_run "$WRAP_MAIN" 0 '' claude --append-system-prompt --print 'prompt says exec login --resume'
claude_value=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' claude -- --print
claude_after_dash=$(wrapper_json)
rm -f "$HOME/.claude.json"
wrapper_run "$WRAP_MAIN" 0 '' claude --model sonnet --continue
claude_continue=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' pi interactive
pi_relocated=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 0 '' dsh interactive
dsh_relocated=$(wrapper_json)
wrapper_run "$WRAP_ORDINARY" 0 '' codex interactive
codex_ordinary=$(wrapper_json)
json_is "wrapper: mode-like option values and prompt tokens do not fool routing; Claude continue remains direct" \
  "$(jq -nc --argjson a "$codex_relocated" --argjson av "$codex_image_value" --argjson az "$codex_after_dash" --argjson b "$claude_value" --argjson c "$claude_after_dash" --argjson d "$claude_continue" --argjson e "$pi_relocated" --argjson f "$dsh_relocated" --argjson g "$codex_ordinary" '{a:$a,av:$av,az:$az,b:$b,c:$c,d:$d,e:$e,f:$f,g:$g}')" \
  '.a.argv[12:] == ["--model","exec","prompt says login --print --resume"] and (.a.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/codex-")) and .av.argv[12:] == ["--image","first.png","exec","--help"] and (.av.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/codex-")) and .az.argv[12:] == ["--","exec"] and (.az.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/codex-")) and .b.argv == ["--append-system-prompt","--print","prompt says exec login --resume"] and (.b.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/claude-")) and .c.argv == ["--","--print"] and (.c.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/claude-")) and .d.argv == ["--model","sonnet","--continue"] and .d.cwd == "'"$WRAP_MAIN"'" and (.e.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/pi-")) and (.f.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/dsh-")) and .g.cwd == "'"$WRAP_ORDINARY"'"'

json_is "wrapper: a relocated codex gets onetree's grants and runs git without FETCH_HEAD, auto gc or maintenance" "$(jq -c --arg g "$codex_gitcfg" '. + {gitcfg: $g}' <<<"$codex_relocated")" \
  '.argv[:12] == ["--add-dir", "'"$WRAP_MAIN"'/.git/objects", "--add-dir", ("'"$WRAP_MAIN"'/.git/worktrees/" + (.cwd | split("/") | last)), "--add-dir", "'"$WRAP_MAIN"'/.git/refs/heads/feature", "--add-dir", "'"$WRAP_MAIN"'/.git/logs/refs/heads/feature", "--add-dir", "'"$WRAP_MAIN"'/.git/refs/remotes/origin", "--add-dir", "'"$WRAP_MAIN"'/.git/logs/refs/remotes/origin"]
   and .gitcfg == "'"'"'fetch.writefetchhead=false'"'"' '"'"'maintenance.auto=false'"'"' '"'"'gc.auto=0'"'"'"'
# A missing onetree binary cannot affect direct modes, but relocation-required commands still fail closed.
mv "$HOME/.local/bin/onetree" "$HOME/.local/bin/onetree.missing"
wrapper_run "$WRAP_MAIN" 17 'missing stdin' claude --print missing
missing_claude=$(wrapper_json)
wrapper_run "$WRAP_MAIN" 18 '' codex exec missing
missing_codex=$(wrapper_json)
rm -f "$TMP/wrapper-log.argv"
wrapper_run "$WRAP_MAIN" 0 '' codex interactive
missing_interactive_status=$WRAP_STATUS
missing_interactive_called=$([[ -f "$TMP/wrapper-log.argv" ]] && echo yes || echo no)
mv "$HOME/.local/bin/onetree.missing" "$HOME/.local/bin/onetree"
json_is "wrapper: pass-through works without onetree, preserving status, while relocation still fails closed" \
  "$(jq -nc --argjson a "$missing_claude" --argjson b "$missing_codex" --argjson status "$missing_interactive_status" --arg called "$missing_interactive_called" '{a:$a,b:$b,status:$status,called:$called}')" \
  '.a.argv == ["--print","missing"] and .a.stdin == "missing stdin" and .a.status == 17 and .b.argv == ["exec","missing"] and .b.status == 18 and .status == 1 and .called == "no"'
WRAP_SHELL=bash wrapper_run "$WRAP_MAIN" 5 'bash stdin' claude -p 'from bash'
bash_print=$(wrapper_json)
WRAP_SHELL=bash wrapper_run "$WRAP_MAIN" 0 '' pi interactive
bash_pi=$(wrapper_json)
json_is "wrapper: bash sources the same file; print mode passes through as typed and an interactive agent is relocated" "$(jq -nc --argjson a "$bash_print" --argjson b "$bash_pi" '{a:$a,b:$b}')" \
  '.a.argv == ["-p","from bash"] and .a.cwd == "'"$WRAP_MAIN"'" and .a.stdin == "bash stdin" and .a.status == 5 and .b.argv == ["interactive"] and (.b.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/pi-"))'
for sh in zsh bash; do   # what Claude Code's shell snapshot carries into an agent's shell: the functions, minus names starting with one underscore, and no variables
  "$sh" -c 'source "$HOME/.onetree-agents.sh"; { if [ -n "${ZSH_VERSION:-}" ]; then typeset +f; else declare -F | cut -d" " -f3; fi; } | grep -vE "^_[^_]" | while read -r f; do typeset -f "$f"; done' > "$TMP/snapshot.$sh"
done
WRAP_FILE=$TMP/snapshot.zsh wrapper_run "$WRAP_MAIN" 0 '' claude -p snap
snap_print=$(wrapper_json)
WRAP_FILE=$TMP/snapshot.bash WRAP_SHELL=bash wrapper_run "$WRAP_MAIN" 0 '' pi snap
snap_pi=$(wrapper_json)
json_is "wrapper: what Claude Code's shell snapshot keeps of it still works in an agent's shell: print mode passes through, an agent is relocated" "$(jq -nc --argjson a "$snap_print" --argjson b "$snap_pi" '{a:$a,b:$b}')" \
  '.a.argv == ["-p","snap"] and .a.cwd == "'"$WRAP_MAIN"'" and .b.argv == ["snap"] and (.b.cwd | startswith("'"$TMP"'/wrapper-worktrees/wrapper-main/pi-"))'
PATH="$WRAP_INSTALL_BIN:$PATH" $ONETREE uninstall >/dev/null 2>&1 || true
eq "uninstall (Linux): the gc job leaves the crontab" "$(grep -c 'onetree gc --all' "$HOME/fake-crontab" || true)" 0
json_is "uninstall: takes out only onetree's handlers, leaving the user's, in order, and the MCP hook" "$(jq -c .hooks "$HOME/.codex/hooks.json")" \
  '.PreToolUse == [{matcher: "Bash", hooks: [{type: "command", command: "/opt/a.sh"}]}, {matcher: "Bash", hooks: [{type: "command", command: "/opt/b.sh"}]}] and .SessionStart == [{hooks: [{type: "command", command: "/opt/my-audit"}]}, {hooks: [{type: "mcp_tool", server: "s", tool: "t"}]}]'
else
  printf 'skip  generated zsh wrappers: zsh is unavailable\n'
fi

# ---- update follows releases: an origin with releases v1.9.0 and v1.10.0 (version order, not text order), a pre-release, and an unreleased commit on main
UH=$TMP/uhome; UB=$TMP/ubin; mkdir -p "$UH" "$UB"
printf '%s\n' '#!/bin/sh' 'echo Linux' > "$UB/uname"; printf '%s\n' '#!/bin/sh' '[ "$1" = -l ] || cat >/dev/null' > "$UB/crontab"; chmod +x "$UB/uname" "$UB/crontab"
ut() { HOME=$UH ONETREE_CONFIG=$UH/config ONETREE_BREW_PREFIX=$TMP/brew PATH="$UB:$PATH" "$@"; }   # install's side effects stay in UH; no real brew
git init -q --bare rel.git; git clone -q rel.git rel-src 2>/dev/null; mkdir -p rel-src/bin "$TMP/brew/Cellar/onetree/1.9.0/libexec/bin"
for v in 1.9.0 1.10.0 1.11.0-rc.1 1.11.0-dev; do
  sed "s/^VERSION=.*/VERSION=$v/" "$ONETREE" > rel-src/bin/onetree; chmod +x rel-src/bin/onetree
  ( cd rel-src && git add -A && git commit -qm "$v" && { [[ $v == *-dev ]] || git tag "v$v"; } )
done
( cd rel-src && git push -q origin HEAD:main --tags ); git -C rel.git symbolic-ref HEAD refs/heads/main
git clone -q rel.git rel-install 2>/dev/null; git -C rel-install -c advice.detachedHead=false checkout -q v1.9.0
ut rel-install/bin/onetree install >/dev/null; ut "$UH/.local/bin/onetree" update >/dev/null 2>&1 || true
eq "update (release install): checks out the newest vX.Y.Z tag, skipping pre-releases, and reinstalls it" "$(git -C rel-install describe --tags) $(ut "$UH/.local/bin/onetree" version)" "v1.10.0 onetree 1.10.0"
git clone -q rel.git rel-dev 2>/dev/null; git -C rel-dev reset -q --hard v1.9.0
ut rel-dev/bin/onetree install >/dev/null; ut "$UH/.local/bin/onetree" update >/dev/null 2>&1 || true
eq "update (contributor clone): fast-forwards its branch, unreleased commits too, and reinstalls" "$(git -C rel-dev symbolic-ref --short HEAD) $(ut "$UH/.local/bin/onetree" version)" "main onetree 1.11.0-dev"
eq "version: a clone off a tag adds (dev <short sha>); a clone at a tag and the installed copy do not" \
  "$(rel-dev/bin/onetree version) / $(rel-install/bin/onetree version) / $(ut "$UH/.local/bin/onetree" version)" "onetree 1.11.0-dev (dev $(git -C rel-dev rev-parse --short HEAD)) / onetree 1.10.0 / onetree 1.11.0-dev"
cp rel-src/bin/onetree "$TMP/brew/Cellar/onetree/1.9.0/libexec/bin/"; ut "$TMP/brew/Cellar/onetree/1.9.0/libexec/bin/onetree" install >/dev/null
eq "update (Homebrew install, source under the brew prefix): changes nothing, prints the brew command, exits 0" \
  "$(ut "$UH/.local/bin/onetree" update; echo "exit $?")" "onetree: installed with Homebrew; update with: brew upgrade onetree && $TMP/brew/bin/onetree install"$'\n'"exit 0"

# ---- install.sh, under sh: the newest release into ONETREE_HOME, then install; a rerun updates in place; anything else there is refused
IH=$TMP/ihome; ID=$IH/.local/share/onetree; mkdir -p "$IH"
it() { HOME=$IH ONETREE_CONFIG=$IH/config ONETREE_BREW_PREFIX=$TMP/brew ONETREE_REPO=$TMP/rel.git PATH="$UB:$PATH" sh "$(dirname "$ONETREE")/../install.sh"; }
it >/dev/null 2>&1 || true
eq "install.sh: clones the newest release into ~/.local/share/onetree, detached at its tag, and installs it" "$(git -C "$ID" describe --tags) $(git -C "$ID" symbolic-ref -q HEAD || echo detached) $(HOME=$IH "$IH/.local/bin/onetree" version)" "v1.10.0 detached onetree 1.10.0"
sed "s/^VERSION=.*/VERSION=1.12.0/" "$ONETREE" > rel-src/bin/onetree; ( cd rel-src && git commit -qam 1.12.0 && git tag v1.12.0 && git push -q origin HEAD:main --tags )
{ echo mine > "$ID/notes.txt"; } 2>/dev/null || true; it >/dev/null 2>&1 || true
eq "install.sh: a rerun moves the same checkout to the new release and reinstalls, keeping an untracked file, one rc line, one source" \
  "$(git -C "$ID" describe --tags) $(HOME=$IH "$IH/.local/bin/onetree" version) $(cat "$ID/notes.txt") $(grep -c onetree-agents "$IH/.zshrc") $(git config -f "$IH/config" --get-all onetree.source)" "v1.12.0 onetree 1.12.0 mine 1 $ID"
git init -q occupied; ( cd occupied && echo keep > data && git add data && git commit -qm mine && git tag v9.9.9 && git remote add origin "$TMP/occupied" ); h0=$(git -C occupied symbolic-ref HEAD)   # another project's checkout, with a release-like tag
eq "install.sh: an ONETREE_HOME holding anything but an onetree checkout (here another project's) is refused and left as it was" \
  "$(ONETREE_HOME=$TMP/occupied it >/dev/null 2>&1; echo "exit $?") $(git -C occupied symbolic-ref -q HEAD || echo detached) $(git -C occupied status --porcelain | wc -l | tr -d ' ')" "exit 1 $h0 0"

V=$(sed -n 's/^VERSION=//p' "$ONETREE"); v=${V//./\\.}; R=$(dirname "$ONETREE")/..   # VERSION is the one source; the rest must agree with it
has "version: onetree version, --version, ui/package.json and the newest released CHANGELOG heading (## X.Y.Z (YYYY-MM-DD)) all give VERSION" \
  "$($ONETREE version) / $($ONETREE --version) / $(jq -r .version "$R/ui/package.json") / $(grep -m1 -E '^## [0-9]' "$R/CHANGELOG.md")" \
  "^onetree $v( \(dev [0-9a-f]+\))? / onetree $v( \(dev [0-9a-f]+\))? / $v / ## $v \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$"

REF=$(dirname "$ONETREE")/../docs/reference.md   # every subcommand in the dispatch and every config key onetree reads is documented
cmds=$(sed -n '/^case "${1:-}" in$/,/^esac/p' "$ONETREE" | grep -oE '^  [a-z][a-z|-]*\)' | tr -d ' )' | tr '|' '\n')
keys=$(grep -oE '\b(cfg|cfg_find_clone) [a-z][A-Za-z]+' "$ONETREE" | cut -d' ' -f2 | grep -vxE 'lookup|onetree' | sort -u)
undoc=$(for w in $cmds $keys; do grep -qE "\`(onetree )?$w([^a-zA-Z-]|$)" "$REF" || printf '%s ' "$w"; done)
if [[ -z "$undoc" && -n "$cmds" && -n "$keys" ]]; then ok "reference.md documents every subcommand and config key"; else bad "reference.md documents every subcommand and config key" "missing: ${undoc:-the extraction found nothing}"; fi

# ==== end
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
