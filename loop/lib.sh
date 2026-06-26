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

log() { printf '%s  %s\n' "$(date +%FT%T)" "$*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || { log "MISSING: $1 not on PATH"; exit 127; }; }

# Portable wall-clock timeout: GNU `timeout`, else `gtimeout` (macOS coreutils),
# else empty — callers degrade to --max-turns only (no hard kill switch).
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else TIMEOUT_BIN=""; fi
