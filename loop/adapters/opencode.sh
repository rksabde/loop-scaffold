#!/usr/bin/env bash
# loop/adapters/opencode.sh — STUB (not implemented; opencode not installed locally).
# To implement: provide the pieces of the contract documented in loop/engine.sh
# (ADAPTER_TOOL, engine_available, adapter_invoke, adapter_describe,
# adapter_dryrun_tail, adapter_is_limit). OpenCode reads AGENTS.md natively and is
# OpenAI-format (no ccr needed); the shared adapter_run in engine.sh does the rest.

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

ADAPTER_TOOL="opencode"

engine_available() {
  log "[engine] LOOP_TOOL=opencode is not implemented yet — set LOOP_TOOL=claude (or codex)"
  return 1     # every chain link unavailable → adapter_run exhausts gracefully
}
adapter_describe()    { echo "opencode (stub)"; }
adapter_dryrun_tail() { echo "stub"; }
adapter_invoke()      { return 2; }
adapter_is_limit()    { return 1; }
