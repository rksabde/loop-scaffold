# 001 — Docs truth sync (kill stale claims from earlier LLM passes)

status: done
worktree: docs-truth-sync

## Goal (verifiable)
Every doc in the scaffold describes the system as it IS today: no `/goal` evaluator,
no `CLAUDE_MODEL`/`VERIFIER_MODEL` vars, no `../wt-<slug>` sibling paths, no "codex is
a stub" claims. A `plans/README.md` exists (intake.sh's planner prompt references it).

## Constraints
- Docs + install.sh copy-list only. Do NOT change runtime behavior of any loop/*.sh.
- do not modify: loop/engine.sh, loop/adapters/**, loop/run-plan.sh, loop/verify.sh,
  loop/integrate.sh, loop/fleet.sh, loop/gate.sh, loop/intake.sh (except no edits at all)

## Tasks
- README.md: verification table row (gate → executor → verifier; no `/goal` mid layer);
  Token-control section → LOOP_ENGINE_*/.env routing; worktree cleanup path → `wt/` +
  WORKTREE_DIR; add integrate.sh/AUTO_INTEGRATE, schedule.sh, intake.sh to the loop
  table + quickstart; mention .env.
- plans/000-EXAMPLE.md: worktree comment → `$WORKTREE_DIR/<repo>-<slug>`; drop `/goal`.
- .env.example: codex is real (opencode still stub); failover chains EXIST now (example
  with `|`); fix scenario numbering; document AUTO_INTEGRATE/MAX_ATTEMPTS/MAX_REPLANS
  pointer to loop.conf.
- NEW plans/README.md: plan format spec (status lifecycle draft|ready|running|blocked|done,
  worktree slug, Goal/Constraints/Acceptance shape) — the file intake.sh already tells
  the planner to read. Add to install.sh copy list.
- LOOPS.md: note codex verifier is NOT tool-restricted read-only (sandbox only).

## Acceptance
- [ ] `grep -rn "/goal" README.md plans/000-EXAMPLE.md` → no matches
- [ ] `grep -rn "CLAUDE_MODEL\|VERIFIER_MODEL" README.md` → no matches
- [ ] `grep -rn '\.\./wt-' README.md plans/000-EXAMPLE.md .env.example` → no matches
- [ ] `grep -n "stub" .env.example` → only opencode called stub, not codex
- [ ] `test -f plans/README.md` and `grep -q "plans/README.md" loop/install.sh`
- [ ] `grep -q "AUTO_INTEGRATE" README.md`
