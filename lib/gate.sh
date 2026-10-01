#!/usr/bin/env bash
# lib/gate.sh — inner self-correction gate.
# Wired as the PostToolUse hook of the loop plugin (plugin/hooks/hooks.json), which the
# claude adapter attaches to every worker via --plugin-dir. Runs the configured
# lint/test/typecheck after each agent edit; non-zero exit surfaces the failure in the turn.
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
run() { [ -n "${1:-}" ] || return 0; echo "› $1"; (cd "$DIR" && eval "$1") || rc=1; }

run "${LINT_CMD:-}"
run "${TEST_CMD:-}"
run "${TYPECHECK_CMD:-}"

exit "$rc"
