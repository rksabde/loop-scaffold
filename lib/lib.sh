#!/usr/bin/env bash
# loop/lib.sh — shared helpers. Source this at the top of every loop script.
set -uo pipefail

# Repo root = parent of the loop/ dir this file lives in.
SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load per-project config.
if [ -f "$SCAFFOLD_ROOT/loop.conf" ]; then
  # shellcheck disable=SC1091
  source "$SCAFFOLD_ROOT/loop.conf"
fi

# Load engine routing (.env) HERE — early — so LOOP_TOOL is set before run-plan.sh/
# verify.sh pick their adapter, and LOOP_ENGINE_* are available to engine.sh.
if [ -f "$SCAFFOLD_ROOT/.env" ]; then
  set -a; # shellcheck disable=SC1091
  . "$SCAFFOLD_ROOT/.env"; set +a
fi

# Where plan/verify git worktrees are created. Default: a single `wt/` dir BESIDE the
# repo (e.g. ~/Claude/dev/wt/) so the parent dev folder isn't littered with wt-* siblings.
# Override in loop.conf or .env (WORKTREE_DIR=/abs/or/relative/path). Worktrees are named
# <repo>-<slug> so several repos can safely share one WORKTREE_DIR root.
REPO_NAME="$(basename "$SCAFFOLD_ROOT")"
WORKTREE_DIR="${WORKTREE_DIR:-$SCAFFOLD_ROOT/../wt}"
# Normalize to an absolute path (create it first so `cd && pwd` can resolve `..`).
WORKTREE_DIR="$(mkdir -p "$WORKTREE_DIR" 2>/dev/null; cd "$WORKTREE_DIR" 2>/dev/null && pwd || printf '%s' "$WORKTREE_DIR")"

# worktree_path <slug> → absolute path for that worktree, namespaced by repo.
worktree_path() { printf '%s/%s-%s' "$WORKTREE_DIR" "$REPO_NAME" "$1"; }

log() { printf '%s  %s\n' "$(date +%FT%T)" "$*" >&2; }

# set_status <plan-file> <value> — rewrite the `status:` line in a plan's frontmatter.
# Portable in-place sed (BSD/macOS needs the -i backup suffix); no-op if absent.
set_status() {
  local f="$1" v="$2"
  grep -qE '^status:' "$f" 2>/dev/null || return 0
  sed -i.bak -E "s/^status:.*/status: $v/" "$f" && rm -f "$f.bak"
}

# plan_verdict <verdict-log> — echo PASS | FAIL | ERROR by scanning the verifier's
# JSON result. Dependency-free: the embedded verdict survives JSON-escaping as
# verdict"…"pass, so a loose proximity match is robust whether or not jq is present.
plan_verdict() {
  local vf="$1"
  [ -s "$vf" ] || { echo ERROR; return; }
  if   grep -qiE 'verdict[\\":[:space:]]+pass' "$vf"; then echo PASS
  elif grep -qiE 'verdict[\\":[:space:]]+fail' "$vf"; then echo FAIL
  else echo ERROR; fi
}

require() { command -v "$1" >/dev/null 2>&1 || { log "MISSING: $1 not on PATH"; exit 127; }; }

# Portable wall-clock timeout: GNU `timeout`, else `gtimeout` (macOS coreutils),
# else empty — callers degrade to --max-turns only (no hard kill switch).
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else TIMEOUT_BIN=""; fi
