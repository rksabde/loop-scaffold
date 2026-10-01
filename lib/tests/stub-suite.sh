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
#   STUB_VERDICT_SHAPE=typed   (default) verifier result carries a schema-valid structured_output
#                     =prose   no structured_output; verdict JSON only inside .result (codex-like → grep)
#                     =malformed  structured_output unusable + .result prose with no verdict
#                     =contradict structured_output says PASS but an item failed
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
      local obj="{\"plan\":\"$slug\",\"verdict\":\"$v\",\"scope_ok\":true,\"items\":[{\"check\":\"stub\",\"pass\":$( [ "$v" = PASS ] && echo true || echo false ),\"evidence\":\"stub check $v\"}]}"
      local res="$obj" so="$obj"
      case "${STUB_VERDICT_SHAPE:-typed}" in
        prose)      so="" ;;
        malformed)  so='{"verdict":"MAYBE"}'; res="I ran out of turns; it would probably PASS if retried." ;;
        contradict) so="{\"plan\":\"$slug\",\"verdict\":\"PASS\",\"scope_ok\":true,\"items\":[{\"check\":\"stub-a\",\"pass\":true,\"evidence\":\"ok\"},{\"check\":\"stub-b\",\"pass\":false,\"evidence\":\"stub-b broke\"}]}" ;;
      esac
      STUB_MODEL=stub-verifier-model STUB_COST=0.02 STUB_RESULT="$res" STUB_SO="$so" \
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
d = {"type": "result", "subtype": "success", "is_error": False,
     "result": e["STUB_RESULT"], "modelUsage": {e["STUB_MODEL"]: {}},
     "total_cost_usd": float(e["STUB_COST"]), "num_turns": 1, "duration_ms": 5}
if e.get("STUB_SO"):
    d["structured_output"] = json.loads(e["STUB_SO"])
print(json.dumps(d))
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
check "cli: init outside a git repo → exit 1" bash -c "mkdir -p '$T/nogit' && cd '$T/nogit' && '$LOOP' init; [ \$? -eq 1 ]"
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
check "gate: LOOP_WORKER=1 runs the WORKTREE's own loop.conf (TEST_CMD=false → exit 2)" \
  bash -c "cd '$T/paths-wt' && LOOP_WORKER=1 LOOP_PROJECT_ROOT='$R' bash '$LOOP_HOME/lib/gate.sh'; [ \$? -eq 2 ]"
check "gate: failure output (the failing command) goes to STDERR, stdout empty" \
  bash -c "cd '$T/paths-wt' && LOOP_WORKER=1 LOOP_PROJECT_ROOT='$R' bash '$LOOP_HOME/lib/gate.sh' >'$T/g.out' 2>'$T/g.err'; [ ! -s '$T/g.out' ] && grep -q 'loop gate FAILED: .false.' '$T/g.err'"
check "gate: no-op is instant (<1s) and writes no heartbeat without LOOP_WORKER" \
  bash -c "cd '$T/paths-wt' && mkdir -p '$T/hb/.loop' && s=\$(date +%s) && LOOP_PROJECT_ROOT='$T/hb' bash '$LOOP_HOME/lib/gate.sh' && [ \$(( \$(date +%s) - s )) -le 1 ] && test ! -e '$T/hb/.loop/gate-fired'"
check "gate: LOOP_WORKER=1 passes (exit 0) with main's empty commands + writes heartbeat" \
  bash -c "cd '$R' && mkdir -p .loop && LOOP_WORKER=1 LOOP_PROJECT_ROOT='$R' bash '$LOOP_HOME/lib/gate.sh'; [ \$? -eq 0 ] && test -s .loop/gate-fired"

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

# ═══ 12. typed verdict (structured_output) + grep fallback ═══════════════════
R="$(mkrepo typed 070-p:ready 071-f:ready 072-m:ready 073-c:ready 074-g:ready)"
(cd "$R" && env "$S" STUB_VERDICTS=PASS MAX_ATTEMPTS=1 MAX_REPLANS=0 "$LOOP" integrate plans/070-p.md) > "$T/ty1.log" 2>&1
check "typed: integrate reaches done via structured_output (grep fallback NOT taken)" \
  bash -c "[ \"\$(sed -n 's/^status: //p' '$R/plans/070-p.md')\" = done ] && grep -q 'verdict via structured_output: PASS' '$R/.loop/logs/070-p.verify.log' && ! grep -q 'grep fallback' '$R/.loop/logs/070-p.verify.log'"
vrun() {   # slug [env...] → runs loop run + loop verify; echoes verify's exit code
  local slug="$1"; shift
  (cd "$R" && env "$S" "$LOOP" run "plans/$slug.md") >/dev/null 2>&1
  (cd "$R" && env "$S" "$@" "$LOOP" verify "plans/$slug.md") > "$T/$slug.verify.out" 2> "$T/$slug.verify.err"
  echo $?
}
rc="$(vrun 071-f STUB_VERDICTS=FAIL)"
check "typed: FAIL read via structured_output → verify exit 1" \
  bash -c "[ '$rc' = 1 ] && grep -q 'verdict via structured_output: FAIL' '$T/071-f.verify.err'"
