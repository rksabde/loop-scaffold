# 007 — Engine call log: record the ACTUAL LLM behind every worker call

status: done
worktree: engine-call-log

## Goal (verifiable)
Every `adapter_run` appends one JSON line to `loop/logs/calls.jsonl` recording what was
REQUESTED and what ACTUALLY answered:
`{ts, plan, role, tool, engine (provider:tier), model_requested, model_actual, cost_usd,
turns, duration_ms, exit}`. PROGRESS.md lines gain `engine=<prov:tier> model=<actual>
cost=<usd>` so a human reading history sees which LLM (claude-opus-5, GLM 5.2,
qwen3.6:27b, gpt-5.x…) did each piece of work.

## Context
- Requested model: the adapter already computes it (`_claude_model` / `_codex_flags`).
- ACTUAL model: parse from the result log — claude JSON has `modelUsage` (keys are real
  model ids, values have costUSD) + `total_cost_usd`, `num_turns`, `duration_ms`;
  codex JSONL carries model info in its events. Actual can differ from requested
  (aliases like `opus` resolve to a dated id; ccr routes to whatever the shim picked) —
  that's the point of logging both.
- Depends on plan 005: the log hook goes in the SHARED adapter_run walk (one place),
  with a small per-tool `adapter_call_meta <logfile>` extractor (python3 stdlib, no jq).
- Plan slug: pass through from callers (run-plan/verify/integrate/intake know it);
  fall back to "-" for ad-hoc calls. Keep the contract backward-compatible: slug via
  env `LOOP_PLAN_SLUG`, not a new positional arg.
- calls.jsonl lives under loop/logs/ (gitignored) — durable copies ride into git via
  plan 008's per-commit transcript meta.

## Acceptance
- [ ] Real cheap run (one tiny plan, frontier:low): `loop/logs/calls.jsonl` gains a line;
      `python3 -c "import json;json.loads(open('loop/logs/calls.jsonl').readlines()[-1])"` exits 0
- [ ] That line's `model_actual` matches the `modelUsage` key in the raw result log
- [ ] PROGRESS.md line for the run contains `engine=` and `model=` and `cost=`
- [ ] LOOP_DRYRUN=1 also logs a line with `"dryrun": true` and no cost
- [ ] Works under codex adapter dry-run (model_requested filled, no crash)
- [ ] `bash -n` clean on engine.sh + adapters
