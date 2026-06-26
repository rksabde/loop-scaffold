#!/usr/bin/env bash
# loop/engine.sh — tool-AGNOSTIC engine resolution.
# Maps an agent role -> an engine-chain ("provider:tier|provider:tier|...").
# The tool-SPECIFIC half (provider -> auth/model/invocation) lives in
# loop/adapters/<tool>.sh. Sourced by the adapters; never calls a tool itself.
#
# Config (in .env, machine-specific, gitignored):
#   LOOP_TOOL=claude|codex|opencode        (default: claude)
#   LOOP_ENGINE_DEFAULT="frontier:high"    (fallback for any unset role)
#   LOOP_ENGINE_ENGINEER / _RESEARCHER / _VERIFIER / _PLANNER / _INTEGRATOR=...
# Tiers are canonical high|mid|low; opus|sonnet|haiku are accepted as aliases.

[ -n "${SCAFFOLD_ROOT:-}" ] || source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Engine routing lives in .env (separate from loop.conf, which holds caps/test cmds).
if [ -f "$SCAFFOLD_ROOT/.env" ]; then
  set -a; # shellcheck disable=SC1091
  . "$SCAFFOLD_ROOT/.env"; set +a
fi

# high|mid|low ; opus|sonnet|haiku aliased; anything else passed through (concrete model).
engine_norm_tier() {
  case "$1" in
    high|opus)  echo high ;;
    mid|sonnet) echo mid  ;;
    low|haiku)  echo low  ;;
    *)          echo "$1" ;;
  esac
}

# Resolve the engine-chain for a role: per-role var > default > built-in.
# Built-in default is frontier:high. VERIFIER and PLANNER are *protected*: unless
# explicitly set they stay frontier:high even when LOOP_ENGINE_DEFAULT is cheap — a
# cheap fleet must never silently grade itself (verifier) or plan without vision
# (planner reads decks/images; cheap/local can't).
engine_chain_for_role() {
  local role_uc var val
  role_uc="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  var="LOOP_ENGINE_${role_uc}"
  eval "val=\${$var:-}"
  if [ -n "$val" ]; then printf '%s' "$val"; return; fi
  case "$role_uc" in VERIFIER|PLANNER) printf 'frontier:high'; return ;; esac
  printf '%s' "${LOOP_ENGINE_DEFAULT:-frontier:high}"
}

# Split one "provider:tier" spec into "$provider $tier" (split on FIRST colon so a
# concrete model with its own colon survives, e.g. local:qwen3.6:27b). Missing tier -> high.
engine_split() {
  local spec prov tier
  spec="$(printf '%s' "$1" | tr -d ' ')"
  prov="${spec%%:*}"
  if [ "$spec" = "$prov" ]; then tier="high"; else tier="${spec#*:}"; fi
  printf '%s %s' "$prov" "$tier"
}

# ── Failover cooldown state (Phase 2) ─────────────────────────────────
# A provider that hits a rate/usage limit is parked in loop/state/<provider>.cooldown
# (a blocked-until epoch). The resolver treats a cooling provider as unavailable and
# falls to the next chain link; it auto-recovers when the timestamp passes.
ENGINE_STATE_DIR="$SCAFFOLD_ROOT/loop/state"
LOOP_COOLDOWN_MIN="${LOOP_COOLDOWN_MIN:-60}"   # default cooldown when no reset time is known

engine_in_cooldown() {            # provider -> 0 (true) if currently cooling down
  local f="$ENGINE_STATE_DIR/$1.cooldown" until now
  [ -f "$f" ] || return 1
  until="$(cat "$f" 2>/dev/null)"; now="$(date +%s)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -lt "$until" ]
}

engine_set_cooldown() {           # provider [seconds]
  local secs until
  secs="${2:-$((LOOP_COOLDOWN_MIN*60))}"
  case "$secs" in ''|*[!0-9]*) secs=$((LOOP_COOLDOWN_MIN*60)) ;; esac
  mkdir -p "$ENGINE_STATE_DIR"
  until=$(( $(date +%s) + secs ))
  echo "$until" > "$ENGINE_STATE_DIR/$1.cooldown"
  log "[engine] $1 parked for ${secs}s (cooldown) — failing over"
}

engine_clear_cooldown() { rm -f "$ENGINE_STATE_DIR/$1.cooldown" 2>/dev/null; }   # provider
