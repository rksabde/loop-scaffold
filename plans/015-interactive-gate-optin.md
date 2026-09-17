# 015 — Interactive gate: opt-in per repo, fast subset, code paths only (spec §8.2)

status: draft
worktree: interactive-gate-optin

## Goal (verifiable)
ONE gate hook (the plugin's `hooks/hooks.json` → `lib/gate.sh`) serves both contexts:
- **Worker** (`LOOP_WORKER=1`): unchanged — full `LINT_CMD`/`TEST_CMD`/`TYPECHECK_CMD`.
- **Interactive** (plugin installed, no `LOOP_WORKER`): fires ONLY when the session's git
  toplevel has a `loop.conf` with `GATE_INTERACTIVE=1`; runs `GATE_INTERACTIVE_CMD` (fast
  subset, e.g. lint + typecheck; empty → falls back to `LINT_CMD` only, never tests); skips
  when the edited file (from the hook's stdin JSON `tool_input.file_path`) matches
  `GATE_SKIP_GLOBS` (default `*.md plans/* inbox/* .transcripts/*`).
- Anything else → exit 0 silently in <50ms (no `loop.conf`, flag off, skipped path).
`templates/loop.conf` documents `GATE_INTERACTIVE=0`, `GATE_INTERACTIVE_CMD=""`, `GATE_SKIP_GLOBS`.

## Constraints
- `lib/gate.sh`, `plugin/hooks/hooks.json`, `templates/loop.conf`, README only.
- No second hook anywhere (a project-settings hook would double-fire inside workers).
- stdin JSON parsed with python3 (no jq dependency); missing/garbled stdin → treat as "no path", don't crash.

## Acceptance (drive `lib/gate.sh` directly with fixture stdin + env)
- [ ] no `loop.conf` in toplevel → exit 0, no command run (marker file absent)
- [ ] `GATE_INTERACTIVE=0`, no `LOOP_WORKER` → exit 0, no command run
- [ ] `GATE_INTERACTIVE=1` + edit of `src/a.ts` → runs `GATE_INTERACTIVE_CMD` only (marker proves TEST_CMD did NOT run); failing cmd → non-zero
- [ ] `GATE_INTERACTIVE=1` + edit of `plans/001-x.md` → exit 0, no command run
- [ ] `LOOP_WORKER=1` → full gate regardless of `GATE_INTERACTIVE`; path filter NOT applied
- [ ] `grep -c gate plugin/hooks/hooks.json` → 1 (single hook)

## Notes
Depends on 010. Default stays OFF — flip per repo when wanted.
