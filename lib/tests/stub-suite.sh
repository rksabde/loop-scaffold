#!/usr/bin/env bash
# lib/tests/stub-suite.sh — end-to-end harness tests with a STUBBED LLM.
# Builds throwaway git repos under $(mktemp -d), points a fake adapter at them
# (LOOP_ADAPTER_FILE: sources the REAL lib/engine.sh, overrides adapter_invoke to write
# claude-format JSON results + create a file) and drives the REAL lib scripts through
# bin/loop. No network, no LLM spend. Foreground only: internal `& wait`, nothing outlives
# the script. Prints one PASS/FAIL line per check and a final count; exit 0 iff all pass.
#
#   bash lib/tests/stub-suite.sh            # KEEP=1 to keep the scratch dir for inspection
set -uo pipefail

LOOP_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOP="$LOOP_HOME/bin/loop"
T="$(cd -P "$(mktemp -d)" && pwd)"
[ "${KEEP:-0}" = "1" ] && echo "scratch: $T" || trap 'rm -rf "$T"' EXIT
# Hermetic: no inherited routing/flags from the caller's shell.
unset LOOP_TOOL LOOP_ENGINE_DEFAULT LOOP_ENGINE_ENGINEER LOOP_ENGINE_VERIFIER LOOP_ENGINE_PLANNER \
      LOOP_ENGINE_RESEARCHER LOOP_DRYRUN AUTO_INTEGRATE RETRY MAX_ATTEMPTS MAX_REPLANS LOOP_WORKER \
      LOOP_ADAPTER_FILE LOOP_PROJECT_ROOT WORKTREE_DIR ANTHROPIC_BASE_URL ANTHROPIC_API_KEY
export STUB_DIR="$T/stub"; mkdir -p "$STUB_DIR"

pass=0; fail=0
check() {   # check "<name>" <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "PASS  $name"
  else fail=$((fail+1)); echo "FAIL  $name"; fi
}

# ── fake adapter ─────────────────────────────────────────────────────────────
cat > "$STUB_DIR/adapter.sh" <<'STUB'
# Stub adapter: real engine.sh walk, fake tool. Knobs (env):
#   STUB_VERDICTS="FAIL PASS"  per-slug verifier verdict sequence (last word repeats)
#   STUB_SLEEP=N               engineer sleeps N s (kill -9 test)
#   provider 'limited'         always answers with a provider rate limit (failover test)
source "$LOOP_HOME/lib/engine.sh"
ADAPTER_TOOL="stub"
engine_available()   { case "$1" in frontier|limited) return 0 ;; *) return 1 ;; esac; }
adapter_describe()   { echo "stub --model $1-$2"; }
adapter_dryrun_tail(){ echo "model=$1-$2 transport=stub"; }
adapter_is_limit()   { grep -q 'rate_limit_error' "$1" 2>/dev/null; }
adapter_invoke() {   # prov tier prompt logfile
  local role="${ENGINE_ROLE:-?}" slug="${LOOP_PLAN_SLUG:--}" out="$4" n v
  echo "$role $slug $1" >> "$STUB_DIR/invocations"
  if [ "$1" = "limited" ]; then
    printf '{"type":"error","error":{"type":"rate_limit_error"},"retry_after": 120}\n' > "$out"; return 1
  fi
  case "$role" in
    engineer)
      [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
      n="$(grep -c "^engineer $slug " "$STUB_DIR/invocations")"
      echo "work $n" > "work-$slug-$n.txt"
      STUB_MODEL=stub-engineer-model STUB_COST=0.01 STUB_RESULT="done $n" python3 "$STUB_DIR/res.py" > "$out" ;;
    verifier)
      n="$(grep -c "^verifier $slug " "$STUB_DIR/invocations")"
      set -- ${STUB_VERDICTS:-PASS}; v="${!#}"; [ "$n" -le $# ] && v="${!n}"
      STUB_MODEL=stub-verifier-model STUB_COST=0.02 \
        STUB_RESULT="{\"plan\":\"$slug\",\"verdict\":\"$v\",\"scope_ok\":true,\"items\":[{\"check\":\"stub\",\"pass\":$( [ "$v" = PASS ] && echo true || echo false ),\"evidence\":\"stub check $v\"}]}" \
        python3 "$STUB_DIR/res.py" > "$out" ;;
    *)
      STUB_MODEL=stub-$role-model STUB_COST=0.03 STUB_RESULT="ok" python3 "$STUB_DIR/res.py" > "$out" ;;
  esac
  return 0
}
STUB
cat > "$STUB_DIR/res.py" <<'PY'
import json, os
e = os.environ
print(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                  "result": e["STUB_RESULT"], "modelUsage": {e["STUB_MODEL"]: {}},
                  "total_cost_usd": float(e["STUB_COST"]), "num_turns": 1, "duration_ms": 5}))
