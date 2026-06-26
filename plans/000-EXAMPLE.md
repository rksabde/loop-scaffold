# 000 — EXAMPLE (copy me to start a new plan)

status: draft          # draft | ready | running | blocked | done
worktree: example      # short slug; becomes ../wt-000-EXAMPLE and branch loop/000-EXAMPLE

## Goal (verifiable)
<!-- A measurable END STATE, not a process. The /goal evaluator + verifier
     check against THIS, so make every clause runnable. -->
e.g. All call sites use `authv2.*`; `npm test` exits 0; `rg authv1 src/` returns nothing.

## Constraints
- do not modify: billing/**, infra/**
- stop after 25 turns or 30 minutes

## Acceptance
- [ ] `npm test` exits 0
- [ ] `rg authv1 src/` returns no matches
- [ ] `npm run typecheck` clean

## Notes
<!-- links, context, gotchas the agent should read first -->
