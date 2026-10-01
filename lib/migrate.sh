#!/usr/bin/env bash
# lib/migrate.sh — `loop migrate [dir] [--dry-run] [--force]` (spec §6, plan 011).
#
# De-vendors an OLD install.sh-style install so the project holds only config + data:
#   - moves loop/logs/* loop/state/* → .loop/{logs,state} (untracked runtime dir)
#   - removes loop/ (ONLY if it holds lib.sh or run-plan.sh), .loop-scaffold/, LOOPS.md,
#     .claude/agents/{engineer,verifier,researcher,planner}.md (other agents untouched)
#   - strips the "@LOOPS.md" line from CLAUDE.md and the loop-scaffold:begin..end block
#     from AGENTS.md
#   - drops PostToolUse hook entries running loop/gate.sh from .claude/settings.json
#     (python3 json; everything else preserved; file deleted if it ends up {})
#   - .gitignore: drops wt-*/ loop/logs/ loop/state/ (+ the old "# loop scaffold"
#     comment), ensures the init block
#   - refreshes .github/workflows/loop.yml ONLY if it is our old template; else warns
#   - runs the init logic (missing templates)
# Idempotent. Refuses on a dirty tree unless --force. --dry-run prints "would: …" and
# changes nothing. Leaves everything STAGED; never commits. Never touches loop.conf,
# .env, plans/*.md (existing), inbox/, .transcripts/.
set -uo pipefail
# shellcheck source=lib/init.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/init.sh"

usage() { echo "usage: loop migrate [dir] [--dry-run] [--force]"; }
dir="" force=0 LOOP_DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) LOOP_DRY=1 ;;
    --force|-f)   force=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*) echo "loop migrate: unknown option '$a'" >&2; usage >&2; exit 2 ;;
    *) [ -z "$dir" ] || { echo "loop migrate: too many arguments" >&2; exit 2; }; dir="$a" ;;
  esac
done
export LOOP_DRY
root="$(loop_resolve_root "${dir:-.}" migrate)" || exit 1
cd "$root" || exit 1
G() { git -C "$root" "$@"; }

echo "loop migrate → $root$([ "$LOOP_DRY" = 1 ] && echo '  (dry run: nothing will change)')"
if [ -n "$(G status --porcelain)" ]; then
  if [ "$force" = 1 ]; then echo "warn   working tree is dirty — proceeding (--force)"
  elif [ "$LOOP_DRY" = 1 ]; then echo "warn   working tree is dirty — a real run would refuse without --force"
  else
    echo "loop migrate: working tree is dirty (git status --porcelain is non-empty)." >&2
    echo "  commit or stash first, or re-run with --force." >&2
    exit 1
  fi
fi

STAGE=()        # paths to `git add` at the end (edits); removals are staged as they happen
changed=0

# _remove <path> — untrack (staged deletion) + delete from disk.
_remove() {
  local p="$1" n
  n="$(G ls-files -- "$p" | wc -l | tr -d ' ')"
  _say remove "$p ($n tracked)"; changed=1
  _dry && return 0
  [ "$n" -gt 0 ] && G rm -r -q --cached --ignore-unmatch -- "$p" >/dev/null
  rm -rf "${root:?}/$p"
}

# _rewrite <file> <new-content-file> <label> — replace if different, stage.
_rewrite() {
  local f="$1" new="$2" label="$3"
  if cmp -s "$f" "$new"; then rm -f "$new"; return 0; fi
  _say edit "$f ($label)"; changed=1
  if _dry; then rm -f "$new"; return 0; fi
  cat "$new" > "$f"; rm -f "$new"; STAGE+=("$f")
}

# ── 1. runtime dirs: loop/{logs,state} → .loop/{logs,state} (before loop/ goes) ──
ours=0
if [ -d loop ] && { [ -f loop/lib.sh ] || [ -f loop/run-plan.sh ]; }; then ours=1; fi
if [ "$ours" = 1 ]; then
  for sub in logs state; do
    [ -d "loop/$sub" ] && [ -n "$(ls -A "loop/$sub" 2>/dev/null)" ] || continue
    _say move "loop/$sub/* → .loop/$sub/"; changed=1
    _dry && continue
    mkdir -p ".loop/$sub"
    [ -f .loop/.gitignore ] || printf '*\n' > .loop/.gitignore
    cp -Rp "loop/$sub/." ".loop/$sub/" && rm -rf "loop/$sub"
  done
  _remove loop
elif [ -d loop ]; then
  _say warn "loop/ left alone (no lib.sh/run-plan.sh — not a loop-scaffold install)"
fi

# ── 2. vendored mirror, protocol doc, role files ──
[ -e .loop-scaffold ] && _remove .loop-scaffold
[ -e LOOPS.md ] && _remove LOOPS.md
for r in engineer verifier researcher planner; do
  [ -e ".claude/agents/$r.md" ] && _remove ".claude/agents/$r.md"
done
if ! _dry && [ -d .claude/agents ] && [ -z "$(ls -A .claude/agents)" ]; then rmdir .claude/agents; fi

# ── 3. CLAUDE.md: exactly the @LOOPS.md import line ──
if [ -f CLAUDE.md ] && grep -qxF '@LOOPS.md' CLAUDE.md; then
  tmp="$(mktemp)"; grep -vxF '@LOOPS.md' CLAUDE.md > "$tmp"
  _rewrite CLAUDE.md "$tmp" "drop @LOOPS.md"
fi

