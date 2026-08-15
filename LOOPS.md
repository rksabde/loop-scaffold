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
- **planner** — intake/PM: turns inbox artifacts into plans, and rewrites a plan that
  keeps failing verification (the `integrate.sh` replan step). Writes `plans/` only.
Fan out the cheap read-only role (researcher); keep write/coordination roles bounded.

## Closed loop & self-correction (`loop/integrate.sh`, opt-in via `AUTO_INTEGRATE=1`)
A FAIL verdict is not handed to the human — the loop fixes itself, bounded:
1. **Inner gate** (`gate.sh`) corrects the executor turn-by-turn within one session.
2. **Tactical retry** — on a verifier FAIL, the executor re-runs up to `MAX_ATTEMPTS`,
   fed the verifier's own verdict as the fix list.
3. **Strategic retry** — still failing, the *planner* rewrites the plan up to
   `MAX_REPLANS`, then the executor retries the improved plan.
4. **Escalate** — both caps exhausted → `status: blocked` + `plans/<slug>.blocked.md`.
   Blocked plans are the ONLY failures a human ever reviews.
On PASS the branch is merged into `BASE_BRANCH`, the plan flips to `status: done`, and the
worktree is cleaned. Caps live in `loop.conf`; total executor runs ≤ `(MAX_REPLANS+1)*MAX_ATTEMPTS`.
