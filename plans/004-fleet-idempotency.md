# 004 — Fleet idempotency (don't re-run finished work)

status: done
worktree: fleet-idempotency

## Goal (verifiable)
Running `./loop/fleet.sh` twice in a row does not re-execute plans that already ran.
Manual mode (AUTO_INTEGRATE=0) currently re-dispatches every `status: ready` plan on
every invocation — status never flips, no branch-exists check → duplicate spend.

## Design
- In manual mode, a plan that has been executed has a `loop/<slug>` branch. fleet.sh
  skips ready plans whose branch already exists, with a log line telling the human:
  `verify + merge it, or delete the branch / set RETRY=1 to re-run`.
- `RETRY=1 ./loop/fleet.sh` (or per-plan `./loop/run-plan.sh plans/NNN.md`) forces re-run.
- Closed-loop mode already flips status (running→done/blocked) — after plan 003 the
  flip is committed, so no change needed there beyond respecting the same skip rule.

## Constraints
- fleet.sh only (+ a README note). No changes to run-plan.sh semantics.

## Acceptance
- [ ] Stub test: fleet run #1 executes plan; fleet run #2 logs skip, executor stub NOT
      invoked (trace file shows one run)
- [ ] Stub test: `RETRY=1` fleet run re-invokes executor
- [ ] `bash -n loop/fleet.sh` exit 0
