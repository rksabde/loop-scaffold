#!/usr/bin/env bash
# lib/gate.sh — inner self-correction gate.
# Wired as the PostToolUse hook of the loop plugin (plugin/hooks/hooks.json), which the
# claude adapter attaches to every worker via --plugin-dir. Runs the configured
# lint/test/typecheck after each agent edit.
#
# Exit codes (Claude Code PostToolUse semantics): 0 = pass. On failure we exit 2 with the
# failing commands' output on STDERR — exit 2 is the code whose stderr Claude Code feeds
# back to the MODEL; exit 1 only shows it to the user, so the executor never saw the
# failure (finding from plan 010). VERIFIED 2026-10-01 (Claude Code 2.1.233, plan 014): plain
# exit 2 + stderr is enough — no JSON {"decision":"block"} needed. Real frontier/sonnet run as
# --agent engineer with TEST_CMD='test -f must-exist.txt', told only "create hello.txt; if a hook
# reports a failing check, create whatever file it says is missing": it created must-exist.txt
# (a name it could only learn from this hook's stderr) in 5 turns, $0.096.
#
# Guard: a NO-OP (exit 0, no git/config work) unless LOOP_WORKER=1 — the plugin may also be
# installed for interactive sessions, where the gate stays off (interactive opt-in = plan 015).
[ "${LOOP_WORKER:-0}" = "1" ] || exit 0
set -uo pipefail

# Config comes from the WORKTREE's own toplevel (the hook runs with cwd = the worker's
# checkout), so a branch that changes LINT_CMD is judged by its own loop.conf (spec §5.2).
# Fallback: the main checkout exported by the adapter.
DIR="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${LOOP_PROJECT_ROOT:-$PWD}")"
# shellcheck disable=SC1091
source "$DIR/loop.conf" 2>/dev/null || true

# Heartbeat: records that the gate fired in a worker (diagnostics / hook-wiring probes).
if [ -n "${LOOP_PROJECT_ROOT:-}" ] && [ -d "$LOOP_PROJECT_ROOT/.loop" ]; then
  date +%FT%T > "$LOOP_PROJECT_ROOT/.loop/gate-fired" 2>/dev/null || true
fi

rc=0
out=""
run() {
  [ -n "${1:-}" ] || return 0
  local o
  if ! o="$( (cd "$DIR" && eval "$1") 2>&1 )"; then
    rc=2
    out="${out}loop gate FAILED: \`$1\`
${o:-(no output)}
"
  fi
}

run "${LINT_CMD:-}"
run "${TEST_CMD:-}"
run "${TYPECHECK_CMD:-}"

if [ "$rc" -ne 0 ]; then
  printf '%s\nFix the failing check(s) above before continuing.\n' "$out" >&2
fi
exit "$rc"
