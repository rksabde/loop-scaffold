# 013 — `agent-skeleton`: remove the subtree; point onboarding at `loop init`

status: draft
worktree: skeleton-desubtree

## Goal (verifiable)
`rksabde/agent-skeleton` is truly lean — no `.loop-scaffold/`, no subtree history going
forward. Template = `AGENTS.md`, `CLAUDE.md`, `README.md`, `.gitignore`,
`plans/{README,000-EXAMPLE,PROGRESS}.md`, `loop.conf`, `.env.example`. Onboarding text
everywhere says `loop init` / `loop fleet` instead of `.loop-scaffold/loop/install.sh .`.

## Tasks
- `git rm -r .loop-scaffold`; copy template files from `~/.loop-scaffold/templates/`; README
  "Turn on autonomous loops" section → install the tool (one clone + symlink) then `loop init`.
- `~/.claude/CLAUDE.md` global note + `~/.claude/commands/scaffold-agents.md`: replace the
  `.loop-scaffold` activation wording with `loop init` (keep the suppressable/once semantics).
- `templates/ci/loop.yml` (in loop-scaffold): clone step
  `git clone --depth 1 -b "${LOOP_REF:-main}" https://github.com/rksabde/loop-scaffold ~/.loop-scaffold`
  + `echo "$HOME/.loop-scaffold/bin" >> "$GITHUB_PATH"`; auth via `CLAUDE_CODE_OAUTH_TOKEN`
  (from `claude setup-token`) or `ANTHROPIC_API_KEY`.

## Constraints
- NOT fleet-runnable (other repo + user-scope files). Human-driven / interactive session.
- Requires `loop-scaffold` to be PUBLIC for the unauthenticated CI clone (see 009 Notes).

## Acceptance
- [ ] In agent-skeleton: `test ! -e .loop-scaffold && git ls-files | wc -l` ≤ 10
- [ ] `grep -rn "loop-scaffold/loop/install.sh\|subtree" README.md ~/.claude/CLAUDE.md ~/.claude/commands/scaffold-agents.md` → no matches
- [ ] Fresh spawn: `gh repo create tmp-skel-test --template rksabde/agent-skeleton --private --clone` → `loop init` → `LOOP_DRYRUN=1 loop fleet` exits 0 (then delete the test repo)
- [ ] `curl -sfI https://github.com/rksabde/loop-scaffold` → 200 without auth

## Notes
Depends on 011 (needs `loop init`) and the repo being public.
