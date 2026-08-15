# Loop scaffold

Self-correcting agent loops layered on the `AGENTS.md` / `plans/` structure.
Closed loops (stop at verifiable acceptance), fanned out across **git worktrees**,
runnable **by hand** and **unattended** (launchd/cron / GitHub Actions). Tool-agnostic:
Claude Code and Codex are wired (OpenCode is a stub); all read the same `AGENTS.md`.

## The loop, mapped to files
| Loop part | Where |
|---|---|
| Goal | `plans/NNN-*.md` → `## Acceptance` (must be checkable by command) |
| Actions | bash / edits / MCP, gated by `.claude/settings.json` → `loop/gate.sh` |
| Verification | gate (inner, every edit) → executor stops at acceptance → `verifier` (pre-merge audit) |
| Decision | `loop/integrate.sh` (opt-in `AUTO_INTEGRATE=1`): merge on PASS, self-correct on FAIL |
| Memory | `AGENTS.md` (stable) + plan `status:` + `plans/PROGRESS.md` (harness-owned episodic log) |
| Discovery | `loop/intake.sh`: `inbox/` artifacts → draft plans via the planner agent |
| Trigger | `loop/fleet.sh` (manual) / `loop/triage.sh` via `loop/schedule.sh` (launchd/cron) or CI |

## Quickstart
```bash
# 1. drop into an existing repo (non-destructive)
./loop/install.sh /path/to/your/repo
cd /path/to/your/repo

# 2. set your stack's commands (the ONLY required edit)
$EDITOR loop.conf          # LINT_CMD, TEST_CMD, (TYPECHECK_CMD)
cp .env.example .env       # optional: engine routing (which LLM per role), LOOP_TOOL

# 3. write a plan (see plans/README.md for the format)
cp plans/000-EXAMPLE.md plans/001-thing.md
$EDITOR plans/001-thing.md # set status: ready + verifiable Acceptance

# 4a. manual: fleet executes, you audit + merge
./loop/fleet.sh
./loop/verify.sh plans/001-thing.md   # independent pre-merge audit

# 4b. closed loop: fleet executes, verifies, merges on PASS, self-corrects on FAIL
#     (set AUTO_INTEGRATE=1 in loop.conf)   — or run one plan through it:
./loop/integrate.sh plans/001-thing.md

# 4c. unattended: per-repo scheduler (macOS launchd / Linux cron)
./loop/schedule.sh install 09:00
# or commit the CI workflow install.sh placed at .github/workflows/loop.yml
```

## Three nested checks (why loops don't drift)
1. **gate.sh** runs after every edit; a failure is fed back into the same turn → the agent fixes before continuing.
2. **The executor itself** works agentically to the plan's `## Acceptance` and stops at `end_turn`; `run-plan.sh` then commits its branch.
3. **`verifier`** (strong model, read-only under Claude) re-runs every acceptance check in a
   detached checkout of the branch — trusts nothing the executor claimed.

With `AUTO_INTEGRATE=1` a FAIL verdict doesn't stop at a report: the executor retries with
the verifier's findings (≤ `MAX_ATTEMPTS`), then the planner rewrites the plan
(≤ `MAX_REPLANS`), and only a fully exhausted plan escalates to a human as
`status: blocked` + `plans/<slug>.blocked.md`.

## Token control (the scaling lever)
- Per-plan hard caps: `MAX_BUDGET_USD` (the real headless kill switch, `claude --max-budget-usd`)
  and `TIMEOUT` (needs `timeout`/`gtimeout`). State a soft turn cap in the plan's `## Constraints`.
- `MAX_PARALLEL` bounds fleet concurrency; merges are serialized by a lock regardless.
- **Engine routing** is the big one (`.env`, see `.env.example`): assign each role an
  engine chain like `LOOP_ENGINE_ENGINEER="glm:high|local:high"` — cheap models write
  code, the verifier stays pinned to frontier, providers that rate-limit are parked in a
  cooldown and the chain fails over. Same mechanism drives Codex (`LOOP_TOOL=codex`).

## Open vs closed loop
Closed (default): fleet runs ready plans and stops. Open: `loop/triage.sh` first runs
`loop/intake.sh` (inbox artifacts → draft plans via the planner agent, content-hash
idempotent), and can grow more discovery sources (per failing CI job, per labelled
issue, per TODO cluster). Drafts always wait for a human `draft → ready` promotion.

## Requirements & notes
- Verified against **Claude Code 2.1.191**. The headless CLI has **no `--max-turns`/`--tokens`**
  flags — the budget cap is **`--max-budget-usd`**. `run-plan.sh` runs a plain agentic
  `claude -p` and **commits the branch itself** (headless `acceptEdits` auto-approves
  edits but not `git commit`).
- Worktrees are consolidated under one folder: `$WORKTREE_DIR` (default `<repo-parent>/wt/`),
  named `<repo>-<slug>`. Inspect with `git worktree list`; integrate.sh cleans up merged
  ones; remove stragglers with `git worktree remove <path>`.
- The verifier runs `bypassPermissions` inside an ephemeral detached worktree — under
  Claude it stays read-only by tool restriction (no Edit/Write). Under **Codex** there is
  no tool restriction, only the `workspace-write` sandbox: the codex verifier *can*
  write to its checkout. The checkout is discarded after the audit, but treat codex
  verification as sandbox-bounded, not read-only.
- **Parallel workers are safe** sharing one `~/.claude` — verified 2026-08-14 by
  `loop/tests/parallel-workers.sh` (3 concurrent headless sessions × 2 rounds in separate
  worktrees: all exit 0, outputs valid, `~/.claude.json` intact; sessions are keyed by cwd
  path, so distinct worktrees don't collide). `MAX_PARALLEL=3` default stands. Caveat: run
  the test from a logged-in terminal — sandboxed/nested contexts fail "Not logged in"
  before touching any state.
- Gitignore build artifacts (`__pycache__/`, `node_modules/`, etc.) **before** the first commit —
  the harness commits with `git add -A`, and the verifier flags out-of-scope files.
- Command flags evolve; if one errors, check `claude --help` and adjust `loop.conf`.
