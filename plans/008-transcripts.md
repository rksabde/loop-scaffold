# 008 — Committed transcripts: every effective commit carries its own LLM chats

status: done
worktree: transcripts

## Goal (verifiable)
Every effective commit CONTAINS the transcript of the LLM run that produced it — no
follow-up "transcripts:" commits, no sha-named files. Under `.transcripts/<slug>/`:
- `attempt-NN-engineer.md` — rendered executor transcript, rides in that attempt's WORK commit
- `verify-NN-verifier.md` + `meta-NN.json` — verdict transcript + call metadata, ride in
  the bookkeeping commit (plan 003's status-flip commit) after verification
- `replan-NN-planner.md` — planner rewrite transcript, rides in the replan bookkeeping commit
- raw JSON logs only when `TRANSCRIPT_RAW=1` (they run 100s of KB).

## Design (no chicken–egg)
The executor's chat log is COMPLETE before the harness commits — so the transcript is
rendered FIRST and the work commit includes it. Filenames use slug + attempt number
(known before commit); the commit sha is never needed in a name because git itself is
the mapping:
- which transcript came with commit X → `git show X --stat`
- which commit added transcript Y → `git log --diff-filter=A -- .transcripts/<slug>/Y`

Flow per attempt (run-plan.sh): `adapter_run` → render `attempt-NN-engineer.md` from the
JSON log → existing `git add -A && git commit` picks it up. NN = next free number in the
dir (works for manual runs and integrate retries alike).
Verifier (verify.sh renders; integrate.sh's bookkeeping commit from plan 003 carries it):
`verify-NN-verifier.md` + `meta-NN.json` (engine/cost/actual-model from plan 007).
Manual mode (no integrate): verify.sh leaves the rendered files in place and logs a hint;
they ride in whatever commit the human makes at merge time.

- Renderer: `loop/transcript.py` (python3 stdlib only) — parses claude `--output-format
  json` and codex JSONL into markdown (prompt, assistant turns, tool summary); tolerant
  of unknown shapes (falls back to dumping text fields). Added to install.sh copy list.
- `.transcripts/` is COMMITTED (that's the point) — never gitignore it. Ship a one-line
  `.transcripts/README.md` explaining the scheme (created lazily on first transcript).
- Never block the loop on transcript failure: renderer errors log a warning, run goes on.

## Constraints
- Depends on 003 (bookkeeping commits) + 007 (meta extractor). Do after both.
- run-plan.sh/verify.sh/integrate.sh call-site contracts unchanged otherwise.

## Acceptance
- [ ] Stubbed run-plan cycle: work commit contains BOTH the code change and
      `.transcripts/<slug>/attempt-01-engineer.md` (`git show --stat HEAD` proves it)
- [ ] Second stubbed attempt on same slug → `attempt-02-engineer.md` in the retry's commit
- [ ] Real cheap integrate run (tiny plan): bookkeeping commit contains
      `verify-01-verifier.md` + `meta-01.json`; `git status` clean after
- [ ] `python3 loop/transcript.py <real claude json log>` emits markdown containing the
      prompt and at least one assistant message
- [ ] `meta-01.json` parses and includes model_actual + cost_usd
- [ ] `grep -q "transcript.py" loop/install.sh` (shipped to targets)
- [ ] TRANSCRIPT_RAW unset → no raw *.json inside .transcripts/ for the test run
