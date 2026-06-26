#!/usr/bin/env bash
# loop/adapters/opencode.sh — STUB (not implemented).
# Implement `adapter_run <role> <prompt> <logfile>` per the contract in
# loop/adapters/claude.sh. OpenCode reads AGENTS.md natively and targets many providers;
# like Codex it is OpenAI-format (no ccr needed). Reuse loop/engine.sh unchanged.

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

adapter_run() {
  log "[engine] LOOP_TOOL=opencode is not implemented yet — set LOOP_TOOL=claude"
  return 2
}
