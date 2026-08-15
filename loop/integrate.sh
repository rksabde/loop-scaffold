#!/usr/bin/env bash
# loop/integrate.sh — the CLOSED loop for ONE plan: execute → verify → act.
# This is the "integrator" role: it turns the advisory verifier into a decision.
#
#   ./loop/integrate.sh plans/001-foo.md
#
# Outcomes:
#   PASS  → merge the branch into BASE_BRANCH, status: done, clean the worktree.
#   FAIL  → self-correct WITHOUT a human:
#            • re-run the executor up to MAX_ATTEMPTS, feeding the verifier's verdict
#              back as the fix (tactical retry — fix the code);
#            • if still failing, re-plan up to MAX_REPLANS (strategic retry — fix the
#              plan), then retry the executor again;
#            • if BOTH caps exhaust → status: blocked + plans/<slug>.blocked.md, stop.
# Total executor runs are bounded by (MAX_REPLANS + 1) * MAX_ATTEMPTS.
#
# Safety (parallel fleets):
#   • ALL merges + bookkeeping commits are serialized through loop/state/merge.lock
#     (atomic mkdir; stale locks from dead PIDs are stolen) — xargs -P workers can't
#     race each other's `git checkout`/`git merge` in the shared main checkout.
#   • Every outcome is COMMITTED (status flip, PROGRESS, blocked note) — no dirty tree.
#   • Crash recovery: a trap restores `status: ready` if we die before a terminal
#     state, and fleet.sh sweeps plans stranded in `running` by a kill -9.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/adapters/${LOOP_TOOL:-claude}.sh"

plan="${1:?usage: integrate.sh plans/NNN-name.md}"
slug="$(basename "$plan" .md)"
branch="loop/$slug"
base="${BASE_BRANCH:-main}"
cd "$SCAFFOLD_ROOT"
mkdir -p loop/logs loop/state

ATTEMPTS="${MAX_ATTEMPTS:-2}"
REPLANS="${MAX_REPLANS:-1}"
fbfile="loop/logs/$slug.feedback"
rm -f "$fbfile"            # start blind; verify.sh writes this only after a FAIL

# ── merge/bookkeeping mutex (serializes ALL git ops on the shared main checkout) ──
LOCK="$SCAFFOLD_ROOT/loop/state/merge.lock"
LOCK_WAIT="${MERGE_LOCK_WAIT:-900}"

_lock_acquire() {
  local waited=0 pid
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && return 0     # re-entrant
  while ! mkdir "$LOCK" 2>/dev/null; do
    pid="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "[integrate] stale merge lock (pid $pid dead) — stealing"
      rm -rf "$LOCK"; continue
    fi
    if [ "$waited" -ge "$LOCK_WAIT" ]; then
      log "[integrate] $slug: merge lock timeout after ${LOCK_WAIT}s"; return 1
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo $$ > "$LOCK/pid"
}
_lock_release() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}

# ── crash recovery: never strand a plan in 'running' ─────────────────────────
PIDFILE="$SCAFFOLD_ROOT/loop/state/$slug.pid"
echo $$ > "$PIDFILE"
terminal=0
_cleanup() {
  [ "$terminal" -eq 1 ] || set_status "$plan" ready
  rm -f "$PIDFILE"
  _lock_release
}
trap _cleanup EXIT INT TERM

# _bookkeep <msg> <path...> — commit loop bookkeeping (status flip, PROGRESS, notes,
# transcripts). Caller must hold the lock. --no-verify: bookkeeping carries no secrets
# and strict pre-commit hooks false-positive on model-generated text.
_bookkeep() {
  local msg="$1" p; shift
  for p in "$@" plans/PROGRESS.md; do [ -e "$p" ] && git add "$p" 2>/dev/null; done
  git diff --cached --quiet || git commit -q --no-verify -m "$msg"
}

