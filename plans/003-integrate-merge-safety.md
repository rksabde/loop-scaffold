# 003 — integrate.sh merge safety (lock, bookkeeping commits, crash recovery)

status: done
worktree: integrate-merge-safety

## Goal (verifiable)
`AUTO_INTEGRATE=1` with `MAX_PARALLEL>1` is safe: merges into BASE_BRANCH are
serialized by a lock; every outcome (done / blocked) is COMMITTED (no dirty tree left);
a killed integrate.sh cannot strand a plan in `status: running` forever.

## Context (bugs found by review)
1. fleet.sh dispatches integrate.sh via `xargs -P N`; each does `git checkout main
   && git merge` in the SAME main checkout → concurrent checkouts/merges collide.
2. integrate.sh flips `status:` and writes blocked.md but never commits → dirty
   plans/NNN.md accumulates on main, can block later checkouts/merges.
3. SIGKILL mid-run leaves `status: running`; fleet greps `^status: ready` → plan
   never dispatched again, silently dead.

## Tasks
- Mutex: `_merge_lock()` using atomic `mkdir loop/state/merge.lock` with bounded wait
  (e.g. 15 min) + PID file for staleness; take it around checkout+merge+bookkeeping,
  always release (trap).
- Bookkeeping commit after merge: `git commit` of the status flip (done) + PROGRESS.md
  line, message `bookkeep <slug>: done`. On block: commit status flip → blocked and the
  blocked summary (move summary from gitignored loop/logs/ to `plans/<slug>.blocked.md`
  so it's committable + visible in the repo).
- Crash recovery: on integrate.sh start, `trap` INT/TERM/EXIT to restore `status: ready`
  if the run reached no terminal state. Plus fleet-side sweep: a plan `running` with no
  live worktree lock older than TIMEOUT → reset to `ready` with a log line.
- verify.sh/run-plan.sh untouched except where the lock forces call-site changes.

## Acceptance
- [ ] Stub test: two integrate.sh in parallel (stub adapters, both PASS) → both merges
      land, `git fsck` clean, no "checkout" errors in logs (script the test under /tmp)
- [ ] Stub test: kill -9 an integrate.sh mid-executor → plan file back at `status: ready`
      (or sweep restores it), lock released
- [ ] After a stubbed PASS: `git status --porcelain` in repo root is empty (bookkeeping committed)
- [ ] After a stubbed exhaust-block: `plans/<slug>.blocked.md` exists AND is committed;
      `git status --porcelain` empty
- [ ] `bash -n loop/integrate.sh loop/fleet.sh` exit 0
