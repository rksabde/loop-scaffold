# 014 — Worker quality upgrades enabled by the CLI flags (spec §5.3, P5)

status: done
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
- [x] Stub cycle (fake `adapter_invoke` emitting a schema-valid verdict): integrate reaches `done` with grep fallback code path NOT taken (log line proves JSON path)
- [x] Malformed verdict fixture → falls back to grep → still yields FAIL/ERROR, never a false PASS
- [x] `grep -rn "Use the .* subagent" lib/` → only the researcher delegation hint remains
- [ ] **DEFERRED** — Rendering a real `stream-json` fixture yields ≥2 assistant turns and ≥1 tool call in the markdown
- [x] Real cheap run: the `init` event in the raw stream lists no user-scope plugins/skills; verdict read via JSON; cost recorded in calls.jsonl
- [x] `adapter_is_limit` + budget-cap exclusion unit checks still pass against the split-out result file

## Notes
Depends on 010 and probes 009.1/.3/.4. Real-run boxes need a logged-in terminal.

## Progress
2026-10-01: DONE with REDUCED scope. Goal items 1 (typed verdict), 2 (role = the session) and
4 (slim context) are in. Two more fixes were added: the gate now exits 2, and stderr is split out
of the JSON log. **Goal item 3, "stream-json full transcripts", is DEFERRED to a follow-up plan.**
Its Acceptance box (the `stream-json` fixture render) stays unticked. Workers still use
`--output-format json`, and `transcript.py` renders only the final result.
Item 4 (`--setting-sources project --strict-mcp-config`) was already wired by plan 010.
Its check, "init event lists no user-scope plugins", already passed in probe 009.3 (spec §7.3:
plugins 2→0, MCP 1→0). It was seen again here: the init event of a `--agent engineer` worker
listed `plugins = [loop]` only.

Commits: `aa7616d` (gate exit 2), `8ff33ad` (stderr split + tolerant parsing), `f91fc36`
(role = the session), then the typed verdict + tests + this update (4/4). Each can be reverted on its own.

### Acceptance outputs (run from the repo root)
```
$ bash lib/tests/stub-suite.sh | tail -1            # 44 → 67 checks
stub-suite: 67 passed, 0 failed (67 checks)
$ bash lib/tests/init-migrate.sh | tail -1
init-migrate: 36 passed, 0 failed (36 checks)
$ grep -rn "Use the .* subagent" lib/ ; echo rc=$?
rc=1        # none left in lib/; the researcher delegation hint lives in plugin/agents/engineer.md:
$ grep -n "researcher. subagent" plugin/agents/engineer.md
14:3. Delegate read-only recon to the `researcher` subagent (agent type `loop:researcher`) rather
```
Stub checks behind the boxes (all PASS):
- `typed: integrate reaches done via structured_output (grep fallback NOT taken)`. It reads
  `.loop/logs/<slug>.verify.log`, which `integrate.sh` now writes (verify stderr is no longer `/dev/null`).
- `typed: malformed verdict → grep fallback → ERROR (never a false PASS)`
- `typed: PASS contradicted by a failed item → FAIL; feedback names that item`
- `typed: feedback file lists the failed items (check + evidence), not raw prose`
- `claude: stderr split → <log>.stderr; the .json log is pure JSON`
- `claude: call log model_actual populated despite the stderr line`
- `claude: adapter_is_limit sees a limit reported only on stderr; budget cap still excluded`
- `claude: engineer runs --agent engineer, without --json-schema` /
  `claude: verifier runs --agent verifier --json-schema <verdict.schema.json contents>`.
  These run the REAL claude adapter against a fake `claude` binary on PATH that records argv,
  prints a stderr line, and returns a JSON result.
- `gate: … (TEST_CMD=false → exit 2)`, `gate: failure output … goes to STDERR`,
  `gate: no-op is instant (<1s) and writes no heartbeat without LOOP_WORKER`

### Real runs (Claude Code 2.1.233, subscription token from ~/.config/claude/oauth-token)
**Gate exit 2 (engineer, frontier:mid = sonnet, via `adapter_run`).** Setup: scratch repo,
`TEST_CMD='test -f must-exist.txt'`, prompt "Create hello.txt containing hi using the Write tool;
if a hook reports a failing check, fix it by creating whatever file it says is missing, then reply
done". Result: `hello.txt` and `must-exist.txt` both exist, `.loop/gate-fired` was written,
`done` came back in 5 turns for $0.096 on `claude-sonnet-5`. Plain exit 2 with stderr was enough;
the JSON `decision:block` form was not needed. This is recorded in the `lib/gate.sh` header.

