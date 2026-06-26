#!/usr/bin/env bash
# loop/install.sh — copy this scaffold into an existing repo, non-destructively.
# Run FROM the scaffold dir:   ./loop/install.sh /path/to/your/repo
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="${1:?usage: install.sh /path/to/target/repo}"
[ -d "$dst/.git" ] || { echo "✗ $dst is not a git repo"; exit 1; }

copy() {  # never clobber an existing file
  if [ -e "$dst/$1" ]; then echo "skip  $1 (exists)"; else
    mkdir -p "$dst/$(dirname "$1")"; cp "$src/$1" "$dst/$1"; echo "add   $1"; fi
}

for f in loop.conf LOOPS.md .env.example \
         loop/lib.sh loop/engine.sh loop/gate.sh loop/run-plan.sh loop/fleet.sh \
         loop/verify.sh loop/triage.sh loop/intake.sh \
         loop/adapters/claude.sh loop/adapters/codex.sh loop/adapters/opencode.sh \
         .claude/settings.json \
         .claude/agents/verifier.md .claude/agents/researcher.md .claude/agents/engineer.md \
         .claude/agents/planner.md \
         plans/000-EXAMPLE.md plans/PROGRESS.md; do
  copy "$f"
done

# CI workflow ships as a TEMPLATE (ci/loop.yml) so this scaffold repo isn't itself an
# active workflow; install places it at the TARGET's .github/workflows/.
if [ -e "$dst/.github/workflows/loop.yml" ]; then echo "skip  .github/workflows/loop.yml (exists)"; else
  mkdir -p "$dst/.github/workflows"; cp "$src/ci/loop.yml" "$dst/.github/workflows/loop.yml"
  echo "add   .github/workflows/loop.yml (from ci/loop.yml)"; fi

# AGENTS.md / CLAUDE.md: keep the lean canonical files, just point them at the loop docs.
[ -e "$dst/AGENTS.md" ] || { cp "$src/AGENTS.md" "$dst/AGENTS.md"; echo "add   AGENTS.md"; }
[ -e "$dst/CLAUDE.md" ] || { printf '@AGENTS.md\n' > "$dst/CLAUDE.md"; echo "add   CLAUDE.md"; }

# Activation makes the loop protocol re-enter the canonical files (idempotent):
#  - AGENTS.md gets a tool-agnostic pointer block (Codex/OpenCode read this too).
#  - CLAUDE.md gets an @LOOPS.md import so Claude auto-loads the protocol.
if ! grep -q 'loop-scaffold:begin' "$dst/AGENTS.md" 2>/dev/null; then
  cat >> "$dst/AGENTS.md" <<'PTR'

<!-- loop-scaffold:begin -->
## Loops (active)
This repo runs autonomous self-correcting loops. Read **LOOPS.md** for the loop
protocol and agent roles before working a plan.
<!-- loop-scaffold:end -->
PTR
  echo "edit  AGENTS.md (loop pointer)"
fi
grep -qxF '@LOOPS.md' "$dst/CLAUDE.md" 2>/dev/null || { printf '@LOOPS.md\n' >> "$dst/CLAUDE.md"; echo "edit  CLAUDE.md (@LOOPS.md)"; }

chmod +x "$dst"/loop/*.sh
grep -qxF 'wt-*/' "$dst/.gitignore" 2>/dev/null || printf '\n# loop scaffold\nwt-*/\nloop/logs/\nloop/state/\n.intake.sha\nAGENTS.override.md\n' >> "$dst/.gitignore"

echo
echo "✓ installed. Next: edit $dst/loop.conf (LINT_CMD/TEST_CMD), then ./loop/fleet.sh"
