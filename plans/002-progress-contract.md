# 002 — PROGRESS.md single-writer contract

status: done
worktree: progress-contract

## Goal (verifiable)
Exactly ONE writer of `plans/PROGRESS.md`: the harness (run-plan.sh / integrate.sh).
No agent-facing doc tells an agent to append to it. Today three sources contradict:
run-plan.sh prompt says "do not edit", engineer.md rule 6 says "append a note",
LOOPS.md protocol says "append at each meaningful step".

## Constraints
- Edit only: .claude/agents/engineer.md, LOOPS.md. (run-plan.sh prompt is already correct.)
- Do not change what the harness writes or its format.

## Tasks
- engineer.md rule 6: drop the "append to PROGRESS.md" clause; keep "stop when all
  Acceptance verify"; state the harness records progress.
- LOOPS.md protocol: replace the append line with "plans/PROGRESS.md is harness-owned;
  agents never write it".

## Acceptance
- [ ] `grep -n "PROGRESS" .claude/agents/engineer.md` → only mentions harness owns it (or no match)
- [ ] `grep -n "Append a one-line note" LOOPS.md` → no matches
- [ ] `grep -n "harness" LOOPS.md` → shows the ownership statement