# ── 4. AGENTS.md: the loop-scaffold:begin..end pointer block (inclusive) ──
if [ -f AGENTS.md ] && grep -q '<!-- loop-scaffold:begin -->' AGENTS.md; then
  tmp="$(mktemp)"
  # drop the block plus the blank lines install.sh put right before it; trailing blanks trimmed
  awk '/<!-- loop-scaffold:begin -->/ { skip=1; pend=0; next }
       skip { if ($0 ~ /<!-- loop-scaffold:end -->/) skip=0; next }
       /^[[:space:]]*$/ { pend++; next }
       { while (pend > 0) { print ""; pend-- } print }' AGENTS.md > "$tmp"
  _rewrite AGENTS.md "$tmp" "drop loop-scaffold pointer block"
fi

# ── 5. .claude/settings.json: PostToolUse entries running loop/gate.sh (python3 json) ──
if [ -f .claude/settings.json ]; then
  res="$(python3 - "$LOOP_DRY" .claude/settings.json <<'PY'
import json, os, sys
dry, path = sys.argv[1] == "1", sys.argv[2]
try:
    with open(path) as f: data = json.load(f)
except Exception as e:
    print("error " + str(e)); sys.exit(0)
hooks = data.get("hooks") if isinstance(data, dict) else None
ptu = hooks.get("PostToolUse") if isinstance(hooks, dict) else None
if not isinstance(ptu, list):
    print("unchanged"); sys.exit(0)
ours = lambda h: isinstance(h, dict) and "loop/gate.sh" in str(h.get("command", ""))
new, removed = [], 0
for grp in ptu:
    if isinstance(grp, dict) and isinstance(grp.get("hooks"), list):
        keep = [h for h in grp["hooks"] if not ours(h)]
        removed += len(grp["hooks"]) - len(keep)
        if not keep: continue
        if len(keep) != len(grp["hooks"]): grp = dict(grp, hooks=keep)
    elif ours(grp):                     # flat (non-grouped) entry
        removed += 1; continue
    new.append(grp)
if removed == 0:
    print("unchanged"); sys.exit(0)
if new: hooks["PostToolUse"] = new
else:   del hooks["PostToolUse"]
if not hooks: del data["hooks"]
if not data:
    if not dry: os.remove(path)
    print("deleted %d" % removed); sys.exit(0)
if not dry:
    with open(path, "w") as f:
        json.dump(data, f, indent=2); f.write("\n")
print("edited %d" % removed)
PY
)"
  case "$res" in
    deleted*) _say remove ".claude/settings.json (only held the loop/gate.sh hook)"; changed=1
              if ! _dry && [ -n "$(G ls-files -- .claude/settings.json)" ]; then
                G rm -q --cached -- .claude/settings.json >/dev/null; fi ;;
    edited*)  _say edit ".claude/settings.json (drop loop/gate.sh PostToolUse hook)"; changed=1
              _dry || STAGE+=(.claude/settings.json) ;;
    error*)   _say warn ".claude/settings.json is not valid JSON — left alone (${res#error })" ;;
  esac
fi
if ! _dry && [ -d .claude ] && [ -z "$(ls -A .claude)" ]; then rmdir .claude; fi

# ── 6. .gitignore: drop old runtime lines (init block is ensured in step 8) ──
if [ -f .gitignore ] && grep -qxE 'wt-\*/|loop/logs/|loop/state/|# loop scaffold' .gitignore; then
  tmp="$(mktemp)"; grep -vxE 'wt-\*/|loop/logs/|loop/state/|# loop scaffold' .gitignore > "$tmp"
  _rewrite .gitignore "$tmp" "drop wt-*/ loop/logs/ loop/state/"
fi

# ── 7. CI workflow: refresh only our old template ──
wf=.github/workflows/loop.yml
if [ -f "$wf" ]; then
  if cmp -s "$wf" "$_INIT_LOOP_HOME/templates/ci/loop.yml"; then :
  elif grep -qF 'npm i -g @anthropic-ai/claude-code' "$wf" && grep -qF './loop/triage.sh' "$wf"; then
    tmp="$(mktemp)"; cp "$_INIT_LOOP_HOME/templates/ci/loop.yml" "$tmp"
    _rewrite "$wf" "$tmp" "refresh to the clone-the-tool template"
  else
    _say warn "$wf is not the stock loop-scaffold template — left alone; compare with \$LOOP_HOME/templates/ci/loop.yml"
  fi
fi

# ── 8. init: templates + gitignore block (skip-if-exists) ──
loop_init_project "$root" 0
[ "${#INIT_TOUCHED[@]}" -gt 0 ] && changed=1
if ! _dry && [ "${#INIT_TOUCHED[@]}" -gt 0 ]; then STAGE+=("${INIT_TOUCHED[@]}"); fi

if [ "$LOOP_DRY" = 1 ]; then
  [ "$changed" = 1 ] && echo "dry run: nothing changed" || echo "already migrated: nothing to do"
  exit 0
fi
# stage per path: one ignored path (e.g. a global `.env*` exclude hitting .env.example)
# must not stop the rest from being staged
if [ "${#STAGE[@]}" -gt 0 ]; then
  for p in "${STAGE[@]}"; do
    G add -- "$p" 2>/dev/null || _say warn "$p not staged (ignored by a gitignore rule?) — git add -f it if wanted"
  done
fi
if [ "$changed" = 1 ]; then echo "done: changes are STAGED (not committed) — review with: git status && git diff --cached"
else echo "already migrated: nothing to do"; fi
