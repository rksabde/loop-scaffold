#!/usr/bin/env bash
# adapters/claude.sh — the Claude Code adapter for the engine seam.
# The chain-walk (adapter_run) lives ONCE in lib/engine.sh; this file provides only
# the Claude-specific pieces of the contract documented there.
#
# Provider transport (spec §7 — all DIRECT, no ccr daemon):
#   frontier → real Anthropic via your subscription. ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY
#              are unset; if ~/.config/claude/oauth-token exists and CLAUDE_CODE_OAUTH_TOKEN
#              is unset, it is exported from that file for THIS call only (env, never argv,
#              never printed). tier → opus/sonnet/haiku. Never --bare (bare ignores OAuth).
#   glm      → OpenRouter's native Anthropic endpoint: ANTHROPIC_BASE_URL=https://openrouter.ai/api,
#              ANTHROPIC_API_KEY from ~/.config/openrouter/key; high/mid→z-ai/glm-5.2, low→z-ai/glm-4.7.
#   local    → Ollama's native /v1/messages: ANTHROPIC_BASE_URL=http://$OLLAMA_HOST,
#              ANTHROPIC_API_KEY=ollama; model $LOCAL_MODEL (default gpt-oss:20b on localhost).
#   glm/local explicitly unset CLAUDE_CODE_OAUTH_TOKEN (the subscription token never goes to 3P).
#
# Every worker call attaches the loop harness for this session only:
#   --plugin-dir $LOOP_HOME/plugin            roles (agents/) + the PostToolUse gate (hooks/)
#   --append-system-prompt-file templates/LOOPS.md   the loop protocol (not written into projects)
#   --setting-sources project --strict-mcp-config    don't inherit the human's plugins/skills/MCP
#   env LOOP_WORKER=1 LOOP_HOME LOOP_PROJECT_ROOT    arms the gate (no-op without LOOP_WORKER=1)
#
# --bare (glm/local only — hermetic, ~32k fewer context tokens per call; spec §7.5):
#   `claude --help` says --bare skips hooks and plugin sync but still honours an explicit
#   --plugin-dir. Probed 2026-10-01 (Claude Code 2.1.233, plan 010 Progress):
#     * WITHOUT --bare, --plugin-dir + LOOP_WORKER=1: gate hook FIRED (marker written).
#     * WITH --bare --plugin-dir: see LOOP_BARE_EXECUTOR below for the recorded outcome.
#   Policy: --bare for glm/local on every role EXCEPT the executor ('engineer') unless
#   LOOP_BARE_EXECUTOR=1, because the executor is the role that needs the edit gate.
#   verifier/planner never edit through the gate, so they always take --bare on 3P engines.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/engine.sh"

ADAPTER_TOOL="claude"
OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
LOCAL_MODEL="${LOCAL_MODEL:-gpt-oss:20b}"
OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api}"
OPENROUTER_KEY_FILE="${OPENROUTER_KEY_FILE:-$HOME/.config/openrouter/key}"
CLAUDE_TOKEN_FILE="${CLAUDE_TOKEN_FILE:-$HOME/.config/claude/oauth-token}"
LOOP_BARE_EXECUTOR="${LOOP_BARE_EXECUTOR:-0}"

# (provider, tier) -> the value for `claude --model`
_claude_model() {
  local prov tier; prov="$1"; tier="$(engine_norm_tier "$2")"
  case "$prov" in
    frontier) case "$tier" in high) echo opus;; mid) echo sonnet;; low) echo haiku;; *) echo "$tier";; esac ;;
    glm)      case "$tier" in low) echo "z-ai/glm-4.7";; *) echo "z-ai/glm-5.2";; esac ;;
    local)    echo "$LOCAL_MODEL" ;;
    *)        echo "$tier" ;;   # treat as a concrete claude model id
  esac
}

