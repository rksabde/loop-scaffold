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