# ── outcomes ─────────────────────────────────────────────────────────────────
_merge_and_finish() {
  _lock_acquire || return 1
  log "[integrate] $slug PASS → merging $branch into $base"
  git checkout "$base" >/dev/null 2>&1 \
    || { log "[integrate] cannot checkout $base"; _lock_release; return 1; }
  if git merge --no-ff --no-verify -m "integrate $slug" "$branch" >/dev/null 2>&1; then
    set_status "$plan" done
    # transcripts (verify-NN/meta-NN) were rendered into .transcripts/<slug>/ by the
    # verify step; they ride in this bookkeeping commit alongside the status flip.
    _bookkeep "bookkeep $slug: done" "$plan" ".transcripts/$slug"
    git worktree remove --force "$(worktree_path "$slug")" 2>/dev/null || true
    git branch -d "$branch" >/dev/null 2>&1 || true
    log "[integrate] $slug merged + marked done; worktree/branch cleaned"
    terminal=1; _lock_release
    return 0
  fi
  git merge --abort >/dev/null 2>&1 || true
  _lock_release
  log "[integrate] $slug merge CONFLICT against $base — leaving branch for a human"
  _block "merge conflict against $base (another plan likely touched the same files)"
  return 1
}

# terminal escalation: no PASS after every cap exhausted (or unrecoverable state)
_block() {
  local why="$1"
  set_status "$plan" blocked
  {
    echo "# BLOCKED: $slug"
    echo
    echo "Reason: $why"
    echo "Exhausted $ATTEMPTS executor attempt(s) × $((REPLANS + 1)) plan version(s) without a merge."
    echo
    echo "## Last verifier verdict"
    echo '```'
    cat "$fbfile" 2>/dev/null || echo "(no verdict captured — verify ERROR)"
    echo '```'
    echo
    echo "## State (kept for inspection)"
    echo "- branch:   $branch"
    echo "- worktree: $(worktree_path "$slug")"
    echo
    echo "## Your move"
    echo "Inspect the branch, fix the plan or the underlying blocker, set \`status: ready\`,"
    echo "then re-run \`./loop/fleet.sh\` (or \`./loop/integrate.sh $plan\`)."
  } > "plans/$slug.blocked.md"
  if _lock_acquire; then
    _bookkeep "bookkeep $slug: blocked" "$plan" "plans/$slug.blocked.md" ".transcripts/$slug"
    _lock_release
  fi
  terminal=1
  log "[integrate] $slug BLOCKED → see plans/$slug.blocked.md (branch/worktree kept)"
}

# ask the planner to rewrite a failing plan from its verdict
_replan() {
  log "[integrate] $slug replanning from failure (planner → frontier)"
  read -r -d '' rp <<PROMPT || true
Use the planner subagent. The plan below FAILED automated verification after $ATTEMPTS
executor attempt(s). Rewrite it IN PLACE so it is achievable: correct wrong assumptions,
fix or tighten the \`## Acceptance\` checks, add missing context/constraints, narrow scope.
Keep the SAME file path ($plan), the SAME plan number, and the SAME \`worktree:\` value;
set \`status: ready\`. Write ONLY $plan — do not create a new plan file or touch code.

--- CURRENT PLAN ($plan) ---
$(cat "$plan")

--- WHY IT FAILED (verifier verdict, last attempt) ---
$(cat "$fbfile" 2>/dev/null || echo "(no verdict captured)")
PROMPT
  LOOP_PLAN_SLUG="$slug" adapter_run planner "$rp" "loop/logs/$slug.replan.json" || true
  rm -f "$fbfile"   # the plan changed; next attempt starts blind against the new plan
}

# ── the closed loop ───────────────────────────────────────────────────────────
replan_n=0
while :; do
  set_status "$plan" running
  passed=0
  attempt=1
  while [ "$attempt" -le "$ATTEMPTS" ]; do
    log "[integrate] $slug — executor attempt $attempt/$ATTEMPTS (plan v$((replan_n + 1)))"
    ./loop/run-plan.sh "$plan" || true        # verdict, not exit code, decides
    if ./loop/verify.sh "$plan" >/dev/null 2>&1; then passed=1; break; fi
    attempt=$((attempt + 1))                  # verify.sh wrote $fbfile; next run consumes it
  done

  [ "$passed" -eq 1 ] && { _merge_and_finish && exit 0 || exit 1; }

  if [ "$replan_n" -lt "$REPLANS" ]; then
    replan_n=$((replan_n + 1))
    _replan
    continue
  fi

  _block "verifier never returned PASS"
  exit 1
done
