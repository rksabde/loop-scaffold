#!/usr/bin/env bash
# lib/tests/init-migrate.sh — tests for `loop init` and `loop migrate` (plan 011).
# Plain foreground bash, scratch dirs via mktemp, no LLM, no network, < 60 s.
# Migrate fixture: a COPY of ~/Claude/dev/amboli-website-claude (an old vendored install);
# the real repo is only read (cp -R), never modified. Override with AMBOLI=/path.
#
#   bash lib/tests/init-migrate.sh          # KEEP=1 keeps the scratch dir
set -uo pipefail

LOOP_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOP="$LOOP_HOME/bin/loop"
AMBOLI="${AMBOLI:-$HOME/Claude/dev/amboli-website-claude}"
T="$(cd -P "$(mktemp -d)" && pwd)"
[ "${KEEP:-0}" = "1" ] && echo "scratch: $T" || trap 'rm -rf "$T"' EXIT

# Hermetic git: no global excludes (this machine ignores .env* globally), no template hooks.
printf '[user]\n\tname = loop-test\n\temail = loop-test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset LOOP_TOOL LOOP_ENGINE_DEFAULT LOOP_ENGINE_ENGINEER LOOP_ENGINE_VERIFIER LOOP_ENGINE_PLANNER \
      LOOP_ENGINE_RESEARCHER LOOP_DRYRUN AUTO_INTEGRATE RETRY LOOP_WORKER LOOP_ADAPTER_FILE \
      LOOP_PROJECT_ROOT WORKTREE_DIR

pass=0; fail=0
check() {   # check "<name>" <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS  $name"
  else fail=$((fail+1)); echo "FAIL  $name"; fi
}
snap() { git -C "$1" status --porcelain -uall; git -C "$1" diff --cached --stat; git -C "$1" diff --stat; }

# ── (a) init in an empty git repo ────────────────────────────────────────────
git init -q "$T/a"
( cd "$T/a" && "$LOOP" init ) > "$T/a.out" 2>&1; rc=$?
git -C "$T/a" status --porcelain -uall | sed 's/^?? //' | sort > "$T/a.files"
printf '%s\n' .env.example .gitignore AGENTS.md CLAUDE.md loop.conf \
  plans/000-EXAMPLE.md plans/PROGRESS.md plans/README.md | sort > "$T/a.want"
check "a1 init exits 0"                         test "$rc" -eq 0
check "a2 init writes exactly the expected files" cmp -s "$T/a.files" "$T/a.want"
check "a3 init: no scripts/agents/hooks/LOOPS.md" bash -c "cd '$T/a' && test ! -e loop && test ! -e .claude && test ! -e LOOPS.md"
check "a4 CLAUDE.md is @AGENTS.md"              bash -c "[ \"\$(cat '$T/a/CLAUDE.md')\" = '@AGENTS.md' ]"
check "a5 gitignore block (marker + 5 entries)" bash -c "cd '$T/a' && grep -qxF '# loop-scaffold' .gitignore && for e in .loop/ .env .intake.sha AGENTS.override.md wt/; do grep -qxF \"\$e\" .gitignore || exit 1; done"
snap "$T/a" > "$T/a.s1"; ( cd "$T/a" && find . -path ./.git -prune -o -type f -print | sort | xargs cksum ) > "$T/a.c1"
( cd "$T/a" && "$LOOP" init ) > "$T/a.out2" 2>&1
snap "$T/a" > "$T/a.s2"; ( cd "$T/a" && find . -path ./.git -prune -o -type f -print | sort | xargs cksum ) > "$T/a.c2"
check "a6 init re-run changes nothing"          bash -c "cmp -s '$T/a.s1' '$T/a.s2' && cmp -s '$T/a.c1' '$T/a.c2' && ! grep -qE '^(add|edit) ' '$T/a.out2'"
( cd "$T/a" && "$LOOP" init --ci ) > "$T/a.out3" 2>&1
check "a7 init --ci adds the workflow"          cmp -s "$T/a/.github/workflows/loop.yml" "$LOOP_HOME/templates/ci/loop.yml"

# ── (b) init outside a git repo ──────────────────────────────────────────────
mkdir -p "$T/b"
( cd "$T/b" && "$LOOP" init ) > "$T/b.out" 2>&1; rc=$?
check "b1 init outside a git repo → exit 1"    test "$rc" -eq 1
check "b2 ...and writes nothing"               test -z "$(ls -A "$T/b")"

