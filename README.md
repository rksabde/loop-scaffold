# Loop scaffold

Self-correcting agent loops layered on the `AGENTS.md` / `plans/` structure.
Closed loops (stop at verifiable acceptance), fanned out across **git worktrees**,
runnable **by hand** and **unattended** (cron / GitHub Actions). Tool-agnostic:
Claude Code, Codex, and OpenCode all read the same `AGENTS.md`.

## The loop, mapped to files
| Loop part | Where |
|---|---|
| Goal | `plans/NNN-*.md` → `## Acceptance` (must be checkable by command) |
| Actions | bash / edits / MCP, gated by `.claude/settings.json` → `loop/gate.sh` |
| Verification | gate (inner) → `/goal` Haiku evaluator (mid) → `verifier` subagent (pre-merge) |
| Memory | `AGENTS.md` (stable) + plan `status:` + `plans/PROGRESS.md` (episodic) |
| Trigger | `loop/fleet.sh` (manual) / `loop/triage.sh` (cron, CI) |

## Quickstart
```bash
# 1. drop into an existing repo (non-destructive)
./loop/install.sh /path/to/your/repo
cd /path/to/your/repo

# 2. set your stack's commands (the ONLY required edit)
$EDITOR loop.conf          # LINT_CMD, TEST_CMD, (TYPECHECK_CMD)

# 3. write a plan
cp plans/000-EXAMPLE.md plans/001-thing.md
$EDITOR plans/001-thing.md # set status: ready + verifiable Acceptance

# 4a. interactive: kick the fleet, walk away
./loop/fleet.sh

# 4b. independent audit before merge
./loop/verify.sh plans/001-thing.md

# 4c. unattended: cron
#   0 2 * * 1-5  cd ~/repo && ./loop/triage.sh >> loop/cron.log 2>&1
# or commit .github/workflows/loop.yml
```

## Three nested checks (why loops don't drift)
1. **gate.sh** runs after every edit; a failure is fed back into the same turn → the agent fixes before continuing.
2. **The executor itself** works agentically to the plan's `## Acceptance` and stops at `end_turn`; `run-plan.sh` then commits its branch.
3. **`verifier` subagent** (strong model, read-only) re-runs every acceptance check on the branch before you merge — trusts nothing the executor claimed.

## Token control (the scaling lever)
- Per-plan hard caps: `MAX_BUDGET_USD` (the real headless kill switch, `claude --max-budget-usd`)
  and `TIMEOUT` (needs `timeout`/`gtimeout`). State a soft turn cap in the plan's `## Constraints`.
- `MAX_PARALLEL` bounds fleet concurrency.
- **Model routing** is the big one: set `CLAUDE_MODEL` to a cheap/long-context model
  for execution turns; keep `VERIFIER_MODEL` strong. This is exactly where a
  cheap long-context model (DeepSeek-class, etc.) slots in — and cross-tool you'd
  point Codex/OpenCode's execution model at the cheap one while the same
  `AGENTS.md` drives all of them.

## Open vs closed loop
Closed (default): fleet runs ready plans and stops. Open: add a discovery step in
`loop/triage.sh` that *writes* new `plans/*.md` each cycle (per failing CI job,
per labelled issue, per TODO cluster) — see the stub in that file.

## Requirements & notes
- Verified against **Claude Code 2.1.191**. The headless CLI has **no `--max-turns`/`--tokens`**
  flags — the budget cap is **`--max-budget-usd`**. `run-plan.sh` runs a plain agentic
  `claude -p` (not `/goal`, which doesn't terminate cleanly headless) and **commits the branch
  itself** (headless `acceptEdits` auto-approves edits but not `git commit`).
- Headless runs use `claude -p ... --permission-mode acceptEdits`. Use
  `bypassPermissions` only inside throwaway containers, and always with a fresh
  `$HOME` per parallel worker (don't share `~/.claude/` across concurrent runs —
  it corrupts session state).
- Gitignore build artifacts (`__pycache__/`, `node_modules/`, etc.) **before** the first commit —
  the harness commits with `git add -A`, and the verifier flags out-of-scope files (e.g. stray `.pyc`).
- `git worktree list` to inspect, `git worktree remove ../wt-<slug>` to clean up.
- Command flags evolve; if one errors, check `claude --help` and adjust `loop.conf`.
