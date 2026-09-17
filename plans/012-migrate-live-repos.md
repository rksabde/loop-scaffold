# 012 — Migrate the live repos: `claude-framework`, then `amboli-website-claude`

status: draft
worktree: migrate-live-repos

## Goal (verifiable)
Both repos run loops from the machine-installed tool with zero vendored machinery, and one
real cheap plan goes end-to-end in each (execute → verify → integrate → `done`) producing a
call-log line and committed transcripts.

## Steps (per repo, framework first — it has no product code at risk)
1. Install the tool once: `git clone … ~/.loop-scaffold && ln -s ~/.loop-scaffold/bin/loop ~/.local/bin/loop`;
   add the same to `claude-framework/scripts/setup-claude-stack.sh` (idempotent).
2. `loop migrate --dry-run` → review → `loop migrate` → review staged diff → commit
   (`De-vendor loop machinery → machine-installed loop tool`).
3. If a launchd job exists (`loop schedule status`): uninstall old, `loop schedule install` (absolute `loop` path in plist).
4. Real run: a trivial `status: ready` plan (e.g. add a line to a scratch doc), `AUTO_INTEGRATE=1 loop fleet`.
5. `claude-framework/AGENTS.md`: update repo-layout + L3/L12 notes (subtree/vendoring superseded; link the spec).

## Constraints
- NOT fleet-runnable: spans other repos and needs a logged-in terminal. Human-driven (or an
  interactive session), one repo at a time; do not start amboli until framework is green.
- amboli: product code untouched; migrate commit contains only loop-machinery deletions + config moves.

## Acceptance (run in each target repo)
- [ ] `git ls-files loop .loop-scaffold LOOPS.md | wc -l` → 0
- [ ] `command -v loop` resolves to `~/.local/bin/loop`; `loop doctor` exits 0
- [ ] The trivial plan is `status: done`; `git log --oneline -3` shows `integrate …` + `bookkeep …`
- [ ] `.transcripts/<slug>/attempt-01-engineer.md` and `verify-01-verifier.md` are committed
- [ ] `tail -1 .loop/logs/calls.jsonl | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['model_actual']"`
- [ ] `loop schedule status` reports ACTIVE where a job existed before

## Notes
Depends on 011. Rollback = `git revert` the migrate commit (vendored copy returns intact).
