# 011 — `loop init` (config+data only) and `loop migrate` (de-vendor an old install)

status: done
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
- [x] `loop init` in an empty git repo → `git status --porcelain` lists only the files named above; re-run changes nothing
- [x] `loop migrate --dry-run` on a copy of a vendored repo changes nothing (`git status` identical before/after)
- [x] `loop migrate` on that copy → `git ls-files loop .loop-scaffold LOOPS.md .claude/agents/engineer.md` is empty; `grep -c LOOPS CLAUDE.md AGENTS.md` → 0; re-run is a no-op
- [x] A custom hook + custom agent planted in the copy's `.claude/` survive migrate byte-identical
- [x] After migrate, `LOOP_DRYRUN=1 loop fleet` works in the copy
- [x] `test ! -e lib/install.sh && ! grep -q "install.sh" README.md`

## Notes
Depends on 010. Blocks 012, 013. Test fixture: `cp -R ~/Claude/dev/amboli-website-claude` to a temp dir.

## Progress
2026-10-01 — DONE. Commits: `003062f` (lib/init.sh + lib/migrate.sh, wired into bin/loop),
`1e92781` (lib/tests/init-migrate.sh, README quickstart, CI template auth), then this plan update.

### Acceptance outputs (run from the repo root)
```
$ bash lib/tests/init-migrate.sh
PASS  a1 init exits 0
PASS  a2 init writes exactly the expected files
PASS  a3 init: no scripts/agents/hooks/LOOPS.md
PASS  a4 CLAUDE.md is @AGENTS.md
PASS  a5 gitignore block (marker + 5 entries)
PASS  a6 init re-run changes nothing
PASS  a7 init --ci adds the workflow
PASS  b1 init outside a git repo → exit 1
PASS  b2 ...and writes nothing
PASS  c1 dry-run exits 0
PASS  c2 dry-run: git status identical
PASS  c3 dry-run: file tree identical
PASS  c4 dry-run output has 'would:' lines
PASS  d1 migrate exits 0
PASS  d2 old install untracked
PASS  d3 old install gone from disk
PASS  d4 no LOOPS in CLAUDE.md / AGENTS.md
PASS  d5 custom agent byte-identical
PASS  d6 settings.json valid JSON
PASS  d7 gate hook removed
PASS  d8 custom hook + permissions identical
PASS  d9 plans/*.md + loop.conf untouched
PASS  d10 runtime moved to .loop/
PASS  d11 gitignore rewritten
PASS  d12 old CI workflow refreshed
PASS  d13 changes staged, not committed
PASS  d14 re-run migrate → no further changes
PASS  d15 re-run on clean migrated tree: no-op
PASS  e1 LOOP_DRYRUN=1 loop fleet exits 0
PASS  e2 ...and dispatched a dry-run worker
PASS  f1 dirty tree → exit 1
PASS  f2 ...and nothing removed
PASS  f3 --force proceeds
PASS  f4 settings.json with only our hook → deleted
PASS  g1 no lib/install.sh, README has no install.sh
PASS  g2 templates mention no install.sh
init-migrate: 36 passed, 0 failed (36 checks)
rc=0
$ bash lib/tests/stub-suite.sh | tail -1
stub-suite: 44 passed, 0 failed (44 checks)
$ test ! -e lib/install.sh && ! grep -q "install.sh" README.md
rc=0
$ for f in bin/loop lib/*.sh adapters/*.sh lib/tests/*.sh; do bash -n "$f"; done
rc=0
```
Fixture: `cp -R ~/Claude/dev/amboli-website-claude` (read-only; the real repo's `git status`
is unchanged: `?? inbox/`). Its plans 002–013 are `status: draft`, so check (e) flips 002 to
`ready` in the copy (after the plans-untouched check) before `LOOP_DRYRUN=1 loop fleet`.

### Decisions the plan did not specify
- `[dir]` resolves to the git toplevel containing it (`git rev-parse --show-toplevel`), so
  `loop init sub/dir` writes at the repo root; inside a linked worktree it writes there.
- Gitignore: only MISSING entries are appended (`.loop/ .env .intake.sha AGENTS.override.md wt/`);
  the `# loop-scaffold` marker is written once. Migrate also drops the old `# loop scaffold`
  comment (space, install.sh's marker) along with `wt-*/ loop/logs/ loop/state/`.
- `migrate --dry-run` on a dirty tree warns instead of refusing (it changes nothing); a real
  run refuses (exit 1) unless `--force`. In dry-run `skip`/`warn` lines are not prefixed `would:`.
- settings.json surgery is per hook: inside a PostToolUse group only `loop/gate.sh` commands are
  removed; an emptied group, then `PostToolUse`, then `hooks` are removed; `{}` → file deleted
  (`git rm --cached` if tracked). Invalid JSON → warning, file left alone. The rewrite is
  `json.dump(indent=2)`, so formatting may normalise; other keys/entries are preserved.
- AGENTS.md block removal also drops the blank line(s) install.sh put right before the block and
  trailing blank lines at EOF.
- Empty `.claude/agents/` and `.claude/` dirs are removed after the role/settings deletions.
- CI: a workflow identical to the current template is skipped silently, so re-runs don't warn.
- Staging is per path: a path matched by an ignore rule (e.g. this machine's global `.env*`
  exclude hitting a freshly-added `.env.example`) warns instead of aborting the whole `git add`.
- `loop init` (standalone) does not stage; only `migrate` stages.
- The stub-suite's `cli: init stub → exit 2` check became `cli: init outside a git repo → exit 1`
  (the old check ran a real `loop init` in this repo once the stub was gone).
- Tests run with a hermetic `GIT_CONFIG_GLOBAL` (no global excludes or template hooks) so
  results don't depend on the machine's `~/.gitignore_global`.
- `lib/intake.sh` still looks for `install.sh`/`loop/install.sh` in its skip rule (it spots
  machinery dirs inside `inbox/`); left alone because it is detection, not documentation.
