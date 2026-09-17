# 009 — Probe the CLI unknowns the new design depends on (spec §7)

status: blocked
worktree: probe-cli-unknowns

## Goal (verifiable)
`loop/tests/probe-cli.sh` exists and, run from a LOGGED-IN terminal, answers the six open
questions in `docs/SPEC-distribution-and-harness.md` §7 with a PASS/FAIL line each plus the
observed detail. The spec's §7 is rewritten from "open questions" to "verified facts"
(with fallbacks chosen where a probe fails).

## Probes (each builds a throwaway plugin dir under mktemp; haiku; "reply pong"-sized prompts)
1. `--plugin-dir P --agent <name>`: does a plugin-provided agent resolve as `engineer` or
   `<plugin>:engineer`? Detect by a marker string in the agent's prompt echoed in the reply.
2. `hooks/hooks.json` in a `--plugin-dir` plugin fires under `-p` and `${CLAUDE_PLUGIN_ROOT}`
   expands (hook touches a marker file after a Write).
3. `--setting-sources project`: subscription auth still works AND user-scope plugins/skills
   are absent (compare `init` event tool/skill/plugin lists with vs without the flag via
   `--output-format stream-json --verbose`).
4. `--json-schema` + `--output-format stream-json`: print the key path where the validated
   object lands in the final `result` event.
5. `--bare` + `ANTHROPIC_BASE_URL` (ccr) + dummy `ANTHROPIC_API_KEY`: accepted? (skip with a
   note if ccr/Ollama unreachable).
6. Native Anthropic endpoints: `POST /v1/messages` on `$OLLAMA_HOST`, and OpenRouter's
   Anthropic-compatible base URL with the key from `~/.config/openrouter/key` — HTTP status
   + whether a text block comes back. NEVER print the key.

## Constraints
- New files only: `loop/tests/probe-cli.sh`; edits only to `docs/SPEC-distribution-and-harness.md` §7.
- Total spend < $0.25. Cleans up its temp dirs. Diagnoses auth failure inline (like
  `parallel-workers.sh`) instead of reporting false FAILs.

## Acceptance
- [ ] `bash -n loop/tests/probe-cli.sh` exits 0
- [ ] `./loop/tests/probe-cli.sh` prints exactly six `PROBE n:` result lines
- [ ] `grep -c "Open questions" docs/SPEC-distribution-and-harness.md` → 0 (section retitled to verified facts)
- [ ] `grep -q "sk-or-v1-" <(./loop/tests/probe-cli.sh 2>&1)` finds nothing (no key leakage)

## Notes
HUMAN: must be run from your own terminal — nested/sandboxed contexts fail "Not logged in".
HUMAN (independent): flip `rksabde/loop-scaffold` to public (history scanned 2026-09-17: 0
key-shaped hits) — unblocks the CI clone step in 013/014.
Blocks: 010 (adapter flags depend on probes 1–3), 014 (probes 3–4), 016 (probes 5–6).

## Progress (2026-09-17)
- `loop/tests/probe-cli.sh` SHIPPED. Verified here: `bash -n`; probe plugin passes
  `claude plugin validate`; analyzer unit-tested on fixtures (result/err/none, marker, init
  counts, schema path, Messages-API body); preflight-abort path + probe-6 failure path
  exercised end-to-end (exactly six PROBE lines, zero key leakage).
- BLOCKED on a human terminal run (sandbox has no login / no LAN DNS):
  `./loop/tests/probe-cli.sh` → paste the PROBE lines; then §7 of the spec gets rewritten
  as verified facts and 010 is finalized.
