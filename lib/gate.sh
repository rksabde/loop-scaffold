#!/usr/bin/env bash
# loop/gate.sh — inner self-correction gate.
# Wired to Claude Code's PostToolUse hook (see .claude/settings.json).
# Runs the configured lint/test/typecheck after each agent edit.
# Non-zero exit feeds the failure back into the current turn so the
# agent fixes it before moving on.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR/loop.conf" 2>/dev/null || true

rc=0
run() { [ -n "${1:-}" ] || return 0; echo "› $1"; eval "$1" || rc=1; }

run "${LINT_CMD:-}"
run "${TEST_CMD:-}"
run "${TYPECHECK_CMD:-}"

exit "$rc"
