#!/usr/bin/env bash
# loop/triage.sh — unattended entrypoint (cron / CI).
# Default behaviour: just run the fleet over ready plans (CLOSED loop).
#
# To make it an OPEN loop, add a discovery step here that WRITES new
# plans/NNN-*.md files (status: ready) before dispatch, e.g.:
#   - one plan per failing CI job
#   - one plan per GitHub issue labelled 'agent'
#   - one plan per TODO/FIXME cluster
# Then the loop never empties.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$SCAFFOLD_ROOT"

log "triage start"

# ── DISCOVERY (open-loop): inbox artifacts → DRAFT plans via the planner agent ──
# intake.sh scans inbox/ and writes status: draft plans for new/changed initiatives.
# Cheap when nothing changed (content-hash idempotent). Disable with INTAKE=0.
# The human gate is the draft→ready promotion: the fleet below runs ONLY 'ready'
# plans, so freshly-discovered drafts wait for review and never auto-execute.
if [ "${INTAKE:-1}" = "1" ] && [ -d "$SCAFFOLD_ROOT/inbox" ]; then
  bash loop/intake.sh
fi
# Other discovery sources (failing CI, labelled issues, TODO clusters) can be added here.

bash loop/fleet.sh   # runs 'status: ready' plans only — drafts wait for promotion
log "triage done"
