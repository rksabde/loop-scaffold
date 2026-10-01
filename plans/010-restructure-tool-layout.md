# 010 — Restructure into a machine-installed tool (`bin/ lib/ adapters/ plugin/ templates/`)

status: done
worktree: restructure-tool-layout

## Goal (verifiable)
The scaffold is a TOOL, not project content (spec §5.1–5.3):
- `bin/loop` single entrypoint dispatching `fleet|run|verify|integrate|intake|triage|schedule|doctor|self-update|version`.
- `lib/` holds today's `loop/*.sh` + `transcript.py` (logic unchanged); `adapters/` moves up one level.
- `plugin/` is a valid Claude Code plugin: `.claude-plugin/plugin.json`, `agents/{engineer,verifier,researcher,planner}.md`
  (moved from `.claude/agents/`), `hooks/hooks.json` (PostToolUse → `lib/gate.sh`).
- `templates/` holds what `loop init` will write: `loop.conf`, `.env.example`,
  `plans/{README,000-EXAMPLE,PROGRESS}.md`, `ci/loop.yml`, `verdict.schema.json`.
- `lib.sh` splits `SCAFFOLD_ROOT` into `LOOP_HOME` (realpath of `bin/loop`/..) and
  `LOOP_PROJECT_ROOT` (main checkout = first entry of `git worktree list --porcelain`);
  both exported to workers. Runtime dirs move to `$LOOP_PROJECT_ROOT/.loop/{logs,state}`.
- claude adapter attaches roles+gate per call: `--plugin-dir "$LOOP_HOME/plugin"` and sets
  `LOOP_WORKER=1`. Gate reads `loop.conf` from the worktree's own toplevel.
- `adapters/opencode.sh` deleted (spec §8.3); `LOOP_TOOL=opencode` fails with a clear message.

## Constraints
- Behavior-preserving refactor: no change to plan format, status lifecycle, merge lock,
  retry/replan caps, call-log schema, transcript naming.
- Prompts keep "Use the X subagent" wording here (role-as-session is plan 014) — agent
  names adjusted only if probe 009.1 shows plugin agents are namespaced.
- Do not touch other repos. Old vendored installs must keep working untouched.
- `install.sh` stays until 011 replaces it (may be broken by the move — then delete it here
  and note it; do not leave a half-working installer).

## Acceptance
- [x] `test -x bin/loop && bin/loop version` prints a version; `bin/loop bogus` exits 2 with usage
- [x] `claude plugin validate plugin/` exits 0
- [x] `test ! -e adapters/opencode.sh && test ! -d .claude/agents && test ! -d loop`
- [x] From a scratch repo containing ONLY `loop.conf` + `plans/001-x.md` (no machinery):
      `LOOP_DRYRUN=1 /abs/path/bin/loop fleet` resolves engines and logs a DRYRUN line; `.loop/logs/calls.jsonl` gains a line
- [x] Stub suites re-run green against the new layout (port to `lib/tests/`): parallel merge
      race, kill -9 → sweep, blocked bookkeeping, fleet skip/RETRY, DRY dry-run diff, call-log, transcripts cycle
- [x] Called from inside a worktree, `LOOP_PROJECT_ROOT` still resolves to the main checkout
- [x] `for f in bin/loop lib/*.sh adapters/*.sh; do bash -n "$f"; done` clean

## Notes
Depends on 009 (probes 1–3). Blocks 011–016.
Stub-suite pattern that works in the sandbox: one foreground script, internal `& wait`, no
disowned jobs, outputs to files (see the 003/004 debugging notes in git history).

## Progress
2026-10-01 — DONE. Commits: `e9473e2` (git mv), `382a015` (path model + bin/loop),
`6da7b0d` (plugin + claude adapter), `fb511cc` (templates + stub suite), then docs/probe.

