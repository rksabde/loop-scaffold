#!/usr/bin/env bash
# loop/intake.sh — open-loop discovery. Scan inbox/ for initiative folders whose
# artifacts are new or changed, and turn each into DRAFT plans via the planner agent.
# Idempotent: a per-initiative content hash means unchanged folders are skipped, so
# this is cheap to poll and a change is the natural re-trigger.
#
#   ./loop/intake.sh            # scan $INBOX_DIR (default <repo>/inbox)
#   FORCE=1 ./loop/intake.sh    # re-plan even if unchanged
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/adapters/${LOOP_TOOL:-claude}.sh"

INBOX="${INBOX_DIR:-$SCAFFOLD_ROOT/inbox}"
[ -d "$INBOX" ] || { log "[intake] no $INBOX — nothing to do"; exit 0; }
mkdir -p "$SCAFFOLD_ROOT/loop/logs" "$SCAFFOLD_ROOT/plans"

# Skip-rule: is this dir machinery/non-initiative rather than a real initiative?
_skip() {
  case "$(basename "$1")" in .*|*-scaffold) return 0 ;; esac
  [ -f "$1/loop.conf" ] || [ -f "$1/install.sh" ] || [ -f "$1/loop/install.sh" ]   # has machinery
}

_hash() {  # content hash of an initiative's artifacts (excluding our marker)
  # `sort` makes it order-independent — `find -exec` output order isn't deterministic.
  find "$1" -type f -not -name '.intake.sha' -exec shasum {} \; 2>/dev/null \
    | sort | shasum | awk '{print $1}'
}

planned=0
for dir in "$INBOX"/*/; do
  dir="${dir%/}"; name="$(basename "$dir")"
  if _skip "$dir"; then log "[intake] skip '$name' (not an initiative)"; continue; fi
  h="$(_hash "$dir")"
  if [ "${FORCE:-0}" != "1" ] && [ -f "$dir/.intake.sha" ] && [ "$(cat "$dir/.intake.sha")" = "$h" ]; then
    continue   # unchanged
  fi
  log "[intake] initiative '$name' new/changed → planning (planner → frontier)"
  read -r -d '' prompt <<PROMPT || true
Use the planner subagent to plan the initiative in: $dir

Read EVERY artifact in that folder (markdown, PDFs, images/screenshots of decks, chat
exports, notes — use vision for images/PDFs). Decompose it into a small set of phases →
tasks and write one draft plan per task into the repo's plans/ directory, following the
format in plans/README.md. Number plans sequentially AFTER any that already exist in
plans/. Every plan is status: draft. Write ONLY under plans/.
PROMPT
  adapter_run planner "$prompt" "$SCAFFOLD_ROOT/loop/logs/intake-$name.json"
  if [ "${LOOP_DRYRUN:-0}" = "1" ]; then
    log "[intake] (dry-run) would plan '$name' — marker NOT written"
  else
    printf '%s' "$h" > "$dir/.intake.sha"
    log "[intake] '$name' planned (marker updated)"
  fi
  planned=$((planned+1))
done
log "[intake] done — $planned initiative(s) (re)planned"
