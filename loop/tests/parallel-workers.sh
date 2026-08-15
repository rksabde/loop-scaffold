#!/usr/bin/env bash
# loop/tests/parallel-workers.sh — does sharing ~/.claude across PARALLEL headless
# workers corrupt session state? (The open question behind MAX_PARALLEL.)
# RUN THIS FROM YOUR OWN TERMINAL — a nested/sandboxed context has no keychain access
# and every call fails with "Not logged in".
#
#   ./loop/tests/parallel-workers.sh [N-parallel] [rounds]     # default 3 x 2
#
# Verdict: prints CLEAN (parallel workers safe) or DIRTY (isolate before MAX_PARALLEL>1).
set -uo pipefail
N="${1:-3}"; ROUNDS="${2:-2}"
T="$(mktemp -d)"; trap 'rm -rf "$T" /tmp/iso-wt-$$' EXIT
cd "$T" && git init -q -b main . && git config user.email t@t.co && git config user.name t
echo hi > f.txt && git add -A && git commit -q --no-verify -m init
for i in $(seq 1 "$N"); do git worktree add -q -B "w$i" "/tmp/iso-wt-$$/w$i" main; done

overall=0
for round in $(seq 1 "$ROUNDS"); do
  for i in $(seq 1 "$N"); do
    ( cd "/tmp/iso-wt-$$/w$i" && \
      env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
        claude -p "Reply with exactly: pong" --model haiku --output-format json \
        < /dev/null > "$T/out-$round-$i.json" 2>&1
      echo $? > "$T/rc-$round-$i" ) &
  done
  wait
done

for f in "$T"/rc-*; do rc="$(cat "$f")"; [ "$rc" = 0 ] || { echo "nonzero exit: $f=$rc"; overall=1; }; done
for f in "$T"/out-*.json; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert not d.get('is_error') and 'pong' in d.get('result','').lower()" "$f" 2>/dev/null \
    || { echo "bad output: $f"; overall=1; }
done
python3 -c "import json; json.load(open('$HOME/.claude.json'))" 2>/dev/null || { echo "~/.claude.json CORRUPT"; overall=1; }

if [ "$overall" = 0 ]; then
  echo "VERDICT: CLEAN — $((N*ROUNDS)) parallel-session runs, all exit 0, outputs valid, ~/.claude.json intact"
else
  echo "VERDICT: DIRTY — do not raise MAX_PARALLEL above 1 without per-worker isolation"
fi
exit "$overall"