### Acceptance outputs (run from the repo root)
```
$ test -x bin/loop && bin/loop version
loop untagged (fb511cc) /Users/rameshwarsabde/Claude/dev/loop-scaffold
rc=0
$ bin/loop bogus
loop: unknown command 'bogus'
usage: loop <command> [args]

rc=2
$ claude plugin validate plugin/
✔ Validation passed
rc=0
$ test ! -e adapters/opencode.sh && test ! -d .claude/agents && test ! -d loop && test ! -e .claude/settings.json
rc=1   (empty .claude/agents/ dir left by git mv — removed; re-run below)
$ (scratch repo: loop.conf + plans/001-x.md only) LOOP_DRYRUN=1 /abs/bin/loop fleet
.git loop.conf plans 
DRYRUN role=engineer tool=claude engine=frontier:high model=opus transport=subscription
calls.jsonl lines: 0 -> 1
$ (inside a worktree of the scratch repo) bash -c 'source $LOOP_HOME/lib/lib.sh; echo $LOOP_PROJECT_ROOT'
/private/var/folders/pt/3gn4sgg10xzc32jbh3pxbvth0000gn/T/tmp.7PrQD0qY14/r
main checkout: /private/var/folders/pt/3gn4sgg10xzc32jbh3pxbvth0000gn/T/tmp.7PrQD0qY14/r
$ bash lib/tests/stub-suite.sh | tail -1
rc=0
stub-suite: 44 passed, 0 failed (44 checks)
$ for f in bin/loop lib/*.sh adapters/*.sh lib/tests/*.sh; do bash -n "$f"; done; python3 -m py_compile lib/transcript.py
rc=0
$ test ! -e adapters/opencode.sh && test ! -d .claude/agents && test ! -d loop && test ! -e .claude/settings.json   # re-run
rc=0
```

### `--bare` + `--plugin-dir` hook probe (Claude Code 2.1.233)
Scratch git repo, `loop.conf` with empty LINT/TEST/TYPECHECK, env `LOOP_WORKER=1 LOOP_HOME
LOOP_PROJECT_ROOT`, `--plugin-dir $LOOP_HOME/plugin --permission-mode acceptEdits`, prompt
"Use the Write tool to create probe.txt containing hi, then reply done". `lib/gate.sh` writes
`$LOOP_PROJECT_ROOT/.loop/gate-fired` when it runs as a worker.

| run | auth / model | result | gate hook |
|---|---|---|---|
| without `--bare` | subscription token (`CLAUDE_CODE_OAUTH_TOKEN`), sonnet | `done`, probe.txt written | **FIRED** |
| `--bare` (as specified) | same OAuth token | `Failed to authenticate: OAuth session expired` — `--bare` never reads OAuth (`claude --help`) | n/a (no tool call) |
| `--bare` (production transport) | direct Ollama `localhost:11434`, `gpt-oss:20b` | 2 turns, probe.txt written | **NOT fired** |

Conclusion: `--bare` loads `--plugin-dir` but skips its hooks. So the claude adapter uses
`--bare` for glm/local **only for non-executor roles** (verifier/planner); the executor
(`engineer`) never runs `--bare`, so the gate always fires. Frontier is never `--bare`.
Recorded in the header comment of `adapters/claude.sh`.

### Decisions the plan did not specify
- `self-update` = `git -C $LOOP_HOME pull --ff-only` (in the plan Goal, not in the task list); `init|migrate` exit 2.
- `loop/install.sh` deleted (broken by the move; 011 replaces it), per the Constraints.
- `.loop/` gets its own `.gitignore` (`*`) on first use, so runtime state never gets committed,
  even before `loop init` updates the project `.gitignore`.
- `LOOP_ADAPTER_FILE` env = adapter override (the stub-suite seam); `load_adapter`/`adapter_path`
  in lib.sh centralise adapter choice; `fleet` fails fast (exit 2) on a bad `LOOP_TOOL`.
- `engine.sh` sets `ENGINE_ROLE` so an adapter can vary flags per role (used for the `--bare` policy).
- `gate.sh` writes a heartbeat `.loop/gate-fired` (used by the probe; cheap diagnostics).
- Old placeholder root `AGENTS.md` → `templates/AGENTS.md`; the root now has a real AGENTS.md for this repo.
- Prompts still say "Use the X subagent" (switching to role-as-session is plan 014); no `--agent`/`--json-schema` wiring yet.