PY

# mkrepo <name> <plan-slug:status>... → echoes repo path. loop.conf honours env overrides.
mkrepo() {
  local r="$T/$1"; shift
  git -c init.templateDir= init -q -b main "$r"
  git -C "$r" config user.email t@t.co; git -C "$r" config user.name t; git -C "$r" config commit.gpgsign false
  cat > "$r/loop.conf" <<CONF
LINT_CMD=""
TEST_CMD=""
TYPECHECK_CMD=""
MAX_BUDGET_USD=""
MAX_PARALLEL="\${MAX_PARALLEL:-3}"
BASE_BRANCH="main"
WORKTREE_DIR="$T/wt"
AUTO_INTEGRATE="\${AUTO_INTEGRATE:-0}"
MAX_ATTEMPTS="\${MAX_ATTEMPTS:-2}"
MAX_REPLANS="\${MAX_REPLANS:-1}"
MERGE_LOCK_WAIT=60
CONF
  mkdir -p "$r/plans"; cp "$LOOP_HOME/templates/plans/PROGRESS.md" "$r/plans/PROGRESS.md"
  local spec
  for spec in "$@"; do
    printf '# %s\nstatus: %s\nworktree: %s\n\n## Acceptance\n- [ ] `true`\n' \
      "${spec%%:*}" "${spec#*:}" "${spec%%:*}" > "$r/plans/${spec%%:*}.md"
  done
  git -C "$r" add -A; git -C "$r" commit -q --no-verify -m init
  printf '%s' "$r"
}
status_of() { sed -n 's/^status: //p' "$1"; }
inv() { grep -c "^$1 $2 " "$STUB_DIR/invocations" 2>/dev/null || true; }   # role slug → count
clean_tracked() { [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ]; }

S="LOOP_ADAPTER_FILE=$STUB_DIR/adapter.sh"

# ═══ 1. CLI surface ══════════════════════════════════════════════════════════
check "cli: version prints a sha"           bash -c "'$LOOP' version | grep -qE '\\([0-9a-f]{7,}\\)'"
check "cli: unknown subcommand → exit 2"    bash -c "'$LOOP' bogus; [ \$? -eq 2 ]"
check "cli: init stub → exit 2"             bash -c "'$LOOP' init; [ \$? -eq 2 ]"
check "cli: outside a git repo → exit 1"    bash -c "cd '$T' && '$LOOP' fleet; [ \$? -eq 1 ]"

# ═══ 2. path model ═══════════════════════════════════════════════════════════
R="$(mkrepo paths)"
git -C "$R" worktree add -q "$T/paths-wt" -b side
check "path: LOOP_PROJECT_ROOT from a worktree = main checkout" \
  bash -c "cd '$T/paths-wt' && [ \"\$(bash -c 'source \"$LOOP_HOME/lib/lib.sh\"; echo \$LOOP_PROJECT_ROOT')\" = '$R' ]"
check "path: LOOP_HOME via symlinked bin/loop" \
  bash -c "ln -s '$LOOP' '$T/loop-link' && '$T/loop-link' version | grep -q '$LOOP_HOME'"
