# LOOPS.md

> Active only when this repo's loop machinery has been activated (the `.loop-scaffold/`
> was promoted to `loop/` via `install.sh`). Agent-facing protocol.
> Humans: see the loop guide in `.loop-scaffold/README.md`.

## Loop protocol
This repo is driven by autonomous loops (see `loop/` and `plans/`).
- Work only the plan you are given; obey its `worktree` and scope Constraints.
- Never touch files outside the plan's stated scope, and never another plan's worktree.
- A plan is DONE only when every `## Acceptance` box verifies by command — not by assertion.
- Append a one-line note to `plans/PROGRESS.md` at each meaningful step.
- Prefer small, reversible commits.
- Keep the `## Commands` in `AGENTS.md` in sync with `LINT_CMD`/`TEST_CMD` in `loop.conf`.

## Agent roles (`.claude/agents/`)
- **researcher** — read-only recon (cheap, fan out wide). Delegate codebase exploration to it.
- **engineer** — the executor: smallest change that turns Acceptance green, in scope only.
- **verifier** — independent pre-merge auditor (strong model, read-only); re-runs every check.
Fan out the cheap read-only role (researcher); keep write/coordination roles bounded.
