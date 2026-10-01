# AGENTS.md — loop-scaffold (the `loop` tool)

> Canonical instructions for ALL coding agents (Claude Code, Codex). `CLAUDE.md` is just
> `@AGENTS.md`. Keep this file lean. Design: `docs/SPEC-distribution-and-harness.md`.

## Project
A machine-installed bash tool (`bin/loop`) that runs self-correcting agent loops over a
project's `plans/` in git worktrees. Bash + python3 stdlib only; no build step.

## Layout
- `bin/loop` — entrypoint/dispatcher. `lib/` — harness scripts (`lib.sh` path model:
  `LOOP_HOME` = this clone, `LOOP_PROJECT_ROOT` = the target repo's main checkout).
- `adapters/` — `claude.sh`, `codex.sh` (engine seam; chain walk lives in `lib/engine.sh`).
- `plugin/` — Claude Code plugin attached per worker (`agents/` roles, `hooks/` → `lib/gate.sh`).
- `templates/` — what `loop init` writes into projects (+ `LOOPS.md`, injected into workers).
- `plans/` — THIS repo's own development plans (`templates/plans/README.md` = format).
- Runtime state of any project the tool runs in: `<project>/.loop/` (never `loop/`).

## Commands
- test: `bash lib/tests/stub-suite.sh` (stubbed LLM, ~10 s, no spend)
- lint: `for f in bin/loop lib/*.sh adapters/*.sh lib/tests/*.sh; do bash -n "$f"; done`
- plugin: `claude plugin validate plugin/`

## Conventions
- Never write project content into this repo, nor tool files into projects.
- Never print or pass secrets as argv; token/key files are read into env per call only.
- Commit with `--no-verify` (the global secret hook false-positives on variable names).