check "path: LOOP_TOOL=opencode → clear message, exit 2" \
  bash -c "cd '$R' && LOOP_TOOL=opencode '$LOOP' run plans/x.md 2>&1 | grep -q 'opencode is not supported'; cd '$R' && LOOP_TOOL=opencode '$LOOP' fleet; [ \$? -eq 2 ]"

# ═══ 3. gate guard ═══════════════════════════════════════════════════════════
printf 'TEST_CMD="false"\n' > "$R/loop.conf.fail"
cp "$R/loop.conf" "$R/loop.conf.orig"; cp "$R/loop.conf.fail" "$T/paths-wt/loop.conf"
check "gate: no-op without LOOP_WORKER (even with a failing TEST_CMD)" \
  bash -c "cd '$T/paths-wt' && bash '$LOOP_HOME/lib/gate.sh'"
check "gate: LOOP_WORKER=1 runs the WORKTREE's own loop.conf (TEST_CMD=false → non-zero)" \
  bash -c "cd '$T/paths-wt' && ! LOOP_WORKER=1 LOOP_PROJECT_ROOT='$R' bash '$LOOP_HOME/lib/gate.sh'"
check "gate: LOOP_WORKER=1 passes with main's empty commands + writes heartbeat" \
  bash -c "cd '$R' && mkdir -p .loop && LOOP_WORKER=1 LOOP_PROJECT_ROOT='$R' bash '$LOOP_HOME/lib/gate.sh' && test -s .loop/gate-fired"

# ═══ 4. dry-run routing (REAL claude adapter, no LLM) + call log ═════════════
R="$(mkrepo dry 001-d:ready)"
key="$T/orkey"; echo dummy-not-a-key > "$key"
dry() { (cd "$R" && env OPENROUTER_KEY_FILE="$key" LOOP_DRYRUN=1 "$@" 2>/dev/null | grep '^DRYRUN'); }
check "dry: default → frontier:high opus subscription" \
  bash -c "[ \"\$(cd '$R' && LOOP_DRYRUN=1 '$LOOP' fleet 2>/dev/null | grep ^DRYRUN)\" = 'DRYRUN role=engineer tool=claude engine=frontier:high model=opus transport=subscription' ]"
check "dry: calls.jsonl gained a dryrun line" \
  bash -c "python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert r[-1][\"kind\"]==\"dryrun\" and r[-1][\"engine\"]==\"frontier:high\" and r[-1][\"plan\"]==\"001-d\"' '$R/.loop/logs/calls.jsonl'"
check "dry: glm:low engineer → z-ai/glm-4.7 direct-openrouter" \
  bash -c "$(declare -f dry); R='$R' key='$key'; [ \"\$(dry env LOOP_ENGINE_ENGINEER=glm:low '$LOOP' run plans/001-d.md)\" = 'DRYRUN role=engineer tool=claude engine=glm:low model=z-ai/glm-4.7 transport=direct-openrouter' ]"
check "dry: chain skips unknown provider → frontier:mid sonnet" \
  bash -c "$(declare -f dry); R='$R' key='$key'; [ \"\$(dry env LOOP_ENGINE_ENGINEER='bogus:high|frontier:mid' '$LOOP' run plans/001-d.md)\" = 'DRYRUN role=engineer tool=claude engine=frontier:mid model=sonnet transport=subscription' ]"
check "dry: glm without key file → unavailable, falls to frontier" \
  bash -c "cd '$R' && [ \"\$(OPENROUTER_KEY_FILE='$T/nokey' LOOP_DRYRUN=1 LOOP_ENGINE_ENGINEER='glm:high|frontier:low' '$LOOP' run plans/001-d.md 2>/dev/null | grep ^DRYRUN)\" = 'DRYRUN role=engineer tool=claude engine=frontier:low model=haiku transport=subscription' ]"
check "dry: executor on glm is NOT --bare (gate needs hooks); exec logged" \
  bash -c "tail -1 '$R/.loop/logs/calls.jsonl' | grep -q '\"exec\": \"claude --model haiku \[subscription\]\"' && grep -q 'claude --model z-ai/glm-4.7 \[direct-openrouter\]' '$R/.loop/logs/calls.jsonl'"
