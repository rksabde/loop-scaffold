# 011 — `loop init` (config+data only) and `loop migrate` (de-vendor an old install)

status: draft
worktree: init-and-migrate

## Goal (verifiable)
- `loop init [dir]` writes ONLY project-owned files from `templates/`, skip-if-exists:
  `loop.conf`, `.env.example`, `plans/{README,000-EXAMPLE,PROGRESS}.md`; appends the
  gitignore block (`.loop/`, `.env`, `.intake.sha`, `AGENTS.override.md`); creates lean
  `AGENTS.md`/`CLAUDE.md` if absent. Optional `--ci` copies `templates/ci/loop.yml` to
  `.github/workflows/loop.yml`. Writes NO scripts, agents, hooks, or LOOPS.md.
- `loop migrate [dir]` converts a vendored install, idempotently:
  removes tracked `loop/` (scripts, adapters, tests, transcript.py), `.loop-scaffold/`,
  `.claude/agents/{engineer,verifier,researcher,planner}.md`, `LOOPS.md`; strips the
  `@LOOPS.md` line from `CLAUDE.md`, the `<!-- loop-scaffold:begin/end -->` block from
  `AGENTS.md`, and the `bash loop/gate.sh` PostToolUse entry from `.claude/settings.json`
  (deleting the file if it becomes empty `{}`/`{"hooks":{}}`); moves `loop/logs`,`loop/state`
  → `.loop/`; rewrites gitignore entries; refreshes CI workflow to the clone-step version.
  `--dry-run` prints the plan and changes nothing. Leaves changes STAGED, never commits.
- `install.sh` deleted; README quickstart uses `loop init`.

## Constraints
- `migrate` must refuse on a dirty tree (except with `--force`) and must never touch
  `loop.conf`, `.env`, `plans/*.md`, `inbox/`, `.transcripts/`, or non-loop entries in
  `.claude/settings.json` / other `.claude/agents/*`.
- settings.json surgery via python3 json (no sed on JSON).

## Acceptance
- [ ] `loop init` in an empty git repo → `git status --porcelain` lists only the files named above; re-run changes nothing
- [ ] `loop migrate --dry-run` on a copy of a vendored repo changes nothing (`git status` identical before/after)
- [ ] `loop migrate` on that copy → `git ls-files loop .loop-scaffold LOOPS.md .claude/agents/engineer.md` is empty; `grep -c LOOPS CLAUDE.md AGENTS.md` → 0; re-run is a no-op
- [ ] A custom hook + custom agent planted in the copy's `.claude/` survive migrate byte-identical
- [ ] After migrate, `LOOP_DRYRUN=1 loop fleet` works in the copy
- [ ] `test ! -e lib/install.sh && ! grep -q "install.sh" README.md`

## Notes
Depends on 010. Blocks 012, 013. Test fixture: `cp -R ~/Claude/dev/amboli-website-claude` to a temp dir.