check "typed: feedback file lists the failed items (check + evidence), not raw prose" \
  bash -c "f='$R/.loop/logs/071-f.feedback'; grep -q '^Verifier verdict: FAIL (scope_ok: true)' \$f && grep -q '^Failed checks:' \$f && grep -q '^- stub\$' \$f && grep -q '^  evidence: stub check FAIL' \$f && ! grep -q '\"items\"' \$f"
rc="$(vrun 072-m STUB_VERDICT_SHAPE=malformed)"
check "typed: malformed verdict → grep fallback → ERROR (never a false PASS)" \
  bash -c "[ '$rc' = 2 ] && grep -q 'verdict via grep fallback: ERROR' '$T/072-m.verify.err' && test ! -e '$R/.loop/logs/072-m.feedback'"
rc="$(vrun 073-c STUB_VERDICT_SHAPE=contradict)"
check "typed: PASS contradicted by a failed item → FAIL; feedback names that item" \
  bash -c "[ '$rc' = 1 ] && grep -q 'verdict via structured_output: FAIL' '$T/073-c.verify.err' && grep -q '^- stub-b\$' '$R/.loop/logs/073-c.feedback' && ! grep -q 'stub-a' '$R/.loop/logs/073-c.feedback'"
rc="$(vrun 074-g STUB_VERDICTS=FAIL STUB_VERDICT_SHAPE=prose)"
check "typed: no structured_output (codex-like) → grep fallback FAIL; feedback = raw result text" \
  bash -c "[ '$rc' = 1 ] && grep -q 'verdict via grep fallback: FAIL' '$T/074-g.verify.err' && grep -q '\"verdict\":\"FAIL\"' '$R/.loop/logs/074-g.feedback'"
check "typed: grep fallback prefers FAIL when a log mentions both" \
  bash -c "cd '$R' && source '$LOOP_HOME/lib/lib.sh' && printf '%s' '{\"result\":\"old verdict: PASS; new verdict: FAIL\"}' > '$T/both.json' && [ \"\$(plan_verdict '$T/both.json' 2>/dev/null)\" = FAIL ]"
check "typed: verifier.md JSON contract names exactly the schema's keys" \
  bash -c "python3 - '$LOOP_HOME' <<'PY'
import json, re, sys
h = sys.argv[1]
sch = json.load(open(h + '/templates/verdict.schema.json'))
md = open(h + '/plugin/agents/verifier.md').read()
blk = md[md.index('Return ONLY'):]
keys = set(re.findall(r'^  \"(\w+)\"', blk, re.M))
item = set(re.findall(r'\"(check|pass|evidence)\"', blk))
assert keys == set(sch['required']) == set(sch['properties']), keys
assert item == set(sch['properties']['items']['items']['required']), item
PY"

check "typed: schema is draft-07 (Claude Code's --json-schema rejects the 2020-12 \$schema URI)" \
  bash -c "grep -q '\"\\\$schema\": \"http://json-schema.org/draft-07/schema#\"' '$LOOP_HOME/templates/verdict.schema.json'"
check "typed: verifier role lists StructuredOutput (else --agent drops it → no structured_output)" \
  bash -c "grep -q '^tools:.*StructuredOutput' '$LOOP_HOME/plugin/agents/verifier.md'"

# ═══ 13. role = the session ══════════════════════════════════════════════════
U='Use the'   # split so this file never matches the pattern it checks for
check "role: no use-the-X-subagent prompt sentence left in lib/" \
  bash -c "! grep -rn '$U .* subagent' '$LOOP_HOME/lib/'"
check "role: engineer.md still delegates recon to the researcher subagent (+ may spawn it)" \
  bash -c "grep -q 'researcher. subagent' '$LOOP_HOME/plugin/agents/engineer.md' && grep -q '^tools:.*Agent(loop:researcher)' '$LOOP_HOME/plugin/agents/engineer.md'"
check "role: engine_role_prompt strips frontmatter; researcher is not a session role" \
  bash -c "cd '$R' && source '$LOOP_HOME/lib/engine.sh' && p=\"\$(engine_role_prompt engineer)\" && [ \"\$(printf '%s\n' \"\$p\" | head -1)\" = 'You are the engineer executing ONE plan to its verifiable goal. The plan is your contract.' ] && ! printf '%s' \"\$p\" | grep -q '^name:' && ! engine_role_prompt researcher"
