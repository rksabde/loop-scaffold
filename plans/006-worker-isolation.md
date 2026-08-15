# 006 — Parallel worker session-state isolation (investigate, then fix or bound)

status: draft
worktree: worker-isolation

## Goal (verifiable)
The "concurrent workers share ~/.claude → session corruption" risk (open since L6) is
either (a) DISPROVEN by test — worktree paths key sessions separately and parallel runs
are safe, documented as such — or (b) real, and fixed/bounded: per-worker isolation or
a safe MAX_PARALLEL default.

## Context
- Claude Code stores per-project session state keyed by cwd path; distinct worktree
  paths under $WORKTREE_DIR likely map to distinct project dirs. Shared files
  (~/.claude/config.json etc.) may still race on write.
- CLAUDE_CONFIG_DIR-per-worker is NOT a free fix: a fresh config dir has no auth.
- loop.conf ships MAX_PARALLEL=3 while AGENTS.md (claude-framework) still warns of
  corruption — shipping a warning and an unsafe default together is incoherent.

## Tasks
1. Test: 3 parallel headless `claude -p` runs in 3 worktrees of a throwaway repo,
   trivial disjoint plans, repeated a few times. Inspect exit codes, outputs, and
   ~/.claude for corruption (truncated JSON, lock errors in logs).
2. If safe → document in README ("parallel workers OK; sessions are path-keyed"),
   delete the stale warning from claude-framework AGENTS.md gotchas.
3. If unsafe → either implement isolation that preserves auth (e.g. seed
   CLAUDE_CONFIG_DIR from a template copy incl. credentials, per worker, cleaned after)
   or set MAX_PARALLEL=1 default with a loud comment; document which.

## Acceptance
- [ ] Test script committed under loop/tests/ (or documented one-liner in the plan) and run
- [ ] README states the verdict explicitly (safe / bounded) with the evidence one-liner
- [ ] loop.conf MAX_PARALLEL default + comment consistent with the verdict
