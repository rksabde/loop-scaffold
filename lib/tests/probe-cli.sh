#!/usr/bin/env bash
# loop/tests/probe-cli.sh — answers the six CLI unknowns the machine-installed design
# depends on (docs/SPEC-distribution-and-harness.md §7). Prints exactly six "PROBE n:"
# result lines (+ indented detail). RUN FROM YOUR OWN LOGGED-IN TERMINAL — nested or
# sandboxed contexts fail "Not logged in". Spend: a handful of haiku "pong"-sized calls.
#
#   ./loop/tests/probe-cli.sh                 # full run
#   PROBE_OFFLINE=1 ./loop/tests/probe-cli.sh # build + validate the probe plugin only
#
# Never prints secrets: the OpenRouter key is fed to curl via stdin config, and only
# extracted fields (status, type, first chars of text) are ever echoed.
set -uo pipefail

MODEL="${PROBE_MODEL:-haiku}"
OFFLINE="${PROBE_OFFLINE:-0}"
OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
LOCAL_MODEL="${LOCAL_MODEL:-gpt-oss:20b}"
CCR_URL="${CCR_BASE_URL:-http://127.0.0.1:3456}"
OR_KEY_FILE="${OR_KEY_FILE:-$HOME/.config/openrouter/key}"
OR_MODEL="${OR_MODEL:-z-ai/glm-4.7}"
MARK="PROBE-MARKER-7391"
OUT="${PROBE_OUT:-/tmp/loop-probe-results.txt}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
: > "$OUT"
say()    { printf '%s\n' "$*" | tee -a "$OUT"; }
detail() { printf '    · %s\n' "$*" | tee -a "$OUT"; }
tlimit() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }   # portable timeout
# frontier call = strip any proxy/env overrides so the subscription login is used.
# Headless/nested contexts (desktop-app sessions, launchd, CI) often cannot use the
# keychain login. If a long-lived token from `claude setup-token` was saved (0600) at
# $CLAUDE_TOKEN_FILE, pass it via env — read at exec time, never echoed.
CLAUDE_TOKEN_FILE="${CLAUDE_TOKEN_FILE:-$HOME/.config/claude/oauth-token}"
# (exported, not passed as an argv element — argv is visible in `ps`.)
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -s "$CLAUDE_TOKEN_FILE" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\n\r ' < "$CLAUDE_TOKEN_FILE")"; export CLAUDE_CODE_OAUTH_TOKEN
fi
CL=(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY claude)

# ── analysis helper (python3 stdlib) ─────────────────────────────────────────
cat > "$T/an.py" <<'PY'
import json, sys
def events(path):
    raw = open(path, errors="replace").read()
    try:
        d = json.loads(raw); return d if isinstance(d, list) else [d]
    except ValueError:
        out = []
        for line in raw.splitlines():
            try: out.append(json.loads(line))
            except ValueError: pass
        return out
def result_ev(evs):
    for e in reversed(evs):
        if isinstance(e, dict) and e.get("type") == "result": return e
    return None
cmd, path = sys.argv[1], sys.argv[2]
evs = events(path); res = result_ev(evs)
if cmd == "result":                      # -> "ok|<text>" / "err|<text>" / "none|<raw head>"
    if res is None:
        print("none|" + open(path, errors="replace").read()[:240].replace("\n", " ")); sys.exit(0)
    txt = str(res.get("result") or "").replace("\n", " ")[:240]
    print(("err|" if res.get("is_error") else "ok|") + txt)
elif cmd == "hasmark":
    mark = sys.argv[3]
    sys.exit(0 if (res and mark in str(res.get("result") or "")) else 1)
elif cmd == "init":                      # list-valued keys of the init event -> {key: count}
    for e in evs:
        if isinstance(e, dict) and e.get("type") == "system" and e.get("subtype") == "init":
            print(json.dumps({k: len(v) for k, v in e.items() if isinstance(v, list)})); break
    else:
        print("{}")
elif cmd == "schema":                    # where does a dict containing "verdict" land?
    hits = []
    def walk(o, p):
        if isinstance(o, dict):
            if "verdict" in o: hits.append(p or "<root>")
            for k, v in o.items(): walk(v, f"{p}.{k}" if p else k)
        elif isinstance(o, list):
            for i, v in enumerate(o): walk(v, f"{p}[{i}]")
    if res is not None:
        walk({k: v for k, v in res.items()}, "")
        try:
            if "verdict" in json.loads(res.get("result") or ""): hits.append("result (JSON string)")
        except (ValueError, TypeError): pass
    print("keys=" + ",".join(sorted(res.keys())) if res else "keys=<no result event>")
    print("paths=" + (" ; ".join(hits) if hits else "<none>"))