check "dry: describe adds --bare for non-executor roles on glm/local" \
  bash -c "cd '$R' && source '$LOOP_HOME/adapters/claude.sh' && ENGINE_ROLE=verifier && adapter_describe glm high | grep -q -- '--bare' && ENGINE_ROLE=engineer && ! adapter_describe local high | grep -q -- '--bare' && [ \"\$(adapter_dryrun_tail local high)\" = 'model=gpt-oss:20b transport=direct-ollama' ]"
check "dry: verifier stays frontier under a cheap default (protected)" \
  bash -c "cd '$R' && source '$LOOP_HOME/lib/engine.sh' && LOOP_ENGINE_DEFAULT=glm:high && [ \"\$(engine_chain_for_role verifier)\" = frontier:high ] && [ \"\$(engine_chain_for_role engineer)\" = glm:high ]"
check "dry: codex adapter sources + dry-run tail (path fix)" \
  bash -c "cd '$R' && source '$LOOP_HOME/adapters/codex.sh' && [ \"\$(adapter_dryrun_tail frontier mid)\" = 'flags=[-c model_reasoning_effort=medium]' ]"
check "dry: claude adapter_is_limit: budget cap ≠ limit, 429 = limit" \
  bash -c "cd '$R' && source '$LOOP_HOME/adapters/claude.sh' && echo '{\"subtype\":\"error_max_budget_usd\",\"x\":\"rate limit\"}' > '$T/b.json' && echo '{\"type\":\"rate_limit\"}' > '$T/l.json' && ! adapter_is_limit '$T/b.json' && adapter_is_limit '$T/l.json'"
mkdir -p "$R/inbox/idea" && echo "an idea" > "$R/inbox/idea/note.md"
check "dry: intake → planner DRYRUN on frontier, marker NOT written" \
  bash -c "cd '$R' && LOOP_DRYRUN=1 '$LOOP' intake 2>/dev/null | grep -q '^DRYRUN role=planner tool=claude engine=frontier:high' && test ! -e inbox/idea/.intake.sha"

# ═══ 5. fleet skip / RETRY (manual mode) ═════════════════════════════════════
R="$(mkrepo fleet 010-f:ready)"
(cd "$R" && env "$S" "$LOOP" fleet) > "$T/fleet1.log" 2>&1
check "fleet: first run executes + commits branch loop/010-f" \
  bash -c "[ \"\$(grep -c '^engineer 010-f ' '$STUB_DIR/invocations')\" = 1 ] && git -C '$R' rev-parse -q --verify refs/heads/loop/010-f && git -C '$R' show loop/010-f:work-010-f-1.txt"
(cd "$R" && env "$S" "$LOOP" fleet) > "$T/fleet2.log" 2>&1
check "fleet: second run skips (branch exists), no duplicate spend" \
  bash -c "grep -q \"skip '010-f'\" '$T/fleet2.log' && [ \"\$(grep -c '^engineer 010-f ' '$STUB_DIR/invocations')\" = 1 ]"
(cd "$R" && env "$S" RETRY=1 "$LOOP" fleet) > "$T/fleet3.log" 2>&1
check "fleet: RETRY=1 re-dispatches" \
  bash -c "[ \"\$(grep -c '^engineer 010-f ' '$STUB_DIR/invocations')\" = 2 ]"
check "call-log: stub run recorded model_actual + cost (kind=run)" \
  bash -c "python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readlines()[-1]); assert r[\"kind\"]==\"run\" and r[\"model_actual\"]==\"stub-engineer-model\" and r[\"cost_usd\"]==0.01 and r[\"tool\"]==\"stub\" and r[\"role\"]==\"engineer\"' '$R/.loop/logs/calls.jsonl'"
check "progress: PROGRESS line carries engine/model/cost" \
  bash -c "grep -q 'engine=frontier:high model=stub-engineer-model cost=0.01' '$R/plans/PROGRESS.md'"
check "runtime: .loop/ self-ignored, no loop/ dir created in project" \
  bash -c "test -f '$R/.loop/.gitignore' && test ! -e '$R/loop' && [ -z \"\$(git -C '$R' status --porcelain .loop)\" ]"