check "role: codex prompt = role body + task (no --agent flag in codex)" \
  bash -c "cd '$R' && source '$LOOP_HOME/adapters/codex.sh' && ENGINE_ROLE=verifier _codex_prompt TASK | grep 'You are an independent verifier' >/dev/null && [ \"\$(ENGINE_ROLE=verifier _codex_prompt TASK | tail -1)\" = TASK ] && [ \"\$(ENGINE_ROLE=researcher _codex_prompt TASK)\" = TASK ]"

# ═══ 14. REAL claude adapter vs a fake `claude` binary (flags + stderr split) ═
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude: records argv per --agent role, prints a stderr line + a JSON result on stdout
role=none; prev=""
for a in "$@"; do [ "$prev" = "--agent" ] && role="$a"; prev="$a"; done
printf '%s\n' "$@" > "$FAKE_DIR/argv-$role"
echo "[claude-code:unrecognized_model] fake stderr line" >&2
so=null
[ "$role" = verifier ] && so='{"plan":"x","verdict":"PASS","scope_ok":true,"items":[{"check":"true","pass":true,"evidence":"ok"}]}'
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","structured_output":%s,"modelUsage":{"fake-claude-model":{}},"total_cost_usd":0.001,"num_turns":1,"duration_ms":3}\n' "$so"
FAKE
chmod +x "$FB/claude"
R="$(mkrepo fake 080-x:ready)"
FENV=("PATH=$FB:$PATH" "FAKE_DIR=$T" "CLAUDE_TOKEN_FILE=$T/no-token")
(cd "$R" && env -u CLAUDE_CODE_OAUTH_TOKEN "${FENV[@]}" "$LOOP" run plans/080-x.md) > "$T/fk1.log" 2>&1
(cd "$R" && env -u CLAUDE_CODE_OAUTH_TOKEN "${FENV[@]}" "$LOOP" verify plans/080-x.md) > "$T/fk2.log" 2>&1; fkrc=$?
check "claude: engineer runs --agent engineer, without --json-schema" \
  bash -c "grep -qx -- '--agent' '$T/argv-engineer' && ! grep -qx -- '--json-schema' '$T/argv-engineer' && grep -qx -- '--plugin-dir' '$T/argv-engineer'"
check "claude: verifier runs --agent verifier --json-schema <verdict.schema.json contents>" \
  bash -c "grep -qx -- '--json-schema' '$T/argv-verifier' && grep -q '\"title\": \"loop verifier verdict\"' '$T/argv-verifier'"
check "claude: stderr split → <log>.stderr; the .json log is pure JSON" \
  bash -c "grep -q 'unrecognized_model' '$R/.loop/logs/080-x.verdict.json.stderr' && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$R/.loop/logs/080-x.verdict.json' && ! grep -q unrecognized_model '$R/.loop/logs/080-x.json'"
check "claude: verdict via structured_output from the real adapter → PASS (exit 0)" \
  bash -c "[ '$fkrc' = 0 ] && grep -q 'verdict via structured_output: PASS' '$T/fk2.log'"
check "claude: call log model_actual populated despite the stderr line" \
  bash -c "python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==2 and all(x[\"model_actual\"]==\"fake-claude-model\" and x[\"cost_usd\"]==0.001 for x in r), r' '$R/.loop/logs/calls.jsonl'"
L="$T/legacy.json"
{ echo "[claude-code:unrecognized_model] legacy 2>&1 line"
  printf '%s\n' '{"type":"result","subtype":"success","result":"ok","modelUsage":{"legacy-model":{}},"total_cost_usd":0.5,"num_turns":2,"duration_ms":9}'; } > "$L"
check "claude: legacy combined log (stderr line + JSON) still parses: call log + transcript" \
  bash -c "cd '$R' && source '$LOOP_HOME/lib/engine.sh' && ADAPTER_TOOL=claude _engine_call_log engineer frontier high x '$L' 0 run && [ \"\$ENGINE_LAST_MODEL\" = legacy-model ] && python3 '$LOOP_HOME/lib/transcript.py' '$L' | grep -q 'models: legacy-model' && test ! -d '$LOOP_HOME/lib/__pycache__'"
echo '{"type":"result","subtype":"success","result":"ok"}' > "$T/lim.json"
echo 'API Error: 429 rate limit exceeded' > "$T/lim.json.stderr"
echo '{"type":"result","subtype":"error_max_budget_usd"}' > "$T/cap.json"
echo 'rate limit noise' > "$T/cap.json.stderr"
check "claude: adapter_is_limit sees a limit reported only on stderr; budget cap still excluded" \
  bash -c "cd '$R' && source '$LOOP_HOME/adapters/claude.sh' && adapter_is_limit '$T/lim.json' && ! adapter_is_limit '$T/cap.json' && ! adapter_is_limit '$R/.loop/logs/080-x.json'"

echo "----------------------------------------"
echo "stub-suite: $pass passed, $fail failed ($((pass+fail)) checks)"
[ "$fail" -eq 0 ]