# ── migrate fixture: copy of amboli + planted custom hook/agent ─────────────
if [ ! -d "$AMBOLI/.git" ]; then
  echo "FAIL  fixture: $AMBOLI not found"; fail=$((fail+1))
else
  cp -R "$AMBOLI" "$T/amb"
  git -C "$T/amb" checkout -q -- . && git -C "$T/amb" clean -fdq
  # sever the copy from the real repo's worktrees (their .git files point at the original)
  rm -rf "$T/amb/.git/worktrees" "$T/amb/.claude/worktrees"; git -C "$T/amb" worktree prune
  git -C "$T/amb" config core.hooksPath /dev/null
  python3 - "$T/amb/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PostToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": "echo custom-hook"}]})
d["permissions"] = {"allow": ["Bash(npm test)"]}
json.dump(d, open(p, "w"), indent=2)
PY
  printf -- '---\nname: custom-reviewer\ndescription: keep me\n---\nI am a custom agent.\n' > "$T/amb/.claude/agents/custom-reviewer.md"
  git -C "$T/amb" add -A && git -C "$T/amb" commit -q --no-verify -m "plant custom hook + agent"
  cp "$T/amb/.claude/agents/custom-reviewer.md" "$T/custom-agent.bak"
  extract_custom() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps([g for g in d['hooks']['PostToolUse'] if 'custom-hook' in json.dumps(g)], sort_keys=True))