# ═══ 6. failover cooldown ════════════════════════════════════════════════════
R="$(mkrepo failover 020-c:ready)"
(cd "$R" && env "$S" LOOP_ENGINE_ENGINEER='limited:high|frontier:high' "$LOOP" run plans/020-c.md) > "$T/fo.log" 2>&1
check "failover: rate-limited provider parked, next link ran" \
  bash -c "test -s '$R/.loop/state/limited.cooldown' && grep -q '^engineer 020-c frontier' '$STUB_DIR/invocations' && grep -q '\"kind\": \"limited\"' '$R/.loop/logs/calls.jsonl'"
check "failover: retry_after honoured (~120s cooldown)" \
  bash -c "d=\$(( \$(cat '$R/.loop/state/limited.cooldown') - \$(date +%s) )); [ \$d -gt 100 ] && [ \$d -le 120 ]"
(cd "$R" && env "$S" RETRY=1 LOOP_ENGINE_ENGINEER='limited:high|frontier:high' "$LOOP" run plans/020-c.md) > "$T/fo2.log" 2>&1
check "failover: cooling provider skipped on next call" \
  bash -c "grep -q \"'limited' cooling down\" '$T/fo2.log' && [ \"\$(grep -c '^engineer 020-c limited' '$STUB_DIR/invocations')\" = 1 ]"

# ═══ 7. transcripts cycle: FAIL → retry → PASS → merge ═══════════════════════
R="$(mkrepo tx 030-t:ready)"
(cd "$R" && env "$S" STUB_VERDICTS="FAIL PASS" MAX_ATTEMPTS=2 MAX_REPLANS=0 "$LOOP" integrate plans/030-t.md) > "$T/tx.log" 2>&1
echo "integrate exit=$?" >> "$T/tx.log"
check "transcripts: plan done, merged, worktree+branch cleaned" \
  bash -c "[ \"\$(sed -n 's/^status: //p' '$R/plans/030-t.md')\" = done ] && git -C '$R' log --oneline main | grep -q 'integrate 030-t' && ! git -C '$R' rev-parse -q --verify refs/heads/loop/030-t && test ! -d '$T/wt/tx-030-t'"
check "transcripts: retry prompt carried the verifier's FAIL verdict" \
  bash -c "grep -q 'PREVIOUS ATTEMPT WAS REJECTED' '$R/.loop/logs/030-t.prompt' && grep -q 'stub check FAIL' '$R/.loop/logs/030-t.prompt'"
check "transcripts: each work commit carries its own attempt-NN-engineer.md" \
  bash -c "git -C '$R' log --format=%H --diff-filter=A -- .transcripts/030-t/attempt-01-engineer.md | head -1 | xargs -I{} git -C '$R' show --stat {} | grep -q work-030-t-1.txt && git -C '$R' log --format=%H --diff-filter=A -- .transcripts/030-t/attempt-02-engineer.md | head -1 | xargs -I{} git -C '$R' show --stat {} | grep -q work-030-t-2.txt"
check "transcripts: bookkeeping commit carries verify-01/02 + meta-01/02" \
  bash -c "git -C '$R' show --stat --format= \$(git -C '$R' log --format=%H -1 --grep='bookkeep 030-t: done') > '$T/bk.txt' && for f in verify-01-verifier.md verify-02-verifier.md meta-01.json meta-02.json; do grep -q \$f '$T/bk.txt' || exit 1; done"
check "transcripts: meta parses with actual model + cost; no raw files by default" \
  bash -c "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"model_actual\"]==\"stub-verifier-model\" and d[\"cost_usd\"]==0.02' '$R/.transcripts/030-t/meta-02.json' && ! ls '$R'/.transcripts/030-t/*.raw.json"
check "transcripts: tracked tree clean, merge lock released" \
  bash -c "$(declare -f clean_tracked); clean_tracked '$R' && test ! -e '$R/.loop/state/merge.lock'"

