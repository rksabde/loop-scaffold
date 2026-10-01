#!/usr/bin/env bash
# lib/lib.sh — shared helpers. Source this at the top of every loop script.
set -uo pipefail

# ── Path model (spec §5.2) ────────────────────────────────────────────
# LOOP_HOME         = the installed tool (the dir holding bin/ lib/ adapters/ plugin/
#                     templates/), resolved from THIS file's real path (lib/..).
# LOOP_PROJECT_ROOT = the MAIN checkout of the git repo we were invoked in: the first
#                     "worktree" entry of `git worktree list --porcelain` run from $PWD.
#                     NOT --show-toplevel, which returns the worktree when called from one.
# Runtime state lives in $LOOP_PROJECT_ROOT/.loop/{logs,state} (self-gitignored).
_loop_realdir() {   # dir of a (possibly symlinked) path, physically resolved
  local p="$1" d
  while [ -L "$p" ]; do
    d="$(cd -P "$(dirname "$p")" && pwd)"; p="$(readlink "$p")"
    case "$p" in /*) ;; *) p="$d/$p" ;; esac
  done
  cd -P "$(dirname "$p")" && pwd
}
# Echo the main checkout of the repo containing $PWD (non-zero if not in a git repo).
loop_project_root() {
  local r
  r="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  [ -n "$r" ] && [ -d "$r" ] || return 1
  (cd -P "$r" && pwd)
}

LOOP_HOME="$(cd -P "$(_loop_realdir "${BASH_SOURCE[0]}")/.." && pwd)"
if ! LOOP_PROJECT_ROOT="$(loop_project_root)"; then
  printf 'loop: not inside a git repository (cwd: %s) — run loop from your project checkout\n' "$PWD" >&2
  exit 1
fi
export LOOP_HOME LOOP_PROJECT_ROOT
# Back-compat alias: the moved scripts still say SCAFFOLD_ROOT (= the project, never the tool).
SCAFFOLD_ROOT="$LOOP_PROJECT_ROOT"
_LOOP_LIB_LOADED=1

LOOP_DIR="$LOOP_PROJECT_ROOT/.loop"
LOOP_LOGS="$LOOP_DIR/logs"
LOOP_STATE="$LOOP_DIR/state"
mkdir -p "$LOOP_LOGS" "$LOOP_STATE" 2>/dev/null
# Self-ignoring runtime dir: never committed even if the project .gitignore lacks it.
[ -f "$LOOP_DIR/.gitignore" ] || printf '*\n' > "$LOOP_DIR/.gitignore" 2>/dev/null

# Load per-project config.
if [ -f "$SCAFFOLD_ROOT/loop.conf" ]; then
  # shellcheck disable=SC1091
  source "$SCAFFOLD_ROOT/loop.conf"
fi

# Load engine routing (.env) HERE — early — so LOOP_TOOL is set before run-plan.sh/
# verify.sh pick their adapter, and LOOP_ENGINE_* are available to engine.sh.
# Both loop.conf and .env are read from the PROJECT (main checkout), never LOOP_HOME.
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

# adapter_path — echo the adapter file for $LOOP_TOOL, or die (exit 2) with a clear
# message. LOOP_ADAPTER_FILE overrides the lookup (test seam: lib/tests/stub-suite.sh).
adapter_path() {
  local tool="${LOOP_TOOL:-claude}" f
  if [ -n "${LOOP_ADAPTER_FILE:-}" ]; then printf '%s' "$LOOP_ADAPTER_FILE"; return 0; fi
  f="$LOOP_HOME/adapters/$tool.sh"
  if [ "$tool" = "opencode" ]; then
    log "LOOP_TOOL=opencode is not supported (adapter dropped, spec §8.3) — set LOOP_TOOL=claude or codex"
    exit 2
  fi
  [ -f "$f" ] || { log "unknown LOOP_TOOL='$tool' (no $f) — supported: claude, codex"; exit 2; }
  printf '%s' "$f"
}
# load_adapter — source the adapter for $LOOP_TOOL (engine seam).
load_adapter() { local f; f="$(adapter_path)" || exit 2; # shellcheck disable=SC1090
  source "$f"; }

require() { command -v "$1" >/dev/null 2>&1 || { log "MISSING: $1 not on PATH"; exit 127; }; }

# Portable wall-clock timeout: GNU `timeout`, else `gtimeout` (macOS coreutils),
# else empty — callers degrade to --max-turns only (no hard kill switch).
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else TIMEOUT_BIN=""; fi
