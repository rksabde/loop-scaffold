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
#            • if BOTH caps exhaust → status: blocked + a human-readable summary, stop.
# Total executor runs are bounded by (MAX_REPLANS + 1) * MAX_ATTEMPTS.
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

# --- merge a passing branch into base, then tidy up --------------------------
_merge_and_finish() {
  log "[integrate] $slug PASS → merging $branch into $base"
  git checkout "$base" >/dev/null 2>&1 || { log "[integrate] cannot checkout $base"; return 1; }
  if git merge --no-ff -m "integrate $slug" "$branch" >/dev/null 2>&1; then
    set_status "$plan" done
    git worktree remove --force "$(worktree_path "$slug")" 2>/dev/null || true
    git branch -d "$branch" >/dev/null 2>&1 || true
    log "[integrate] $slug merged + marked done; worktree/branch cleaned"
    return 0
  fi
  git merge --abort >/dev/null 2>&1 || true
  log "[integrate] $slug merge CONFLICT against $base — leaving branch for a human"
  _block "merge conflict against $base (another plan likely touched the same files)"
  return 1
}

# --- terminal escalation: no PASS after every cap exhausted ------------------
_block() {
  local why="$1"
  set_status "$plan" blocked
  {
    echo "# BLOCKED: $slug"
    echo
    echo "Reason: $why"
    echo "Exhausted $ATTEMPTS executor attempt(s) × $((REPLANS + 1)) plan version(s) without a PASS."
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
  } > "loop/logs/$slug.blocked.md"
  log "[integrate] $slug BLOCKED → see loop/logs/$slug.blocked.md (branch/worktree kept)"
}

# --- ask the planner to rewrite a failing plan from its verdict --------------
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
  adapter_run planner "$rp" "loop/logs/$slug.replan.json" || true
  rm -f "$fbfile"   # the plan changed; next attempt starts blind against the new plan
}

# --- the closed loop ---------------------------------------------------------
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
