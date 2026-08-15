# 008 — Committed transcripts: every effective commit carries its LLM chats

status: draft
worktree: transcripts

## Goal (verifiable)
For each effective work commit, the repo permanently records the LLM conversations that
produced it, under `.transcripts/<shortsha>-<slug>/`:
- `engineer.md` — rendered readable transcript of the executor run (prompt → responses)
- `verifier.md` — rendered verdict transcript (when a verify ran)
- `meta.json` — engine/call metadata (from plan 007's extractor: requested vs actual
  model, cost, turns, duration, attempt number)
- raw JSON logs included only when `TRANSCRIPT_RAW=1` (they run 100s of KB).

## Design (chicken–egg resolved)
A transcript named by a commit cannot live IN that commit (amend would change the sha).
So: work commit lands → harness resolves `shortsha=$(git rev-parse --short HEAD)` →
writes `.transcripts/<shortsha>-<slug>/…` → immediate FOLLOW-UP commit
`transcripts: <slug> @ <shortsha>` on the same branch. Merge carries both.
- Executor transcripts: run-plan.sh, after its harness-commit (skip if nothing committed).
- Verifier transcript: verify.sh writes it; integrate.sh commits it post-merge keyed to
  the MERGE commit sha (manual mode: left staged-ready with a log hint, or committed by
  the bookkeeping step from plan 003).
- Replan transcripts (planner rewrites): keyed to the replan bookkeeping commit.
- Renderer: `loop/transcript.py` (python3 stdlib only) — parses claude `--output-format
  json` result and codex JSONL into markdown; tolerant of unknown shapes (falls back to
  dumping text fields). Registered in install.sh copy list.
- `.transcripts/` is COMMITTED (that's the point) — do NOT gitignore. Add a one-line
  README.md inside explaining the naming scheme.

## Constraints
- Depends on 003 (bookkeeping commits) + 007 (meta extractor). Do after both.
- Never block the loop on transcript failure: renderer errors log a warning, loop goes on.
- Follow-up commits must be `--no-verify`-free (they contain no secrets; if the global
  secret hook false-positives on model output, document the bypass in the commit).

## Acceptance
- [ ] Stubbed run-plan cycle: after harness commit, `.transcripts/<sha>-<slug>/engineer.md`
      exists and a `transcripts:` commit follows the work commit (`git log --oneline -2`)
- [ ] Real cheap run end-to-end (integrate on a tiny plan): merge commit followed by a
      transcripts commit containing verifier.md + meta.json; `git status` clean after
- [ ] `python3 loop/transcript.py <a real claude json log>` produces markdown with the
      prompt and at least one assistant message
- [ ] meta.json parses (`python3 -c "import json;json.load(open(...))"`) and includes
      model_actual + cost_usd
- [ ] `grep -q "transcript.py" loop/install.sh` (shipped to targets)
- [ ] TRANSCRIPT_RAW unset → no *.json raw logs inside .transcripts/ for the test run
