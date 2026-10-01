# plans/ — task plans the loop can run

One file per task: `NNN-<slug>.md` (numbered sequentially). Copy `000-EXAMPLE.md` to start.

## Format
```
# NNN — <title>
status: draft
worktree: <slug>

## Goal (verifiable)
<measurable END STATE, not a process — every clause runnable>

## Constraints
- <scope limits; files not to touch>
- stop after N turns or M minutes (soft cap; hard caps live in loop.conf)

## Acceptance
- [ ] <command-checkable check — test / grep / typecheck / file-exists>

## Notes
<links, context, gotchas — optional>
```

## status lifecycle
| status | meaning | who sets it |
|---|---|---|
| `draft` | written (by intake's planner agent or a human), not reviewed | planner / human |
| `ready` | reviewed; fleet may execute it | **human** (the gate) |
| `running` | integrate.sh is working it | harness |
| `blocked` | self-correction exhausted — see `plans/<slug>.blocked.md` | harness |
| `done` | merged; every Acceptance box verified by command | harness |

Rules that keep the loop honest:
- **Acceptance must be checkable by command** — the verifier re-runs each one; prose
  claims don't count.
- Keep plan scopes **disjoint**: worktrees prevent concurrent collision, but two plans
  editing the same file still conflict at merge.
- `PROGRESS.md` here is **harness-owned** (one line per run) — agents never write it.
- `worktree:` slug names the branch (`loop/NNN-<slug>`) and the worktree dir
  (`$WORKTREE_DIR/<repo>-NNN-<slug>`).

## Runtime dir: `.loop/` (never committed)
The `loop` tool keeps machine-local runtime state in `<project>/.loop/` (main checkout;
it carries its own `.gitignore` of `*`, so it is never committed even if the project
`.gitignore` misses it):

| path | what |
|---|---|
| `.loop/logs/calls.jsonl` | one JSON line per worker call: requested engine vs the model that actually answered, cost, turns |
| `.loop/logs/<slug>.json` / `.prompt` / `.verdict.json` / `.diff` | last executor log + prompt, verifier result, audited diff |
| `.loop/logs/<slug>.feedback` | the verifier's FAIL verdict, fed to the next executor attempt |
| `.loop/logs/cron.log` | output of the scheduled (`loop schedule`) runs |
| `.loop/state/<provider>.cooldown` | rate-limited provider parked until this epoch (failover) |
| `.loop/state/<slug>.pid`, `merge.lock/` | crash recovery + the merge mutex for parallel workers |

What IS committed: `plans/` (incl. `PROGRESS.md`, `*.blocked.md`) and `.transcripts/<slug>/`
(the LLM transcripts that ride inside the commits they produced).
