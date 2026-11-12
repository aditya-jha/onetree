# Copy-on-write clones for new worktrees

**Status:** tried and dropped.

**In one line:** cloning the main checkout's files was slower than letting git
write them, so `onetree new` writes them with one git worker per CPU core instead.

## The problem

Claude Code waits for `onetree new` before a session starts, and most of that
wait is `git worktree add` writing every tracked file. On a large repo (32k
files, 4.7 GB) it took 26 s, and every agent pays it again on every new task.

## What was tried

Most files in a new worktree are identical to the main checkout's. APFS (and
reflink filesystems on Linux) can copy a file without copying its bytes, so the
plan was:

1. create the worktree without checking anything out;
2. clone the main checkout's unmodified tracked files into it;
3. let `git checkout` write only the files that differ from the branch;
4. fall back to a normal checkout whenever any step can't be trusted.

## Results

The same repo after its large binaries were untracked (29k files, 2.8 GB,
12 cores, APFS):

| How `onetree new` writes files | total | writing files |
|---|---|---|
| git, one worker (before) | 13.2 s | 8.7 s |
| copy-on-write clone (prototype) | 44.5 s | 40.1 s |
| git, one worker per core (shipped) | 8.3 s | 4.3–4.8 s |

## Why it lost

- **Clones cost per file, not per byte.** An APFS clone takes about 0.27 ms per
  file whatever the size, so 30k small files take as long to clone as git takes
  to write them. Clones save disk, not time.
- **Ignored files get in the way.** `__pycache__` folders all through the tree
  meant cloning about 1,900 separate pieces rather than a few top-level folders.
- **Git re-reads every file afterwards.** Clones get new inode numbers, so git
  treats every file as possibly changed and hashes it again. Avoiding that would
  have meant changing git settings in the user's repo.
- **Read-only modes are copied too.** A guarded main checkout's files are
  read-only, and the clones would need every one made writable.

## Also rejected

- **A pool of ready-made worktrees** that `new` renames into place. That's the
  fastest option (about 2 s), but it keeps one spare full checkout per repo on
  disk all the time.
- **Sparse checkout** of a repo's big folders. A script that reads a skipped
  file fails later, far from the cause.

## What worked instead

Besides the parallel checkout, the biggest gain was untracking large
generated files and linking them in from a shared store with `bootstrap`: that
alone took 26 s down to 13.2 s.
