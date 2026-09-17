# 014 — Worker quality upgrades enabled by the CLI flags (spec §5.3, P5)

status: draft
worktree: worker-quality-upgrades

## Goal (verifiable)
Four independent upgrades to how the claude adapter runs a worker:
1. **Typed verdict.** verify runs with `--json-schema templates/verdict.schema.json`
   (`{plan, verdict: PASS|FAIL, scope_ok, items:[{check, pass, evidence}]}`); `plan_verdict`
   reads the validated object; the grep survives only as the fallback for Codex / parse failure.
   The retry feedback file is built from failed `items[]`, not raw prose.
2. **Role = the session.** engineer/verifier/planner run as `--agent <role>` (name form per
   probe 009.1; fallback `--append-system-prompt-file` + `--tools`). Prompts drop
   "Use the X subagent". `researcher` remains a real subagent the engineer can fan out to.
3. **Full transcripts.** workers use `--output-format stream-json --verbose`; the final
   `result` event is split out to the existing `<slug>.json` (call-log + limit detection keep
   working unchanged); `transcript.py` renders every assistant/tool turn from the stream.
4. **Slim, deterministic context.** workers pass `--setting-sources project --strict-mcp-config`
   so the human's user-scope plugins/skills/MCP servers are not loaded (only if probe 009.3
   confirms subscription auth survives).

## Constraints
- claude adapter + verify/run-plan prompts + `transcript.py` + `lib.sh::plan_verdict` only.
- Codex path must keep working (grep verdict, JSONL transcript rendering untouched).
- Each upgrade behind its own commit so one can be reverted alone.

## Acceptance
- [ ] Stub cycle (fake `adapter_invoke` emitting a schema-valid verdict): integrate reaches `done` with grep fallback code path NOT taken (log line proves JSON path)
- [ ] Malformed verdict fixture → falls back to grep → still yields FAIL/ERROR, never a false PASS
- [ ] `grep -rn "Use the .* subagent" lib/` → only the researcher delegation hint remains
- [ ] Rendering a real `stream-json` fixture yields ≥2 assistant turns and ≥1 tool call in the markdown
- [ ] Real cheap run: the `init` event in the raw stream lists no user-scope plugins/skills; verdict read via JSON; cost recorded in calls.jsonl
- [ ] `adapter_is_limit` + budget-cap exclusion unit checks still pass against the split-out result file

## Notes
Depends on 010 and probes 009.1/.3/.4. Real-run boxes need a logged-in terminal.
