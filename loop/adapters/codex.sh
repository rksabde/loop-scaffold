#!/usr/bin/env bash
# loop/adapters/codex.sh — OpenAI Codex adapter for the engine seam.
# The chain-walk (adapter_run) lives ONCE in loop/engine.sh; this file provides only
# the Codex-specific pieces of the contract documented there.
#
# Codex is OpenAI-native, so OpenAI-format providers go DIRECT — no ccr shim:
#   frontier → OpenAI (Codex's configured model, e.g. gpt-5.5); tier → reasoning effort
#   local    → Ollama via Codex's native `--oss --local-provider ollama`
#   glm      → OpenRouter: NOT wired here (configure model_providers in ~/.codex/config.toml,
#              then add a case below). Treated as unavailable so chains skip it.
#
# Cross-tool caveats (the loop SHAPE transfers; Claude-only niceties don't):
#   - `.claude/agents/*.md` subagents and the `.claude/settings.json` PostToolUse gate are
#     no-ops under Codex. The executor still edits in its worktree and the harness commits;
#     the verifier runs from its prompt without a formal subagent (and is sandbox-bounded,
#     not tool-restricted read-only).
#   - Codex headless = `codex exec`, output is JSONL (`--json`) + last message (`-o`).
#   - No `--max-budget-usd` equivalent; bound via the task + sandbox, not a $ cap.

source "$(dirname "${BASH_SOURCE[0]}")/../engine.sh"

ADAPTER_TOOL="codex"
OLLAMA_HOST="${OLLAMA_HOST:-ollama-gpu.home.arpa:11434}"
LOCAL_MODEL="${LOCAL_MODEL:-qwen3.6:27b}"

# Can the Codex tool use this provider right now?
engine_available() {
  command -v codex >/dev/null 2>&1 || { log "[engine] codex not on PATH"; return 1; }
  case "$1" in
    frontier) return 0 ;;                                            # OpenAI auth via `codex login`
    local)    curl -s --max-time 3 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1 ;;
    glm)      log "[engine] codex: 'glm' not wired — set up model_providers.openrouter in ~/.codex/config.toml"; return 1 ;;
    *)        log "[engine] codex: unknown provider '$1'"; return 1 ;;
  esac
}

# (provider, tier) -> codex flags (model / provider / reasoning effort)
_codex_flags() {
  local prov tier eff; prov="$1"; tier="$(engine_norm_tier "$2")"
  case "$prov" in
    frontier)
      case "$tier" in high) eff=high;; mid) eff=medium;; low) eff=low;; *) eff="$tier";; esac
      printf -- '-c model_reasoning_effort=%s' "$eff"
      [ -n "${CODEX_FRONTIER_MODEL:-}" ] && printf -- ' -m %s' "$CODEX_FRONTIER_MODEL"   # else config default (e.g. gpt-5.5)
      ;;
    local)  printf -- '--oss --local-provider ollama -m %s' "$LOCAL_MODEL" ;;
  esac
}

# Is this run a provider rate/usage limit (→ fail over)?
adapter_is_limit() {              # logfile (codex JSONL)
  grep -qiE 'rate.?limit|usage limit|insufficient_quota|quota.?exceeded|"status":429|too many requests' "$1" 2>/dev/null
}

adapter_describe()    { echo "codex exec $(_codex_flags "$1" "$2")"; }
adapter_dryrun_tail() { echo "flags=[$(_codex_flags "$1" "$2")]"; }

adapter_invoke() {                # provider tier prompt logfile
  local flags sandbox
  flags="$(_codex_flags "$1" "$2")"
  sandbox="-s ${CODEX_SANDBOX:-workspace-write}"
  [ "${CODEX_FULL_AUTO:-0}" = "1" ] && sandbox="--dangerously-bypass-approvals-and-sandbox"
  ${TIMEOUT_BIN:+$TIMEOUT_BIN "${TIMEOUT:-35m}"} \
    codex exec "$3" $flags $sandbox \
      --skip-git-repo-check -C "$PWD" --json -o "$4.last" \
      < /dev/null > "$4" 2>&1
}
