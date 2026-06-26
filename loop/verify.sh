#!/usr/bin/env bash
# loop/verify.sh — independent pre-merge audit of a plan's branch.
# Runs the 'verifier' subagent (strong model, read-only) which re-runs
# each Acceptance check itself rather than trusting the executor.
#
#   ./loop/verify.sh plans/002-auth-v2.md
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/adapters/${LOOP_TOOL:-claude}.sh"

plan="${1:?usage: verify.sh plans/NNN-name.md}"
slug="$(basename "$plan" .md)"
cd "$SCAFFOLD_ROOT"
mkdir -p loop/logs

git diff "${BASE_BRANCH:-main}...loop/$slug" > "loop/logs/$slug.diff" 2>/dev/null || true

# The 'verifier' role resolves to a protected frontier engine (engine.sh keeps it on
# real Anthropic even when the fleet default is cheap), so the auditor never grades
# itself with the cheap execution engine.
read -r -d '' prompt <<PROMPT || true
Use the verifier subagent.
Plan file contents:
$(cat "$plan")

The branch diff is saved at loop/logs/$slug.diff (also reproducible via
'git diff ${BASE_BRANCH:-main}...loop/$slug'). Run each Acceptance check
yourself and return the JSON verdict.
PROMPT

adapter_run verifier "$prompt" "loop/logs/$slug.verdict.json"
cat "loop/logs/$slug.verdict.json"