# ═══ 8. blocked bookkeeping (bounded self-correction) ════════════════════════
R="$(mkrepo blk 040-b:ready)"
(cd "$R" && env "$S" STUB_VERDICTS="FAIL" MAX_ATTEMPTS=2 MAX_REPLANS=1 "$LOOP" integrate plans/040-b.md) > "$T/blk.log" 2>&1
check "blocked: status blocked + plans/040-b.blocked.md committed" \
  bash -c "[ \"\$(sed -n 's/^status: //p' '$R/plans/040-b.md')\" = blocked ] && git -C '$R' ls-files --error-unmatch plans/040-b.blocked.md && grep -q 'loop fleet' '$R/plans/040-b.blocked.md'"
check "blocked: executor runs bounded = (MAX_REPLANS+1)*MAX_ATTEMPTS = 4, planner 1" \
  bash -c "[ \"\$(grep -c '^engineer 040-b ' '$STUB_DIR/invocations')\" = 4 ] && [ \"\$(grep -c '^planner 040-b ' '$STUB_DIR/invocations')\" = 1 ]"
check "blocked: tracked tree clean (every outcome committed)" \
  bash -c "$(declare -f clean_tracked); clean_tracked '$R'"

# ═══ 9. parallel merge race (closed loop, 2 workers) ═════════════════════════
R="$(mkrepo race 050-a:ready 051-b:ready)"
(cd "$R" && env "$S" AUTO_INTEGRATE=1 MAX_PARALLEL=2 STUB_VERDICTS=PASS "$LOOP" fleet) > "$T/race.log" 2>&1
check "race: both plans done + merged serially" \
  bash -c "[ \"\$(sed -n 's/^status: //p' '$R/plans/050-a.md')\" = done ] && [ \"\$(sed -n 's/^status: //p' '$R/plans/051-b.md')\" = done ] && [ \"\$(git -C '$R' log --oneline main | grep -c 'integrate 05')\" = 2 ]"
check "race: both workers' files on main, fsck clean, lock released, tree clean" \
  bash -c "$(declare -f clean_tracked); test -f '$R/work-050-a-1.txt' && test -f '$R/work-051-b-1.txt' && git -C '$R' fsck --no-progress && test ! -e '$R/.loop/state/merge.lock' && clean_tracked '$R' && [ \"\$(git -C '$R' worktree list | wc -l | tr -d ' ')\" = 1 ]"

# ═══ 10. kill -9 → fleet sweep ═══════════════════════════════════════════════
R="$(mkrepo kill 060-k:ready)"
( cd "$R" && exec env "$S" STUB_SLEEP=20 "$LOOP" integrate plans/060-k.md ) > "$T/kill.log" 2>&1 &
kpid=$!
for _ in $(seq 1 50); do grep -q '^status: running' "$R/plans/060-k.md" && [ -s "$R/.loop/state/060-k.pid" ] && break; sleep 0.2; done
tree() { local p; for p in $(pgrep -P "$1"); do tree "$p"; done; echo "$1"; }
pids="$(tree "$kpid")"
kill -9 $pids 2>/dev/null; wait "$kpid" 2>/dev/null
check "kill: integrate SIGKILLed while running leaves plan stranded" \
  bash -c "grep -q '^status: running' '$R/plans/060-k.md' && test -s '$R/.loop/state/060-k.pid'"
(cd "$R" && env "$S" "$LOOP" fleet) > "$T/sweep.log" 2>&1
check "kill: fleet sweep resets the stranded plan to ready + removes pid file" \
  bash -c "grep -q \"'060-k' stranded in 'running'\" '$T/sweep.log' && grep -q '^status: ready' '$R/plans/060-k.md' && test ! -e '$R/.loop/state/060-k.pid'"

# ═══ 11. schedule (read-only) ════════════════════════════════════════════════
check "schedule: status runs from the tool (no install)" \
  bash -c "cd '$R' && '$LOOP' schedule status 2>&1 | grep -q '\[schedule\]'"

echo "----------------------------------------"
echo "stub-suite: $pass passed, $fail failed ($((pass+fail)) checks)"
[ "$fail" -eq 0 ]
