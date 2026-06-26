#!/usr/bin/env bash
# loop/adapters/codex.sh — STUB (not implemented).
#
# To support driving the loop with OpenAI Codex, implement `adapter_run` with the
# SAME contract as loop/adapters/claude.sh:
#   adapter_run <role> <prompt> <logfile>
#
# Codex-specific notes (the seam exists so the rest of the loop never changes):
#   - Codex is OpenAI-format, so it talks to OpenRouter / Ollama DIRECTLY — no ccr shim.
#     Configure providers in ~/.codex/config.toml (or per-call flags); ccr is Claude-only.
#   - `frontier` here is NOT the Claude subscription (Codex can't use it). Map it to an
#     OpenAI frontier model, or to OpenRouter-served Claude — your choice in this file.
#   - Invocation/budget/permission flags and the JSON result schema differ from Claude;
#     translate them here. Reuse loop/engine.sh (engine_chain_for_role / engine_split /
#     engine_norm_tier) unchanged — only the provider→invocation half is tool-specific.
#   - Roles' system prompts: .claude/agents/*.md is Claude-specific; Codex needs its own
#     role prompts (inline or a codex equivalent). AGENTS.md / LOOPS.md still apply.

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

adapter_run() {
  log "[engine] LOOP_TOOL=codex is not implemented yet — set LOOP_TOOL=claude (see loop/adapters/codex.sh)"
  return 2
}