elif cmd == "msg":                       # raw Anthropic Messages API response
    try:
        d = json.loads(open(path, errors="replace").read())
        blocks = d.get("content") or []
        text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict))[:60].replace("\n", " ")
        print(f'type={d.get("type")} blocks={len(blocks)} text="{text}"' if d.get("type") == "message"
              else f'type={d.get("type")} error={str(d.get("error"))[:120]}')
        sys.exit(0 if d.get("type") == "message" else 1)
    except ValueError:
        print("non-JSON body: " + open(path, errors="replace").read()[:120].replace("\n", " ")); sys.exit(1)
PY
an() { python3 "$T/an.py" "$@"; }

# ── throwaway plugin + project ───────────────────────────────────────────────
P="$T/plug"; mkdir -p "$P/.claude-plugin" "$P/agents" "$P/hooks" "$T/proj"
cat > "$P/.claude-plugin/plugin.json" <<'J'
{ "name": "loopprobe", "version": "0.0.1", "description": "Throwaway plugin for loop-scaffold CLI capability probes." }
J
cat > "$P/agents/engineer.md" <<A
---
name: engineer
description: Probe agent used to test how plugin-provided agents resolve.
---
You are a probe agent. End EVERY reply with the exact token $MARK on its own line.
A
cat > "$P/hook.sh" <<'H'
#!/usr/bin/env bash
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
touch "$d/../hook-fired-root"
printf '%s' "${CLAUDE_PLUGIN_ROOT:-unset}" > "$d/../plugin-root-env"
H
cat > "$P/hooks/hooks.json" <<J
{ "hooks": { "PostToolUse": [ { "matcher": "Write|Edit", "hooks": [
  { "type": "command", "command": "bash \"\${CLAUDE_PLUGIN_ROOT}/hook.sh\"" },
  { "type": "command", "command": "touch '$T/hook-fired-abs'" } ] } ] } }
J
( cd "$T/proj" && git init -q . 2>/dev/null )

say "claude: $(claude --version 2>/dev/null | head -1)   model: $MODEL   results → $OUT"
v="$(claude plugin validate "$P" 2>&1 | tail -2 | tr '\n' ' ')"
say "probe plugin validate: ${v:-<no output>}"

if [ "$OFFLINE" = "1" ]; then
  for n in 1 2 3 4 5 6; do say "PROBE $n: SKIPPED (PROBE_OFFLINE=1)"; done; exit 0
fi

# ── preflight = probe 3 baseline (doubles as the auth check) ─────────────────
( cd "$T/proj" && tlimit 180 "${CL[@]}" -p "Reply with exactly: pong" --model "$MODEL" \
    --output-format stream-json --verbose < /dev/null > "$T/p3-base.jsonl" 2>&1 )
base="$(an result "$T/p3-base.jsonl")"
AUTH_OK=1
case "$base" in ok\|*) ;; *) AUTH_OK=0 ;; esac

if [ "$AUTH_OK" = 0 ]; then
  say "PREFLIGHT FAILED — frontier call did not succeed: ${base#*|}"
  say "  (auth problem, not a probe result. Own terminal: run \`claude\` → /login. Nested/headless context:"
  say "   \`claude setup-token\`, save the token to $CLAUDE_TOKEN_FILE (chmod 600) — this script picks it up.)"
  for n in 1 2 3 4 5; do say "PROBE $n: ABORTED (preflight auth failure)"; done
