#!/usr/bin/env bash
# loop/adapters/claude.sh — the Claude Code adapter for the engine seam.
# Contract (shared by every loop/adapters/<tool>.sh):
#   adapter_run <role> <prompt> <logfile>   → resolve engine for role, run headless, write JSON log
#   (Phase 2 will add: adapter_is_limit <logfile> for failover.)
#
# Provider mapping (Claude speaks Anthropic format; OpenAI-format providers go via ccr):
#   frontier → real Anthropic (your subscription); NO ccr; tier→opus/sonnet/haiku
#   glm      → ccr → OpenRouter GLM           ; tier high/mid→glm-5.2, low→glm-4.7
#   local    → ccr → Ollama box               ; single model (LOCAL_MODEL, default qwen3.6:27b)

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

CCR_URL="${CCR_BASE_URL:-http://127.0.0.1:3456}"
OLLAMA_HOST="${OLLAMA_HOST:-ollama-gpu.home.arpa:11434}"
LOCAL_MODEL="${LOCAL_MODEL:-qwen3.6:27b}"

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

# availability incl. cooldown: a cooling-down provider is treated as unavailable.
engine_usable() { engine_in_cooldown "$1" && return 1; engine_available "$1" "$2"; }

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

# Best-effort seconds-until-reset from the error (else empty → default cooldown).
adapter_retry_after() {           # logfile
  grep -oiE 'retry[_-]?after"?[ :=]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1
}

_claude_invoke() {                # provider model prompt logfile
  ( _claude_apply_env "$1"
    # < /dev/null: headless claude otherwise waits on / consumes stdin (flaky/empty output in subshells)
    ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TIMEOUT:-35m}"} claude -p "$3" \
      --model "$2" \
      --permission-mode "${PERMISSION_MODE:-acceptEdits}" \
      ${MAX_BUDGET_USD:+--max-budget-usd "$MAX_BUDGET_USD"} \
      --output-format json < /dev/null > "$4" 2>&1 )
}

# adapter_run <role> <prompt> <logfile>
# Walks the role's engine-chain: skip unavailable/cooling links; run; on a provider
# rate/usage limit, park that provider and fail over to the next link (Phase 2).
adapter_run() {
  local role prompt logf chain spec prov tier model rc OLDIFS
  role="$1"; prompt="$2"; logf="$3"
  chain="$(engine_chain_for_role "$role")"

  OLDIFS="$IFS"; IFS='|'; set -- $chain; IFS="$OLDIFS"
  for spec in "$@"; do
    spec="${spec// /}"
    prov="${spec%%:*}"; if [ "$spec" = "$prov" ]; then tier="high"; else tier="${spec#*:}"; fi
    if ! engine_usable "$prov" "$tier"; then
      engine_in_cooldown "$prov" && log "[engine] $role: '$prov' cooling down — next" \
                                 || log "[engine] $role: '$prov' unavailable — next"
      continue
    fi
    model="$(_claude_model "$prov" "$tier")"
    log "[engine] $role → $prov:$tier  (claude --model $model)"

    if [ "${LOOP_DRYRUN:-0}" = "1" ]; then
      printf 'DRYRUN role=%s tool=claude engine=%s:%s model=%s\n' "$role" "$prov" "$tier" "$model" | tee "$logf"
      return 0
    fi

    _claude_invoke "$prov" "$model" "$prompt" "$logf"; rc=$?
    if adapter_is_limit "$logf"; then
      engine_set_cooldown "$prov" "$(adapter_retry_after "$logf")"
      continue                                   # fail over to the next link
    fi
    return $rc                                   # success / task-failure / our budget cap — stop
  done
  log "[engine] $role: chain exhausted (all unavailable or rate-limited): '$chain'"
  return 1
}
