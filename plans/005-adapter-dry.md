# 005 — Adapter DRY: one chain-walk, thin adapters

status: draft
worktree: adapter-dry

## Goal (verifiable)
The engine-chain walk (parse chain → skip unavailable/cooling → invoke → detect
provider limit → cooldown + failover) lives ONCE, in `loop/engine.sh`, as the shared
`adapter_run`. Each `loop/adapters/<tool>.sh` provides only the tool-specific parts:
`engine_available <prov>`, `adapter_invoke <prov> <tier> <prompt> <logfile>`,
`adapter_is_limit <logfile>`, `adapter_retry_after <logfile>` (optional).
Today ~40 lines of the walk are copy-pasted in claude.sh AND codex.sh — the exact
duplication that breeds drift when different LLMs edit one copy.

## Context
- `engine_split()` in engine.sh is dead code (adapters inline their own split) — use it
  in the shared walk or delete it.
- DRYRUN handling and the "chain exhausted" log also duplicate — move into the shared walk.
- This plan blocks 007 (engine-call-log): the call-log hook should be written once in
  the shared walk, not per adapter.

## Constraints
- Contract stays: `adapter_run <role> <prompt> <logfile>` callable exactly as today from
  run-plan.sh / verify.sh / intake.sh / integrate.sh — zero call-site changes.
- opencode.sh stays a stub but must still fail gracefully under the new shape.
- No behavior change: same logs, same cooldown semantics, same exit codes.

## Acceptance
- [ ] `grep -c "engine_chain_for_role" loop/adapters/claude.sh loop/adapters/codex.sh` → 0 in each
      (walk no longer in adapters)
- [ ] `grep -q "adapter_invoke" loop/adapters/claude.sh && grep -q "adapter_invoke" loop/adapters/codex.sh`
- [ ] LOOP_DRYRUN=1 resolution matrix unchanged: dry-run `adapter_run engineer|verifier`
      under claude prints same engine/model lines as before refactor (capture before/after)
- [ ] Cooldown unit checks still pass: limit-detect excludes budget cap; cooling provider
      skipped; retry-after parsed (re-run the L9 unit tests)
- [ ] `bash -n` clean on engine.sh + all three adapters
