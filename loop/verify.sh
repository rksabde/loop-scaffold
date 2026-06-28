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

# Audit IN a checkout of the branch (detached, so it coexists with the executor's
# worktree) — acceptance commands then run against the branch's actual state, not main.
wt="$(worktree_path "verify-$slug")"
git worktree remove --force "$wt" 2>/dev/null || true
git worktree add --detach "$wt" "loop/$slug" >/dev/null 2>&1 \
  || { log "[verify] cannot check out loop/$slug"; exit 1; }

# The 'verifier' role resolves to a protected frontier engine (engine.sh keeps it on
# real Anthropic even when the fleet default is cheap), so the auditor never grades
# itself with the cheap execution engine.
read -r -d '' prompt <<PROMPT || true
Use the verifier subagent. You are in a CHECKOUT of branch loop/$slug (this working dir).
Plan file contents:
$(cat "$plan")

Run each \`## Acceptance\` check HERE. For scope, judge ONLY the committed diff vs
${BASE_BRANCH:-main} (\`git diff ${BASE_BRANCH:-main}...loop/$slug\`, saved at
$SCAFFOLD_ROOT/loop/logs/$slug.diff) — IGNORE generated/untracked files (e.g. __pycache__,
*.pyc, build output) created by running the checks. Return the JSON verdict.
PROMPT

# The verifier must actually RUN the acceptance commands (not just inspect), or "trust
# nothing" is hollow. It is read-only by tool restriction (Bash/Read/Grep/Glob — no
# Edit/Write), and runs in an ephemeral detached worktree, so bypassPermissions lets it
# EXECUTE checks while still being unable to modify the repo. (Codex: workspace-write
# already allows running commands.)
vfile="$SCAFFOLD_ROOT/loop/logs/$slug.verdict.json"
( cd "$wt" && PERMISSION_MODE=bypassPermissions CODEX_SANDBOX=workspace-write \
    adapter_run verifier "$prompt" "$vfile" )
git worktree remove --force "$wt" 2>/dev/null || true
cat "$vfile"

# Make the verdict machine-readable so the closed loop (integrate.sh) can act on it.
# Exit code is the SIGNAL: 0=PASS, 1=FAIL, 2=ERROR (couldn't read a verdict). The raw
# auditor result is also dropped at <slug>.feedback so a retry executor sees exactly
# what was wrong, in the auditor's own words.
verdict="$(plan_verdict "$vfile")"
log "[verify] $slug verdict=$verdict"
case "$verdict" in
  PASS) exit 0 ;;
  FAIL) python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' \
          "$vfile" 2>/dev/null > "$SCAFFOLD_ROOT/loop/logs/$slug.feedback" || \
          cp "$vfile" "$SCAFFOLD_ROOT/loop/logs/$slug.feedback"
        exit 1 ;;
  *)    exit 2 ;;
esac