**Typed verdict end-to-end.** Setup: scratch repo, plan Acceptance `test -f hello.txt`, `hello.txt`
committed on `loop/001-hello`. Command: `LOOP_ENGINE_VERIFIER=frontier:low loop verify plans/001-hello.md`:
```
[engine] verifier → frontier:low  (claude --model haiku [subscription])
[verify] verdict via structured_output: PASS
[verify] 001-hello verdict=PASS        rc=0
calls.jsonl: "role": "verifier", "engine": "frontier:low", "exit": 0, "kind": "run",
  "model_actual": "claude-haiku-4-5-20251001", "cost_usd": 0.0184445, "turns": 4
structured_output: {"items": [{"check": "test -f hello.txt", "pass": true, ...},
  {"check": "Scope: only hello.txt modified", "pass": true, ...}],
  "plan": "001-hello", "verdict": "PASS", "scope_ok": true}
```
It took two fixes to get there. Both were found by real runs that the stub suite could not catch:
1. `--json-schema is not a valid JSON Schema: no schema with key or ref
   "https://json-schema.org/draft/2020-12/schema"`. Claude Code's validator does not know the
   2020-12 meta-schema. `templates/verdict.schema.json` now uses draft-07 (it uses no 2020-only features).
2. The run then succeeded, but `structured_output` was null and the verdict fell back to grep.
   A direct probe found the cause. Under `--agent verifier`, the role's `tools:` allowlist is
   enforced: the init tools were `['Bash','Read']`, and `StructuredOutput` was missing. Without
   `--agent`, the model called `StructuredOutput`. `verifier.md` now lists `StructuredOutput`.
   Stub regression checks now guard both fixes.

### Decisions the plan did not specify
- Schema plumbing: `verify.sh` sets `LOOP_JSON_SCHEMA=<schema file>` on the verifier call.
  The claude adapter reads that file and passes its *contents* (`--json-schema` takes inline JSON,
  not a path). If the file is unreadable, it logs and runs without the schema. Codex ignores the variable.
- Session roles = `engineer verifier planner` (`ENGINE_SESSION_ROLES` in engine.sh), and only
  when `plugin/agents/<role>.md` exists. `researcher` (and any unknown role) gets no `--agent`.
  `adapter_describe` and the dry-run line are unchanged (they do not mention `--agent`), so the call-log exec strings stay stable.
- Engineer tools: `Agent(loop:researcher)`. Probed: `Agent(researcher)` left "Available agents:"
  EMPTY, because plugin agents are typed `loop:<name>`. The qualified form spawned the researcher.
  The engineer.md hint now names the type.
- The verdict is never a false PASS. A structured PASS whose own `items` contain a failure, or
  whose `scope_ok` is false, is downgraded to FAIL. The grep fallback now checks FAIL before PASS.
  Malformed `structured_output` (missing, or `verdict` not PASS/FAIL) → grep fallback.
- Feedback format (from structured_output): `Verifier verdict: FAIL (scope_ok: …)`, then
  `Failed checks:` with `- <check>` / `  evidence: <evidence>` lines, plus a scope line when
  `scope_ok` is false. Fallbacks, in order: raw `.result` text, then the whole log.
- Codex role prompt: `<role body>\n\n---\n\n<task prompt>`. Codex keeps `2>&1` and the grep
  verdict (the stderr split covers the claude adapter only, per scope).
- `claude_result()` lives in `lib/transcript.py` and is imported by the engine.sh call log and by
  lib.sh's verdict helpers. All use `sys.dont_write_bytecode`, so nothing is written to `$LOOP_HOME/lib/__pycache__`.
- Commits 1–3 were staged straight into the index from built intermediate file states, so the
  working tree was never reset. Each was checked by exporting the index (`git checkout-index`) and
  running the stub suite there. All green except `cli: version prints a sha`, which is expected
  because an export is not a git checkout. Tests for items 2–3 land in commit 4.