else
  # ── PROBE 1: does --agent resolve a PLUGIN-provided agent, and under which name? ──
  got=""
  for name in engineer loopprobe:engineer; do
    ( cd "$T/proj" && tlimit 180 "${CL[@]}" -p "Say hello in three words." --plugin-dir "$P" --agent "$name" \
        --model "$MODEL" --output-format json < /dev/null > "$T/p1-$name.json" 2>&1 )
    if an hasmark "$T/p1-$name.json" "$MARK"; then got="$name"; break; fi
    detail "--agent $name → no marker ($(an result "$T/p1-$name.json" | cut -c1-110))"
  done
  if [ -n "$got" ]; then
    say "PROBE 1: PASS — plugin agent resolves as --agent '$got'"
  else
    printf 'You are a probe. End EVERY reply with the exact token %s on its own line.\n' "$MARK" > "$T/sys.txt"
    ( cd "$T/proj" && tlimit 180 "${CL[@]}" -p "Say hello in three words." --append-system-prompt-file "$T/sys.txt" \
        --model "$MODEL" --output-format json < /dev/null > "$T/p1-fallback.json" 2>&1 )
    if an hasmark "$T/p1-fallback.json" "$MARK"; then
      say "PROBE 1: FAIL — --agent does not pick up plugin agents; fallback --append-system-prompt-file WORKS (use it + --tools)"
    else
      say "PROBE 1: FAIL — neither --agent nor --append-system-prompt-file showed the marker ($(an result "$T/p1-fallback.json" | cut -c1-110))"
    fi
  fi

  # ── PROBE 2: plugin hooks fire under -p, and ${CLAUDE_PLUGIN_ROOT} expands ──
  ( cd "$T/proj" && tlimit 240 "${CL[@]}" -p "Use the Write tool to create a file named probe.txt containing the single word hi. Then reply done." \
      --plugin-dir "$P" --permission-mode acceptEdits --model "$MODEL" --output-format json < /dev/null > "$T/p2.json" 2>&1 )
  if [ ! -f "$T/proj/probe.txt" ]; then
    say "PROBE 2: INCONCLUSIVE — the model never wrote probe.txt ($(an result "$T/p2.json" | cut -c1-110)); re-run"
  elif [ -f "$T/hook-fired-root" ]; then
    say "PROBE 2: PASS — plugin hook fires under -p and \${CLAUDE_PLUGIN_ROOT} expands (env inside hook: $(cat "$T/plugin-root-env" 2>/dev/null | sed "s|$T|<tmp>|"))"
  elif [ -f "$T/hook-fired-abs" ]; then
    say "PROBE 2: PARTIAL — plugin hook fires, but \${CLAUDE_PLUGIN_ROOT} did NOT resolve in the command → use absolute paths / exported LOOP_HOME"
  else
    rm -f "$T/proj/probe.txt"
    sj="{\"hooks\":{\"PostToolUse\":[{\"matcher\":\"Write|Edit\",\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$T/hook-fired-settings'\"}]}]}}"
    ( cd "$T/proj" && tlimit 240 "${CL[@]}" -p "Use the Write tool to create a file named probe.txt containing the single word hi. Then reply done." \
        --settings "$sj" --permission-mode acceptEdits --model "$MODEL" --output-format json < /dev/null > "$T/p2b.json" 2>&1 )
    if [ -f "$T/hook-fired-settings" ]; then
      say "PROBE 2: FAIL — --plugin-dir hooks do not fire under -p; fallback --settings '<hooks json>' WORKS"
    else
      say "PROBE 2: FAIL — neither plugin hooks nor --settings hooks fired under -p"
    fi
  fi

  # ── PROBE 3: --setting-sources project (+ --strict-mcp-config): auth survives, user scope dropped ──
  ( cd "$T/proj" && tlimit 180 "${CL[@]}" -p "Reply with exactly: pong" --model "$MODEL" \
      --setting-sources project --strict-mcp-config \
      --output-format stream-json --verbose < /dev/null > "$T/p3-slim.jsonl" 2>&1 )
  slim="$(an result "$T/p3-slim.jsonl")"
  bi="$(an init "$T/p3-base.jsonl")"; si="$(an init "$T/p3-slim.jsonl")"
  detail "init lists  default: $bi"
  detail "init lists  slim:    $si"
  cmp="$(python3 - "$bi" "$si" <<'PY'
