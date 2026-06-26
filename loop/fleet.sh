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

log "dispatching $(echo "$ready" | wc -l | tr -d ' ') plan(s), -P ${MAX_PARALLEL:-3}:"
echo "$ready" >&2

echo "$ready" | xargs -P "${MAX_PARALLEL:-3}" -I{} bash loop/run-plan.sh {}

log "fleet done."
log "branches:  git branch --list 'loop/*'"
log "verify:    ./loop/verify.sh plans/<plan>.md"
