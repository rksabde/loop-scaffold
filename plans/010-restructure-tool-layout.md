# 010 — Restructure into a machine-installed tool (`bin/ lib/ adapters/ plugin/ templates/`)

status: draft
worktree: restructure-tool-layout

## Goal (verifiable)
The scaffold is a TOOL, not project content (spec §5.1–5.3):
- `bin/loop` single entrypoint dispatching `fleet|run|verify|integrate|intake|triage|schedule|doctor|self-update|version`.
- `lib/` holds today's `loop/*.sh` + `transcript.py` (logic unchanged); `adapters/` moves up one level.
- `plugin/` is a valid Claude Code plugin: `.claude-plugin/plugin.json`, `agents/{engineer,verifier,researcher,planner}.md`
  (moved from `.claude/agents/`), `hooks/hooks.json` (PostToolUse → `lib/gate.sh`).
- `templates/` holds what `loop init` will write: `loop.conf`, `.env.example`,
  `plans/{README,000-EXAMPLE,PROGRESS}.md`, `ci/loop.yml`, `verdict.schema.json`.
- `lib.sh` splits `SCAFFOLD_ROOT` into `LOOP_HOME` (realpath of `bin/loop`/..) and
  `LOOP_PROJECT_ROOT` (main checkout = first entry of `git worktree list --porcelain`);
  both exported to workers. Runtime dirs move to `$LOOP_PROJECT_ROOT/.loop/{logs,state}`.
- claude adapter attaches roles+gate per call: `--plugin-dir "$LOOP_HOME/plugin"` and sets
  `LOOP_WORKER=1`. Gate reads `loop.conf` from the worktree's own toplevel.
- `adapters/opencode.sh` deleted (spec §8.3); `LOOP_TOOL=opencode` fails with a clear message.

## Constraints
- Behavior-preserving refactor: no change to plan format, status lifecycle, merge lock,
  retry/replan caps, call-log schema, transcript naming.
- Prompts keep "Use the X subagent" wording here (role-as-session is plan 014) — agent
  names adjusted only if probe 009.1 shows plugin agents are namespaced.
- Do not touch other repos. Old vendored installs must keep working untouched.
- `install.sh` stays until 011 replaces it (may be broken by the move — then delete it here
  and note it; do not leave a half-working installer).

## Acceptance
- [ ] `test -x bin/loop && bin/loop version` prints a version; `bin/loop bogus` exits 2 with usage
- [ ] `claude plugin validate plugin/` exits 0
- [ ] `test ! -e adapters/opencode.sh && test ! -d .claude/agents && test ! -d loop`
- [ ] From a scratch repo containing ONLY `loop.conf` + `plans/001-x.md` (no machinery):
      `LOOP_DRYRUN=1 /abs/path/bin/loop fleet` resolves engines and logs a DRYRUN line; `.loop/logs/calls.jsonl` gains a line
- [ ] Stub suites re-run green against the new layout (port to `lib/tests/`): parallel merge
      race, kill -9 → sweep, blocked bookkeeping, fleet skip/RETRY, DRY dry-run diff, call-log, transcripts cycle
- [ ] Called from inside a worktree, `LOOP_PROJECT_ROOT` still resolves to the main checkout
- [ ] `for f in bin/loop lib/*.sh adapters/*.sh; do bash -n "$f"; done` clean

## Notes
Depends on 009 (probes 1–3). Blocks 011–016.
Stub-suite pattern that works in the sandbox: one foreground script, internal `& wait`, no
disowned jobs, outputs to files (see the 003/004 debugging notes in git history).