import json, sys
b, s = json.loads(sys.argv[1] or "{}"), json.loads(sys.argv[2] or "{}")
watch = [k for k in b if k != "tools"]
print("shrunk" if sum(s.get(k, 0) for k in watch) < sum(b.get(k, 0) for k in watch) else "same")
PY
)"
  case "$slim" in
    ok\|*) if [ "$cmp" = shrunk ]; then say "PROBE 3: PASS — subscription auth survives and user-scope items are dropped"
           else say "PROBE 3: PARTIAL — auth survives but the init lists did not shrink (flag has no slimming effect here)"; fi ;;
    *)     say "PROBE 3: FAIL — call failed under --setting-sources project: ${slim#*|}" ;;
  esac

  # ── PROBE 4: --json-schema + stream-json — where does the validated object land? ──
  schema='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]}},"required":["verdict"],"additionalProperties":false}'
  ( cd "$T/proj" && tlimit 180 "${CL[@]}" -p "Return the verdict PASS." --json-schema "$schema" --model "$MODEL" \
      --output-format stream-json --verbose < /dev/null > "$T/p4.jsonl" 2>&1 )
  p4="$(an schema "$T/p4.jsonl")"
  detail "$(printf '%s' "$p4" | sed -n 1p)"
  paths="$(printf '%s' "$p4" | sed -n 2p)"
  case "$paths" in
    "paths=<none>") say "PROBE 4: FAIL — no object with 'verdict' in the final result event ($(an result "$T/p4.jsonl" | cut -c1-110))" ;;
    *)              say "PROBE 4: PASS — structured output found at ${paths#paths=}" ;;
  esac

  # ── PROBE 5: --bare + ANTHROPIC_BASE_URL(ccr) + dummy ANTHROPIC_API_KEY ──
  m=""
  if command -v ccr >/dev/null 2>&1 && { ccr status >/dev/null 2>&1 || ccr start >/dev/null 2>&1; }; then
    if curl -s --max-time 4 "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then m="ollama,$LOCAL_MODEL"
    elif [ -s "$OR_KEY_FILE" ]; then m="openrouter,$OR_MODEL"; fi
  fi
  if [ -z "$m" ]; then
    say "PROBE 5: SKIPPED — ccr not available, or neither the Ollama box nor an OpenRouter key is reachable"
  else
    ( cd "$T/proj" && tlimit 420 env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL="$CCR_URL" ANTHROPIC_API_KEY="probe-dummy" \
        claude --bare -p "Reply with exactly: pong" --model "$m" --output-format json < /dev/null > "$T/p5.json" 2>&1 )
    r5="$(an result "$T/p5.json")"
    case "$r5" in
      ok\|*) say "PROBE 5: PASS — --bare works through ccr with a dummy API key (model $m → \"$(printf '%s' "${r5#*|}" | cut -c1-40)\")" ;;
      *)  ( cd "$T/proj" && tlimit 420 env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$CCR_URL" ANTHROPIC_AUTH_TOKEN="ccr" \
              claude -p "Reply with exactly: pong" --model "$m" --output-format json < /dev/null > "$T/p5b.json" 2>&1 )
          case "$(an result "$T/p5b.json")" in
            ok\|*) say "PROBE 5: FAIL — --bare rejected (${r5#*|}) while the normal ccr route works → keep non-bare for 3P engines" ;;
            *)     say "PROBE 5: INCONCLUSIVE — ccr route itself is failing for $m (${r5#*|}); fix the route, re-run" ;;
          esac ;;
    esac
  fi
fi

# ── PROBE 6: native Anthropic Messages endpoints (no ccr) — curl only, no login needed ──
body() { printf '{"model":"%s","max_tokens":512,"messages":[{"role":"user","content":"Reply with exactly: pong"}]}' "$1"; }
oll="FAIL"; orb="FAIL"; orx="FAIL"
detail "ollama version: $(curl -s --max-time 4 "http://$OLLAMA_HOST/api/version" 2>/dev/null | head -c 60 || true)"
code="$(curl -s --max-time 180 -o "$T/p6-oll.json" -w '%{http_code}' -X POST "http://$OLLAMA_HOST/v1/messages" \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -H 'x-api-key: ollama' -d "$(body "$LOCAL_MODEL")" 2>/dev/null)"
if [ "$code" = 200 ] && d="$(an msg "$T/p6-oll.json")"; then oll="OK"; fi
detail "ollama  POST /v1/messages → HTTP ${code:-000}  $( [ -s "$T/p6-oll.json" ] && an msg "$T/p6-oll.json" )"
if [ -s "$OR_KEY_FILE" ]; then
  for hdr in "Authorization: Bearer" "x-api-key:"; do
    code="$(printf 'header = "%s %s"\n' "$hdr" "$(tr -d '\n\r ' < "$OR_KEY_FILE")" | curl -s --max-time 90 -K - -o "$T/p6-or.json" -w '%{http_code}' \
      -X POST "https://openrouter.ai/api/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "$(body "$OR_MODEL")" 2>/dev/null)"
    ok=FAIL; [ "$code" = 200 ] && an msg "$T/p6-or.json" >/dev/null && ok=OK
    detail "openrouter POST /api/v1/messages [$hdr …] → HTTP ${code:-000}  $( [ -s "$T/p6-or.json" ] && an msg "$T/p6-or.json" )"
    case "$hdr" in Authorization*) orb="$ok" ;; *) orx="$ok" ;; esac
  done
else
  detail "openrouter: no key at $OR_KEY_FILE — skipped"
fi
if [ "$oll" = OK ] && [ "$orb" = OK ]; then
  say "PROBE 6: PASS — native Anthropic endpoints on BOTH ollama and openrouter (bearer=$orb x-api-key=$orx) → ccr removable"
elif [ "$oll" = OK ] || [ "$orb" = OK ] || [ "$orx" = OK ]; then
  say "PROBE 6: PARTIAL — ollama=$oll openrouter(bearer)=$orb openrouter(x-api-key)=$orx → ccr stays for the failing provider"
else
  say "PROBE 6: FAIL — no native Anthropic endpoint answered (ollama=$oll openrouter=$orb/$orx) → ccr retained"
fi
say "done — paste the PROBE lines (or $OUT) back."
