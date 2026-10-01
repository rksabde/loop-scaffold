# Loop scaffold — the `loop` tool

Self-correcting agent loops layered on the `AGENTS.md` / `plans/` structure.
Closed loops (stop at verifiable acceptance), fanned out across **git worktrees**,
runnable **by hand** and **unattended** (launchd/cron / GitHub Actions). Tool-agnostic:
Claude Code and Codex are wired; all read the same `AGENTS.md`.

This repo is a **machine-installed tool**, not files you copy into projects. One clone per
machine (`LOOP_HOME`); projects hold only their own config and data (`loop.conf`, `.env`,
`plans/`, `inbox/`, `.transcripts/`, gitignored `.loop/`).

## Layout (`LOOP_HOME`)
```
bin/loop        single entrypoint: fleet | run | verify | integrate | intake | triage | schedule | doctor | version
lib/            the harness scripts (fleet, run-plan, verify, integrate, intake, triage, schedule, gate) + tests/
adapters/       claude.sh, codex.sh — tool-specific invocation behind the engine seam
plugin/         Claude Code plugin attached per worker (--plugin-dir): agents/ roles + hooks/ edit gate
templates/      what `loop init` writes into a project: loop.conf, .env.example, plans/, ci/loop.yml,
                verdict.schema.json — plus LOOPS.md, the protocol injected into every worker
```

## The loop, mapped to files
| Loop part | Where |
|---|---|
| Goal | `plans/NNN-*.md` → `## Acceptance` (must be checkable by command) |
| Actions | bash / edits, gated by the plugin's PostToolUse hook → `lib/gate.sh` (only when `LOOP_WORKER=1`) |
| Verification | gate (inner, every edit) → executor stops at acceptance → `verifier` (pre-merge audit) |
| Decision | `loop integrate` (opt-in `AUTO_INTEGRATE=1`): merge on PASS, self-correct on FAIL |
| Memory | `AGENTS.md` (stable) + plan `status:` + `plans/PROGRESS.md` (harness-owned episodic log) |
| Discovery | `loop intake`: `inbox/` artifacts → draft plans via the planner agent |
| Trigger | `loop fleet` (manual) / `loop triage` via `loop schedule` (launchd/cron) or CI |

## Quickstart
```bash
# 1. install the tool once per machine (or symlink a dev clone instead)
git clone https://github.com/rksabde/loop-scaffold ~/.loop-scaffold
ln -s ~/.loop-scaffold/bin/loop ~/.local/bin/loop
loop version && loop doctor

# 2. in a project (a git repo): write config + plans scaffolding
cd /path/to/your/repo
loop init                  # (coming in plan 011 — until then copy templates/loop.conf + templates/plans/)
$EDITOR loop.conf          # LINT_CMD, TEST_CMD, (TYPECHECK_CMD) — the ONLY required edit
cp ~/.loop-scaffold/templates/.env.example .env   # optional: engine routing per role

# 3. write a plan (see templates/plans/README.md for the format)
$EDITOR plans/001-thing.md # status: ready + verifiable Acceptance

# 4a. manual: fleet executes, you audit + merge
loop fleet
loop verify plans/001-thing.md        # independent pre-merge audit

# 4b. closed loop: execute, verify, merge on PASS, self-correct on FAIL
loop integrate plans/001-thing.md     # (or AUTO_INTEGRATE=1 in loop.conf, then loop fleet)

# 4c. unattended: per-repo scheduler (macOS launchd / Linux cron), or CI (templates/ci/loop.yml)
loop schedule install 09:00
```
`loop` works from the main checkout or any worktree of it: `LOOP_PROJECT_ROOT` always
resolves to the main checkout (first entry of `git worktree list`).

## Three nested checks (why loops don't drift)
1. **gate.sh** runs after every edit; a failure is fed back into the same turn → the agent fixes before continuing.
2. **The executor itself** works agentically to the plan's `## Acceptance` and stops at `end_turn`; `loop run` then commits its branch.
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

## How a worker is invoked (claude adapter)
Every worker call is `claude -p` with the harness attached for that session only:
`--plugin-dir $LOOP_HOME/plugin` (roles + gate hook), `--append-system-prompt-file
templates/LOOPS.md`, `--setting-sources project --strict-mcp-config` (the human's plugins/MCP
are not inherited) and env `LOOP_WORKER=1 LOOP_HOME LOOP_PROJECT_ROOT`. Transports are direct
(no ccr): `frontier` = subscription (`~/.config/claude/oauth-token` exported per call if
present), `glm` = OpenRouter's Anthropic endpoint (key in `~/.config/openrouter/key`), `local`
= Ollama's native endpoint. `glm`/`local` run `--bare` except for the executor — hooks do not
fire under `--bare`, and the executor needs the gate.

## Open vs closed loop
Closed (default): fleet runs ready plans and stops. Open: `loop triage` first runs
`loop intake` (inbox artifacts → draft plans via the planner agent, content-hash
idempotent), and can grow more discovery sources (per failing CI job, per labelled
issue, per TODO cluster). Drafts always wait for a human `draft → ready` promotion.

## Requirements & notes
- Verified against **Claude Code 2.1.233**. The headless CLI has **no `--max-turns`/`--tokens`**
  flags — the budget cap is **`--max-budget-usd`**. `loop run` runs a plain agentic
  `claude -p` and **commits the branch itself** (headless `acceptEdits` auto-approves
  edits but not `git commit`).
- Worktrees are consolidated under one folder: `$WORKTREE_DIR` (default `<repo-parent>/wt/`),
  named `<repo>-<slug>`. Inspect with `git worktree list`; `loop integrate` cleans up merged
  ones; remove stragglers with `git worktree remove <path>`.
- The verifier runs `bypassPermissions` inside an ephemeral detached worktree — under
  Claude it stays read-only by tool restriction (no Edit/Write). Under **Codex** there is
  no tool restriction, only the `workspace-write` sandbox: the codex verifier *can*
  write to its checkout. The checkout is discarded after the audit, but treat codex
  verification as sandbox-bounded, not read-only.
- **Parallel workers are safe** sharing one `~/.claude` — verified 2026-08-14 by
  `lib/tests/parallel-workers.sh` (3 concurrent headless sessions × 2 rounds in separate
  worktrees: all exit 0, outputs valid, `~/.claude.json` intact; sessions are keyed by cwd
  path, so distinct worktrees don't collide). `MAX_PARALLEL=3` default stands. Caveat: run
  the test from a logged-in terminal — sandboxed/nested contexts fail "Not logged in"
  before touching any state.
- Gitignore build artifacts (`__pycache__/`, `node_modules/`, etc.) **before** the first commit —
  the harness commits with `git add -A`, and the verifier flags out-of-scope files.
- Command flags evolve; if one errors, check `claude --help` and adjust `loop.conf`.
- Runtime state lives in the project's `.loop/` (logs, call log, cooldowns, merge lock) —
  self-gitignored. Tests: `bash lib/tests/stub-suite.sh` (stubbed LLM, ~10 s, no spend).
