#!/usr/bin/env bash
# loop/run-plan.sh — execute ONE plan to its verifiable goal, in an
# isolated git worktree, headless, with hard budget caps.
#
#   ./loop/run-plan.sh plans/002-auth-v2.md
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require git
# engine seam: LOOP_TOOL selects the adapter (claude | codex | opencode)
source "$(dirname "$0")/adapters/${LOOP_TOOL:-claude}.sh"

plan="${1:?usage: run-plan.sh plans/NNN-name.md}"
slug="$(basename "$plan" .md)"
repo="$SCAFFOLD_ROOT"
wt="$repo/../wt-$slug"
branch="loop/$slug"
mkdir -p "$repo/loop/logs"

log "[$slug] worktree → $wt   branch → $branch"
git -C "$repo" worktree add -B "$branch" "$wt" "${BASE_BRANCH:-main}" 2>/dev/null \
  || git -C "$repo" worktree add "$wt" "$branch" 2>/dev/null \
  || log "[$slug] worktree already exists, reusing"

[ -z "$TIMEOUT_BIN" ] && log "[$slug] no timeout/gtimeout on PATH — running without a wall-clock kill switch (the \$-budget cap still applies)"

read -r -d '' prompt <<PROMPT || true
$(cat "$repo/$plan")

Work ONLY within this worktree and the plan's stated scope. Make the SMALLEST change
that satisfies every \`## Acceptance\` check. As soon as all acceptance commands pass:
  1. Commit your work on this branch: \`git add -A && git commit -m '<plan slug>: <summary>'\`.
  2. STOP immediately — do not explore, refactor, web-search, or make unrelated changes.
Do not edit plans/PROGRESS.md (the harness records progress for you).
PROMPT

(
  cd "$wt" || exit 1
  # The 'engineer' role's engine is resolved from .env (LOOP_ENGINE_ENGINEER / _DEFAULT).
  adapter_run engineer "$prompt" "$repo/loop/logs/$slug.json"
  rc=$?
  # Harness commits whatever the agent changed, so the branch carries a diff the
  # verifier can audit — reliable regardless of headless permission mode (which
  # auto-accepts edits but not `git commit`).
  git add -A
  if ! git diff --cached --quiet; then
    git commit -q -m "$slug: automated loop changes"
    log "[$slug] committed changes to $branch"
  fi
  printf -- '- %s exit=%s %s branch=%s\n' \
    "$slug" "$rc" "$(date +%FT%T)" "$branch" >> "$repo/plans/PROGRESS.md"
  log "[$slug] finished exit=$rc  (log: loop/logs/$slug.json)"
  exit $rc
)