# provider -> transport label (dry-run line + call log exec string)
_claude_transport() {
  case "$1" in
    frontier) echo subscription ;;
    glm)      echo direct-openrouter ;;
    local)    echo direct-ollama ;;
    *)        echo unknown ;;
  esac
}

# Should this call run --bare? (3P engines only; executor only when opted in)
_claude_bare() {    # provider -> 0 (yes) / 1 (no)
  case "$1" in glm|local) ;; *) return 1 ;; esac
  [ "${ENGINE_ROLE:-}" = "engineer" ] && [ "$LOOP_BARE_EXECUTOR" != "1" ] && return 1
  return 0
}

# Can the Claude tool use this provider right now? (availability gating)
# Only frontier|glm|local are valid for the claude adapter; anything else is
# unavailable so a misconfigured chain link is skipped, not run with a bogus model.
engine_available() {
  case "$1" in
    frontier) return 0 ;;                                   # subscription assumed present
    glm)      [ -s "$OPENROUTER_KEY_FILE" ] ;;
    local)    curl -s --max-time 3 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1 ;;
    *)        log "[engine] unknown provider '$1' (claude adapter knows frontier|glm|local)"; return 1 ;;
  esac
}

# Point Claude at the right endpoint for the chosen provider. Runs INSIDE the
# adapter_invoke subshell, so nothing leaks into the caller's environment.
_claude_apply_env() {
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
  case "$1" in
    frontier)
      if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -s "$CLAUDE_TOKEN_FILE" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$(tr -d ' \n\r' < "$CLAUDE_TOKEN_FILE")"; export CLAUDE_CODE_OAUTH_TOKEN
      fi ;;
    glm)
      unset CLAUDE_CODE_OAUTH_TOKEN
      ANTHROPIC_API_KEY="$(tr -d ' \n\r' < "$OPENROUTER_KEY_FILE")"
      export ANTHROPIC_BASE_URL="$OPENROUTER_BASE_URL" ANTHROPIC_API_KEY ;;
    local)
      unset CLAUDE_CODE_OAUTH_TOKEN
      export ANTHROPIC_BASE_URL="http://$OLLAMA_HOST" ANTHROPIC_API_KEY="ollama" ;;
  esac
  export LOOP_WORKER=1 LOOP_HOME LOOP_PROJECT_ROOT
}

# Is this result a provider RATE/USAGE limit (→ fail over)? NOT our budget cap, NOT a task failure.
adapter_is_limit() {              # logfile
  grep -q '"subtype":"error_max_budget_usd"' "$1" 2>/dev/null && return 1   # our cap, not a provider limit
  grep -qiE 'usage limit|rate[ _-]?limit|"type":"?(overloaded|rate_limit)|too many requests|429|quota.?exceeded' "$1" 2>/dev/null
}

adapter_describe() {
  local bare=""; _claude_bare "$1" && bare=" --bare"
  echo "claude --model $(_claude_model "$1" "$2")$bare [$(_claude_transport "$1")]"
}
adapter_dryrun_tail() { echo "model=$(_claude_model "$1" "$2") transport=$(_claude_transport "$1")"; }

adapter_invoke() {                # provider tier prompt logfile
  local model bare=()
  model="$(_claude_model "$1" "$2")"
  _claude_bare "$1" && bare=(--bare)
  ( _claude_apply_env "$1"
    # < /dev/null: headless claude otherwise waits on / consumes stdin (flaky/empty output in subshells)
    ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TIMEOUT:-35m}"} claude -p "$3" \
      ${bare[@]+"${bare[@]}"} \
      --model "$model" \
      --plugin-dir "$LOOP_HOME/plugin" \
      --append-system-prompt-file "$LOOP_HOME/templates/LOOPS.md" \
      --setting-sources project --strict-mcp-config \
      --permission-mode "${PERMISSION_MODE:-acceptEdits}" \
      ${MAX_BUDGET_USD:+--max-budget-usd "$MAX_BUDGET_USD"} \
      --output-format json < /dev/null > "$4" 2>&1 )
}
