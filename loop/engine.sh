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

# Engine routing (.env) is loaded by lib.sh — early, so LOOP_TOOL is set before an
# adapter is chosen. (lib.sh is sourced above when SCAFFOLD_ROOT was unset.)

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

# ── The ONE engine walk (shared adapter_run) ──────────────────────────
# The chain-walk (parse → skip unavailable/cooling → invoke → limit-detect →
# cooldown + failover) lives HERE, once. A tool adapter (loop/adapters/<tool>.sh)
# provides only the tool-specific pieces:
#   ADAPTER_TOOL                        tool name for logs ("claude", "codex", …)
#   engine_available <prov>             can this tool use the provider right now?
#   adapter_invoke <prov> <tier> <prompt> <logfile>    one actual headless run
#   adapter_describe <prov> <tier>      display string for the routing log line
#   adapter_dryrun_tail <prov> <tier>   tail of the DRYRUN line (model=…/flags=…)
#   adapter_is_limit <logfile>          was that a provider rate/usage limit?
#   adapter_retry_after <logfile>       optional override; default below

# Best-effort seconds-until-reset from the error (else empty → default cooldown).
adapter_retry_after() { grep -oiE 'retry[_-]?after"?[ :=]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# ── Engine call log ───────────────────────────────────────────────────
# One JSON line per worker call → loop/logs/calls.jsonl: what was REQUESTED
# (engine + exec string) and what ACTUALLY answered (model ids from the result log —
# claude's modelUsage keys are real dated ids; ccr/codex may route to something else
# than the alias asked for, which is exactly why both sides are recorded).
# Callers set LOOP_PLAN_SLUG so lines are attributable to a plan.
# Also exports ENGINE_LAST_MODEL / ENGINE_LAST_COST / ENGINE_LAST_ENGINE for the
# caller's own bookkeeping (e.g. run-plan.sh's PROGRESS line).
ENGINE_CALLS_LOG="$SCAFFOLD_ROOT/loop/logs/calls.jsonl"

_engine_call_log() {   # role prov tier exec logfile rc kind(run|dryrun|limited)
  local out
  mkdir -p "$(dirname "$ENGINE_CALLS_LOG")"
  out="$(CL_PATH="$ENGINE_CALLS_LOG" CL_LOG="$5" CL_ROLE="$1" CL_TOOL="${ADAPTER_TOOL:-?}" \
         CL_ENGINE="$2:$3" CL_EXEC="$4" CL_RC="$6" CL_KIND="$7" \
         CL_PLAN="${LOOP_PLAN_SLUG:--}" python3 - <<'PY' 2>/dev/null
import json, os, time
e = os.environ
rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "plan": e["CL_PLAN"], "role": e["CL_ROLE"],
       "tool": e["CL_TOOL"], "engine": e["CL_ENGINE"], "exec": e["CL_EXEC"],
       "exit": int(e["CL_RC"]), "kind": e["CL_KIND"],
       "model_actual": "", "cost_usd": None, "turns": None, "duration_ms": None}
if e["CL_KIND"] != "dryrun":
    try:
        raw = open(e["CL_LOG"], errors="replace").read()
        try:                      # claude --output-format json: one result object
            d = json.loads(raw)
            rec["model_actual"] = ",".join(sorted((d.get("modelUsage") or {}).keys()))
            rec["cost_usd"] = d.get("total_cost_usd")
            rec["turns"] = d.get("num_turns")
            rec["duration_ms"] = d.get("duration_ms")
        except ValueError:        # codex --json: JSONL events; best-effort model scrape
            models = set()
            for line in raw.splitlines():
                try: ev = json.loads(line)
                except ValueError: continue
                for k in ("model",):
                    v = ev.get(k) or (ev.get("msg") or {}).get(k) if isinstance(ev, dict) else None
                    if isinstance(v, str): models.add(v)
            rec["model_actual"] = ",".join(sorted(models))
    except OSError:
        pass
with open(e["CL_PATH"], "a") as f:
    f.write(json.dumps(rec) + "\n")
print(f'{rec["model_actual"]}|{rec["cost_usd"] if rec["cost_usd"] is not None else ""}')
PY
)"
  ENGINE_LAST_ENGINE="$2:$3"
  ENGINE_LAST_MODEL="${out%%|*}"
  ENGINE_LAST_COST="${out#*|}"
}

# availability incl. cooldown: a cooling-down provider is treated as unavailable.
engine_usable() { engine_in_cooldown "$1" && return 1; engine_available "$1" "$2"; }

# adapter_run <role> <prompt> <logfile>
# Walks the role's engine-chain: skip unavailable/cooling links; run; on a provider
# rate/usage limit, park that provider (cooldown) and fail over to the next link.
adapter_run() {
  local role prompt logf chain spec prov tier rc OLDIFS
  role="$1"; prompt="$2"; logf="$3"
  chain="$(engine_chain_for_role "$role")"

  OLDIFS="$IFS"; IFS='|'; set -- $chain; IFS="$OLDIFS"
  for spec in "$@"; do
    set -- $(engine_split "$spec"); prov="$1"; tier="${2:-high}"
    if ! engine_usable "$prov" "$tier"; then
      engine_in_cooldown "$prov" && log "[engine] $role: '$prov' cooling down — next" \
                                 || log "[engine] $role: '$prov' unavailable — next"
      continue
    fi
    log "[engine] $role → $prov:$tier  ($(adapter_describe "$prov" "$tier"))"

    if [ "${LOOP_DRYRUN:-0}" = "1" ]; then
      printf 'DRYRUN role=%s tool=%s engine=%s:%s %s\n' \
        "$role" "$ADAPTER_TOOL" "$prov" "$tier" "$(adapter_dryrun_tail "$prov" "$tier")" | tee "$logf"
      _engine_call_log "$role" "$prov" "$tier" "$(adapter_describe "$prov" "$tier")" "$logf" 0 dryrun
      return 0
    fi

    adapter_invoke "$prov" "$tier" "$prompt" "$logf"; rc=$?
    if adapter_is_limit "$logf"; then
      _engine_call_log "$role" "$prov" "$tier" "$(adapter_describe "$prov" "$tier")" "$logf" "$rc" limited
      engine_set_cooldown "$prov" "$(adapter_retry_after "$logf")"
      continue                                   # fail over to the next link
    fi
    _engine_call_log "$role" "$prov" "$tier" "$(adapter_describe "$prov" "$tier")" "$logf" "$rc" run
    return $rc                                   # success / task-failure / our budget cap — stop
  done
  log "[engine] $role: chain exhausted (all unavailable or rate-limited): '$chain'"
  return 1
}
