#!/usr/bin/env bash
# loop/adapters/claude.sh — the Claude Code adapter for the engine seam.
# The chain-walk (adapter_run) lives ONCE in loop/engine.sh; this file provides only
# the Claude-specific pieces of the contract documented there.
#
# Provider mapping (Claude speaks Anthropic format; OpenAI-format providers go via ccr):
#   frontier → real Anthropic (your subscription); NO ccr; tier→opus/sonnet/haiku
#   glm      → ccr → OpenRouter GLM           ; tier high/mid→glm-5.2, low→glm-4.7
#   local    → ccr → Ollama box               ; single model (LOCAL_MODEL, default gpt-oss:20b on localhost)

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

ADAPTER_TOOL="claude"
CCR_URL="${CCR_BASE_URL:-http://127.0.0.1:3456}"
OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
LOCAL_MODEL="${LOCAL_MODEL:-gpt-oss:20b}"

_ccr_up() { command -v ccr >/dev/null 2>&1 || return 1; ccr status >/dev/null 2>&1 || ccr start >/dev/null 2>&1; ccr status >/dev/null 2>&1; }

# (provider, tier) -> the value for `claude --model`
_claude_model() {
  local prov tier; prov="$1"; tier="$(engine_norm_tier "$2")"
  case "$prov" in
    frontier) case "$tier" in high) echo opus;; mid) echo sonnet;; low) echo haiku;; *) echo "$tier";; esac ;;
    glm)      case "$tier" in low) echo "openrouter,z-ai/glm-4.7";; *) echo "openrouter,z-ai/glm-5.2";; esac ;;
    local)    echo "ollama,$LOCAL_MODEL" ;;
    *)        echo "$tier" ;;   # treat as a concrete claude model id
  esac
}

# Can the Claude tool use this provider right now? (availability gating)
# Only frontier|glm|local are valid for the claude adapter; anything else is
# unavailable so a misconfigured chain link is skipped, not run with a bogus model.
engine_available() {
  case "$1" in
    frontier) return 0 ;;                                   # subscription assumed present
    glm)      [ -s "$HOME/.config/openrouter/key" ] && _ccr_up ;;
    local)    curl -s --max-time 3 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && _ccr_up ;;
    *)        log "[engine] unknown provider '$1' (claude adapter knows frontier|glm|local)"; return 1 ;;
  esac
}

# Point Claude at the right endpoint for the chosen provider.
_claude_apply_env() {
  case "$1" in
    frontier)  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ;;
    glm|local) export ANTHROPIC_BASE_URL="$CCR_URL" ANTHROPIC_AUTH_TOKEN="ccr" ;;
  esac
}

# Is this result a provider RATE/USAGE limit (→ fail over)? NOT our budget cap, NOT a task failure.
adapter_is_limit() {              # logfile
  grep -q '"subtype":"error_max_budget_usd"' "$1" 2>/dev/null && return 1   # our cap, not a provider limit
  grep -qiE 'usage limit|rate[ _-]?limit|"type":"?(overloaded|rate_limit)|too many requests|429|quota.?exceeded' "$1" 2>/dev/null
}

adapter_describe()    { echo "claude --model $(_claude_model "$1" "$2")"; }
adapter_dryrun_tail() { echo "model=$(_claude_model "$1" "$2")"; }

adapter_invoke() {                # provider tier prompt logfile
  local model; model="$(_claude_model "$1" "$2")"
  ( _claude_apply_env "$1"
    # < /dev/null: headless claude otherwise waits on / consumes stdin (flaky/empty output in subshells)
    ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TIMEOUT:-35m}"} claude -p "$3" \
      --model "$model" \
      --permission-mode "${PERMISSION_MODE:-acceptEdits}" \
      ${MAX_BUDGET_USD:+--max-budget-usd "$MAX_BUDGET_USD"} \
      --output-format json < /dev/null > "$4" 2>&1 )
}