print(json.dumps(d.get('permissions'), sort_keys=True))" "$1"; }
  extract_custom "$T/amb/.claude/settings.json" > "$T/custom-hook.before"
  ( cd "$T/amb" && for f in plans/*.md loop.conf; do cksum "$f"; done ) > "$T/plans.before"
  mkdir -p "$T/amb/loop/state" && echo 123 > "$T/amb/loop/state/frontier.cooldown"   # untracked runtime (gitignored)

  # ── (c) migrate --dry-run changes nothing ──
  snap "$T/amb" > "$T/c.s1"; ( cd "$T/amb" && find . -path ./.git -prune -o -print | sort ) > "$T/c.f1"
  ( cd "$T/amb" && "$LOOP" migrate --dry-run ) > "$T/c.out" 2>&1; rc=$?
  snap "$T/amb" > "$T/c.s2"; ( cd "$T/amb" && find . -path ./.git -prune -o -print | sort ) > "$T/c.f2"
  check "c1 dry-run exits 0"                       test "$rc" -eq 0
  check "c2 dry-run: git status identical"         cmp -s "$T/c.s1" "$T/c.s2"
  check "c3 dry-run: file tree identical"          cmp -s "$T/c.f1" "$T/c.f2"
  check "c4 dry-run output has 'would:' lines"     grep -q '^would: ' "$T/c.out"

  # ── (d) migrate ──
  ( cd "$T/amb" && "$LOOP" migrate ) > "$T/d.out" 2>&1; rc=$?
  check "d1 migrate exits 0"                       test "$rc" -eq 0
  check "d2 old install untracked"                 test -z "$(git -C "$T/amb" ls-files loop .loop-scaffold LOOPS.md .claude/agents/engineer.md .claude/agents/verifier.md .claude/agents/researcher.md .claude/agents/planner.md)"
  check "d3 old install gone from disk"            bash -c "cd '$T/amb' && test ! -e loop && test ! -e .loop-scaffold && test ! -e LOOPS.md && test ! -e .claude/agents/engineer.md"
  check "d4 no LOOPS in CLAUDE.md / AGENTS.md"     bash -c "cd '$T/amb' && [ \"\$(grep -c LOOPS CLAUDE.md)\" = 0 ] && [ \"\$(grep -c LOOPS AGENTS.md)\" = 0 ] && ! grep -q loop-scaffold: AGENTS.md"
  check "d5 custom agent byte-identical"           cmp -s "$T/custom-agent.bak" "$T/amb/.claude/agents/custom-reviewer.md"
  check "d6 settings.json valid JSON"              python3 -c "import json; json.load(open('$T/amb/.claude/settings.json'))"
  check "d7 gate hook removed"                     bash -c "! grep -q 'loop/gate.sh' '$T/amb/.claude/settings.json'"
  extract_custom "$T/amb/.claude/settings.json" > "$T/custom-hook.after" 2>/dev/null
  check "d8 custom hook + permissions identical"   cmp -s "$T/custom-hook.before" "$T/custom-hook.after"
  ( cd "$T/amb" && for f in plans/*.md loop.conf; do cksum "$f"; done ) > "$T/plans.after"
  check "d9 plans/*.md + loop.conf untouched"      cmp -s "$T/plans.before" "$T/plans.after"
  check "d10 runtime moved to .loop/"              bash -c "test -f '$T/amb/.loop/state/frontier.cooldown' && ls '$T/amb/.loop/logs/' | grep -q verdict"
  check "d11 gitignore rewritten"                  bash -c "cd '$T/amb' && ! grep -qxE 'wt-\\*/|loop/logs/|loop/state/' .gitignore && grep -qxF .loop/ .gitignore && grep -qxF .env .gitignore"
  check "d12 old CI workflow refreshed"            cmp -s "$T/amb/.github/workflows/loop.yml" "$LOOP_HOME/templates/ci/loop.yml"
  check "d13 changes staged, not committed"        bash -c "[ \"\$(git -C '$T/amb' log -1 --format=%s)\" = 'plant custom hook + agent' ] && [ -n \"\$(git -C '$T/amb' diff --cached --name-only)\" ] && [ -z \"\$(git -C '$T/amb' diff --name-only)\" ]"
  snap "$T/amb" > "$T/d.s1"
  ( cd "$T/amb" && "$LOOP" migrate --force ) > "$T/d.out2" 2>&1
  snap "$T/amb" > "$T/d.s2"
  check "d14 re-run migrate → no further changes"  bash -c "cmp -s '$T/d.s1' '$T/d.s2' && grep -q 'already migrated' '$T/d.out2'"
  git -C "$T/amb" commit -q --no-verify -m "loop migrate"
  ( cd "$T/amb" && "$LOOP" migrate ) > "$T/d.out3" 2>&1; rc=$?
  check "d15 re-run on clean migrated tree: no-op" bash -c "[ $rc -eq 0 ] && [ -z \"\$(git -C '$T/amb' status --porcelain)\" ]"

  # ── (e) loop fleet works after migrate ──
  p="$(grep -l '^status: ready' "$T/amb"/plans/[0-9]*.md 2>/dev/null | head -1)"
  if [ -z "$p" ]; then p="$T/amb/plans/002-shared-ui-components.md"; sed -i.bak -E 's/^status:.*/status: ready/' "$p" && rm -f "$p.bak"
    git -C "$T/amb" commit -q --no-verify -am "ready one plan"; fi
  ( cd "$T/amb" && WORKTREE_DIR="$T/wt" LOOP_DRYRUN=1 "$LOOP" fleet ) > "$T/e.out" 2>&1; rc=$?
  check "e1 LOOP_DRYRUN=1 loop fleet exits 0"      test "$rc" -eq 0
  check "e2 ...and dispatched a dry-run worker"    grep -q 'DRYRUN role=engineer' "$T/e.out"

  # ── (f) migrate on a dirty copy ──
  cp -R "$AMBOLI" "$T/amb2"
  git -C "$T/amb2" checkout -q -- . && git -C "$T/amb2" clean -fdq
  rm -rf "$T/amb2/.git/worktrees" "$T/amb2/.claude/worktrees"; git -C "$T/amb2" worktree prune
  echo "dirty" >> "$T/amb2/README.md"
  ( cd "$T/amb2" && "$LOOP" migrate ) > "$T/f.out" 2>&1; rc=$?
  check "f1 dirty tree → exit 1"                   test "$rc" -eq 1
  check "f2 ...and nothing removed"                test -f "$T/amb2/loop/lib.sh"
  ( cd "$T/amb2" && "$LOOP" migrate --force ) > "$T/f.out2" 2>&1; rc=$?
  check "f3 --force proceeds"                      bash -c "[ $rc -eq 0 ] && test ! -e '$T/amb2/loop' && grep -qxF dirty <(tail -1 '$T/amb2/README.md')"
  check "f4 settings.json with only our hook → deleted" bash -c "test ! -e '$T/amb2/.claude/settings.json' && [ -z \"\$(git -C '$T/amb2' ls-files .claude)\" ]"
fi

# ── (g) install.sh is gone ───────────────────────────────────────────────────
check "g1 no lib/install.sh, README has no install.sh" bash -c "cd '$LOOP_HOME' && test ! -e lib/install.sh && ! grep -q 'install.sh' README.md"
check "g2 templates mention no install.sh"       bash -c "! grep -rq 'install.sh' '$LOOP_HOME/templates'"

echo "init-migrate: $pass passed, $fail failed ($((pass+fail)) checks)"
[ "$fail" -eq 0 ]
