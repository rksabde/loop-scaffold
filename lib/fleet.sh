#!/usr/bin/env bash
# loop/fleet.sh — dispatch every "status: ready" plan in parallel,
# one git worktree each, capped at MAX_PARALLEL.
#
#   ./loop/fleet.sh              # dispatch ready plans
#   RETRY=1 ./loop/fleet.sh      # manual mode: also re-run plans whose branch exists
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$SCAFFOLD_ROOT"

# ── sweep: recover plans stranded in 'running' by a killed worker (kill -9 skips
# integrate.sh's own trap). A running plan whose recorded PID is gone → back to ready.
for p in plans/*.md; do
  grep -q '^status: running' "$p" 2>/dev/null || continue
  s="$(basename "$p" .md)"; pidf="loop/state/$s.pid"
  pid="$(cat "$pidf" 2>/dev/null)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    log "[fleet] '$s' stranded in 'running' (worker dead) — resetting to ready"
    set_status "$p" ready
    rm -f "$pidf"
  fi
done

ready="$(grep -l '^status: ready' plans/*.md 2>/dev/null | grep -v 'PROGRESS' || true)"

# ── idempotency (manual mode): a ready plan whose loop/<slug> branch already exists
# has already been executed — skip it instead of paying for a duplicate run. The human
# should verify+merge it, delete the branch, or force with RETRY=1. Closed-loop mode
# manages the lifecycle itself (status flips + branch reuse on retry), so no skip there.
if [ "${AUTO_INTEGRATE:-0}" != "1" ] && [ "${RETRY:-0}" != "1" ] && [ -n "$ready" ]; then
  kept=""
  while IFS= read -r p; do
    s="$(basename "$p" .md)"
    if git rev-parse -q --verify "refs/heads/loop/$s" >/dev/null; then
      log "[fleet] skip '$s' — branch loop/$s already exists (verify+merge it, delete the branch, or RETRY=1)"
    else
      kept="${kept}${p}"$'\n'
    fi
  done <<< "$ready"
  ready="$(printf '%s' "$kept")"
fi

if [ -z "$ready" ]; then
  log "no plans with 'status: ready' — nothing to dispatch"
  exit 0
fi

# AUTO_INTEGRATE=1 → each plan runs the CLOSED loop (execute→verify→merge|retry|
# replan|block) via integrate.sh. Off (default) → bare executor runs; you verify and
# merge by hand afterward. Merges inside integrate.sh are serialized via a lock, so
# parallel workers are safe in either mode.
if [ "${AUTO_INTEGRATE:-0}" = "1" ]; then
  worker="loop/integrate.sh"; mode="closed loop (verify+merge+self-correct)"
else
  worker="loop/run-plan.sh";  mode="executor only (manual verify+merge)"
fi

log "dispatching $(echo "$ready" | wc -l | tr -d ' ') plan(s), -P ${MAX_PARALLEL:-3}, mode: $mode"
echo "$ready" >&2

echo "$ready" | xargs -P "${MAX_PARALLEL:-3}" -I{} bash "$worker" {}

log "fleet done."
if [ "${AUTO_INTEGRATE:-0}" = "1" ]; then
  log "merged → main: git log --oneline | grep integrate"
  log "blocked:       ls plans/*.blocked.md 2>/dev/null"
else
  log "branches:  git branch --list 'loop/*'"
  log "verify:    ./loop/verify.sh plans/<plan>.md"
fi
