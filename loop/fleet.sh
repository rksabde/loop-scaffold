#!/usr/bin/env bash
# loop/fleet.sh — dispatch every "status: ready" plan in parallel,
# one git worktree each, capped at MAX_PARALLEL.
#
#   ./loop/fleet.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$SCAFFOLD_ROOT"

ready="$(grep -l '^status: ready' plans/*.md 2>/dev/null | grep -v 'PROGRESS' || true)"
if [ -z "$ready" ]; then
  log "no plans with 'status: ready' — nothing to dispatch"
  exit 0
fi

# AUTO_INTEGRATE=1 → each plan runs the CLOSED loop (execute→verify→merge|retry|
# replan|block) via integrate.sh. Off (default) → bare executor runs; you verify and
# merge by hand afterward.
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
  log "blocked:       ls loop/logs/*.blocked.md 2>/dev/null"
else
  log "branches:  git branch --list 'loop/*'"
  log "verify:    ./loop/verify.sh plans/<plan>.md"
fi
