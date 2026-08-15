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
export LOOP_PLAN_SLUG="$slug"     # attributes loop/logs/calls.jsonl lines to this plan
repo="$SCAFFOLD_ROOT"
wt="$(worktree_path "$slug")"
branch="loop/$slug"
mkdir -p "$repo/loop/logs"

log "[$slug] worktree → $wt   branch → $branch"
git -C "$repo" worktree add -B "$branch" "$wt" "${BASE_BRANCH:-main}" 2>/dev/null \
  || git -C "$repo" worktree add "$wt" "$branch" 2>/dev/null \
  || log "[$slug] worktree already exists, reusing"

[ -z "$TIMEOUT_BIN" ] && log "[$slug] no timeout/gtimeout on PATH — running without a wall-clock kill switch (the \$-budget cap still applies)"

# If a prior attempt was rejected by the verifier, integrate.sh leaves its verdict here.
# Feed it back so this attempt fixes the SPECIFIC findings instead of starting blind.
feedback=""
fb="$repo/loop/logs/$slug.feedback"
if [ -s "$fb" ]; then
  feedback="

⚠️ A PREVIOUS ATTEMPT WAS REJECTED by the independent verifier. Do NOT start over —
fix exactly what it flagged below, then re-check every Acceptance box yourself:
$(cat "$fb")
"
fi

read -r -d '' prompt <<PROMPT || true
$(cat "$repo/$plan")
$feedback
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
  # The transcript rides INSIDE the commit it documents: the run's log is complete
  # here, so render it into the worktree BEFORE the harness commit picks it up.
  # (git maps commit↔transcript: `git show <sha> --stat` / `git log --diff-filter=A`.)
  tdir=".transcripts/$slug"; mkdir -p "$tdir"
  [ -f .transcripts/README.md ] || printf '%s\n' \
    "# .transcripts/ — committed LLM transcripts, per plan" \
    "Each work commit carries attempt-NN-engineer.md (the executor chat that produced it);" \
    "bookkeeping commits carry verify-NN-verifier.md + meta-NN.json (verdict + engine/cost)." \
    > .transcripts/README.md
  nn="$(printf '%02d' $(( $(ls "$tdir"/attempt-*-engineer.md 2>/dev/null | wc -l) + 1 )))"
  printf '%s' "$prompt" > "$repo/loop/logs/$slug.prompt"
  python3 "$repo/loop/transcript.py" "$repo/loop/logs/$slug.json" \
      --prompt "$repo/loop/logs/$slug.prompt" --role engineer \
      --title "$slug — attempt $nn (engineer)" > "$tdir/attempt-$nn-engineer.md" 2>/dev/null \
    || log "[$slug] transcript render failed (run continues)"
  [ "${TRANSCRIPT_RAW:-0}" = "1" ] && cp "$repo/loop/logs/$slug.json" "$tdir/attempt-$nn-engineer.raw.json"

  # Harness commits whatever the agent changed, so the branch carries a diff the
  # verifier can audit — reliable regardless of headless permission mode (which
  # auto-accepts edits but not `git commit`).
  git add -A
  if ! git diff --cached --quiet; then
    git commit -q -m "$slug: automated loop changes"
    log "[$slug] committed changes to $branch"
  fi
  # engine=/model=/cost= come from the engine call log (which LLM actually answered)
  printf -- '- %s exit=%s %s branch=%s engine=%s model=%s cost=%s\n' \
    "$slug" "$rc" "$(date +%FT%T)" "$branch" \
    "${ENGINE_LAST_ENGINE:--}" "${ENGINE_LAST_MODEL:--}" "${ENGINE_LAST_COST:--}" \
    >> "$repo/plans/PROGRESS.md"
  log "[$slug] finished exit=$rc  (log: loop/logs/$slug.json)"
  exit $rc
)
