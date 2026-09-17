# SPEC — How the loop machinery is distributed and how it drives Claude Code

status: draft (for review) · 2026-09-17 · scope: `loop-scaffold`, `agent-skeleton`, every repo that runs loops

## 1. Intent (restated)

Run self-correcting loops with **Claude Code as the harness**, where the LLM *behind* the
harness may be Anthropic (subscription), a third-party model (GLM via OpenRouter/Z.AI), or a
local model (Ollama). Do it without per-repo copies of the machinery and without `git subtree`.

Non-goals: replacing the plan format, the status lifecycle, worktree fan-out, the
execute → verify → integrate loop, engine chains/cooldown, the call log, or committed
transcripts. Those stay. This spec is about **where the machinery lives** and **how it
attaches to a Claude Code session**.

## 2. Current model and what is wrong with it

```
rksabde/loop-scaffold ──subtree──▶ agent-skeleton/.loop-scaffold/ ──template──▶ new repo/.loop-scaffold/
                                                                              └─ install.sh (copy, skip-if-exists) ─▶ repo/loop/, .claude/agents, .claude/settings.json, LOOPS.md …
updates: hand-run rsync/cp into every repo (active copy + dormant mirror)
```

Observed problems (all from this project's history, not hypotheticals):

| # | Problem | Evidence |
|---|---|---|
| 1 | Generic machinery is **vendored into every repo, often twice** (dormant `.loop-scaffold/` + active `loop/`) | Last wave: 35 files changed in `amboli-website-claude`, zero project-specific content |
| 2 | One scaffold change = **4 repos, 3 mechanisms** (subtree pull, rsync, cp), by hand | The sync script lived in `/tmp`; `install.sh` cannot update (skip-if-exists, open gap since L3) |
| 3 | **Drift is the default** — each repo freezes whatever it spawned with | The 001–008 wave was mostly repairing drift (stale docs, duplicated chain-walk) |
| 4 | Project history polluted by machinery commits; secret hook false-positives on vendored scripts → `--no-verify` habit | "Sync loop-scaffold maintenance wave" commits in product repos |
| 5 | Gate hook sits in project `.claude/settings.json` → fires on **every interactive edit**, not only loop workers | Not a choice today |
| 6 | Workers **inherit the human's whole interactive environment** (user plugins, skills, MCP servers) → token bloat, nondeterminism — worst for a local 27B model | Headless `claude -p` loads user scope by default |
| 7 | A role is reached via **subagent indirection** ("Use the verifier subagent") → extra hop, `model: inherit` subtlety, and it relies on the driving model being good at Task delegation — weakest exactly when a local LLM drives | `verify.sh`, `run-plan.sh` prompts |
| 8 | Verdict is **regex-parsed from prose** | `plan_verdict()` grep |
| 9 | Two implementations of "point Claude Code at provider X" | `.zshrc` wrappers (`ccr code`) vs `adapters/claude.sh::_claude_apply_env` |
| 10 | Subtree friction: squash merges, "working tree has modifications" failures, scaffold's own dev plans leak into `agent-skeleton/.loop-scaffold/plans/` | Hit during the 001–008 propagation |

What is actually project-specific: `loop.conf`, `.env`, `plans/`, `inbox/`, `.transcripts/`,
`AGENTS.md`. **Everything else is generic** and has no reason to be in the repo.

Root cause: the design treats the machinery as *project content* (so it must be copied) when
it is a *tool* (so it should be installed). Subtree is a symptom, not the disease.

## 3. Facts that change the design space (verified on this machine, Claude Code 2.1.233)

`claude --help` confirms per-invocation injection of everything we currently vendor:

| Flag | What it lets the harness do |
|---|---|
| `--plugin-dir <path>` | Load a plugin (agents, hooks, commands, skills) **for this session only** — no install, no repo files |
| `--agent <name>` / `--agents <json>` | Run the top-level session **as** a role / define roles inline — no "use the X subagent" hop |
| `--settings <file-or-json>` | Inject hooks/settings per call |
| `--append-system-prompt[-file]`, `--tools`, `--allowedTools`, `--disallowedTools` | Role prompt + tool restriction from the CLI |
| `--json-schema <schema>` | Schema-validated structured output → typed verdict, no regex |
| `--setting-sources user,project,local`, `--strict-mcp-config` | Stop workers inheriting the human's plugins/skills/MCP |
| `--bare` | Hermetic mode (no hooks, plugin sync, CLAUDE.md discovery, keychain). **Auth is API-key/apiKeyHelper only — OAuth/keychain never read** → usable for 3P/local providers, *not* for subscription `frontier` |
| `--output-format stream-json` | Full turn-by-turn stream → real transcripts (today's JSON has only the final message) |
| `--fallback-model a,b` | In-provider fallback on overload (complements, doesn't replace, engine chains) |
| `claude setup-token` | Long-lived subscription token → CI and sandboxed contexts without keychain (the 006 "Not logged in" failure mode) |
| `claude plugin install/update/marketplace/validate/tag` | First-class plugin distribution + versioning |

Probe results for the open points are in §7.

## 4. Alternatives

**A0 — Status quo.** Vendored copy + dormant mirror + subtree in the template + manual sync.

**A1 — Machine-installed CLI + per-session plugin injection.** *(recommended)*
One clone at `~/.loop-scaffold`, one `loop` executable on `PATH`. Repo holds config + data
only. Claude-specific bits (roles, gate hook) ship as a plugin directory inside the clone
and are attached to each worker with `--plugin-dir`. Nothing Claude-specific is committed
to the project.

**A2 — Installed marketplace plugin only.** Publish the scaffold as a Claude Code plugin;
`claude plugin install loop@rksabde`. Orchestration runs from slash commands or from
scripts under the plugin cache. Native versioning/updates. But: the cache path is versioned
and owned by Claude Code (bad target for launchd/cron/CI); an *installed* plugin's hooks
fire in **every** session on the machine; orchestrating from inside a session puts a model
in the control path; Claude-only.

**A3 — MCP server ("loop as tools").** Expose `next_plan`, `run_gate`, `submit_verdict`,
`record_progress` over MCP; any MCP-speaking harness can use them. MCP is the wrong layer
for *orchestration*: tools are called **by** a model **inside** a session, while the
orchestrator must sit outside and *launch* sessions deterministically ("a script can't
hallucinate dispatch"). As an inner gate it is *voluntary* (model must choose to call it)
where a hook is *mandatory* — and weak local models are the least reliable tool-callers.
Its one strong use — a typed verdict — is covered by `--json-schema` with no server.
Adds a runtime (Node/Python) and still needs its own distribution (npx/uvx).

**A4 — Shell aliases / functions, or user-scope `~/.claude` install.** Aliases and zsh
functions do not exist in non-interactive shells (launchd, cron, CI, bash scripts), so they
are interactive sugar, not a distribution mechanism; a `PATH` executable is the robust form
of the same idea (= A1). Installing roles into `~/.claude/agents` and the gate into
`~/.claude/settings.json` works without new flags but makes the hook global, pollutes the
agent namespace, and cannot be reproduced in CI.

**A5 — Wrapper pinning (gradlew pattern).** Repo commits a ~30-line `./loopw` + `loop.lock`;
the wrapper fetches the pinned version into `~/.cache/loop-scaffold/<ver>/` and execs it.
Per-project pinning and CI-friendly with near-zero vendoring. More moving parts than a solo
setup needs; a natural *add-on* to A1 if pinning ever matters.

**A6 — Git submodule.** Reference instead of copy, pinned per repo. Already rejected
(template/`degit` don't populate it); also every fresh worktree needs
`submodule update --init` or `loop/gate.sh` is missing. Still machinery-in-repo.

**A7 — Agent SDK rewrite.** Orchestrator as a TS/Python program: in-process hook callbacks,
typed outputs, streamed transcripts. Cleanest long-term shape, but a rewrite of ~1k lines
of tested bash, a new runtime, a separate path for Codex, and subscription-auth posture via
the SDK needs checking. Most of its benefits are reachable from bash via the §3 flags.

### Trade-off matrix

| | Update cost (N repos) | Repo footprint | Unattended / CI | 3P-LLM robustness | Worktree-safe | Version pinning | Cross-harness | Self-contained spawn | Migration cost |
|---|---|---|---|---|---|---|---|---|---|
| **A0** status quo | ❌ O(N×2), manual | ❌ ~35 files | ✅ in-repo | ◐ subagent hop | ✅ committed | ◐ implicit freeze | ✅ adapters | ✅ | — |
| **A1** CLI + `--plugin-dir` | ✅ `git pull` once | ✅ config+data | ✅ (CI: 1 clone step) | ✅ top-level role, slim ctx, mandatory hook | ✅ absolute paths | ◐ tags + min-version | ✅ adapters kept | ◐ needs tool on machine | ◐ medium |
| **A2** installed plugin | ✅ `plugin update` | ✅ | ❌ cache path, CI install | ◐ | ✅ | ✅ plugin versions | ❌ Claude-only | ◐ | ◐ |
| **A3** MCP server | ✅ | ✅ | ❌ not an orchestrator | ❌ voluntary tools | ✅ | ✅ | ✅ best | ◐ | ❌ high |
| **A4** aliases / `~/.claude` | ✅ | ✅ | ❌ no non-interactive | ◐ | ✅ | ❌ | ❌ | ◐ | ✅ low |
| **A5** wrapper pin | ✅ bump lock | ◐ wrapper+lock | ✅ self-fetch | (as A1) | ✅ | ✅ exact | ✅ | ✅ after 1st fetch | ◐ |
| **A6** submodule | ◐ per-repo bump | ◐ | ◐ init step | ◐ | ❌ per-worktree init | ✅ exact | ✅ | ❌ | ◐ |
| **A7** SDK rewrite | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ◐ | ❌ rewrite |

What A1 gives up vs A0: a repo is no longer runnable on a machine that lacks the tool, and
the implicit per-repo version freeze is gone (one scaffold bug reaches all projects at
once — the inverse of today's drift problem; mitigated by tags + `LOOP_MIN_VERSION`).

## 5. Recommended design (A1, with A2 as optional interactive sugar)

### 5.1 Layout

```
~/.loop-scaffold/                      # LOOP_HOME — the only copy on the machine
  bin/loop                             # fleet | run | verify | integrate | intake | triage | schedule | init | migrate | doctor | self-update
  lib/                                 # today's loop/*.sh + transcript.py (unchanged logic)
  adapters/                            # claude.sh codex.sh opencode.sh
  plugin/                              # a valid Claude Code plugin, attached per worker
    .claude-plugin/plugin.json
    agents/{engineer,verifier,researcher,planner}.md   # single source of role text
    hooks/hooks.json                   # PostToolUse → lib/gate.sh; no-op unless LOOP_WORKER=1 or loop.conf has GATE_INTERACTIVE=1 (§8.2)
    commands/{status,promote,fleet,blocked}.md         # thin wrappers over `loop …`
  templates/                           # loop.conf, .env.example, plans/{README,000-EXAMPLE}.md, ci/loop.yml, verdict.schema.json
  .claude-plugin/marketplace.json      # repo doubles as a marketplace (optional install)
~/.local/bin/loop → ~/.loop-scaffold/bin/loop
```

Project after `loop init` — **nothing generic, nothing Claude-specific**:

```
loop.conf   .env (gitignored)   plans/   inbox/   .transcripts/   .loop/ (gitignored: logs, state)   AGENTS.md   CLAUDE.md
```
Gone: `loop/`, `.loop-scaffold/`, `.claude/agents/*`, the hook in `.claude/settings.json`,
`LOOPS.md` + its `@import` and pointer block (the protocol is injected into workers only).

### 5.2 Path model

`lib.sh` splits today's `SCAFFOLD_ROOT` in two: `LOOP_HOME` (from the real path of
`bin/loop`) and `LOOP_PROJECT_ROOT` (main checkout = first entry of `git worktree list`,
not `--show-toplevel`, which returns the worktree when called from one). Both are exported
to workers; the gate reads `loop.conf` from the worktree's own toplevel so a branch that
changes `LINT_CMD` is judged by its own config.

### 5.3 Worker invocation (claude adapter)

```bash
LOOP_WORKER=1 LOOP_HOME=… LOOP_PROJECT_ROOT=… \
claude -p "$prompt" \
  --plugin-dir "$LOOP_HOME/plugin" \
  --agent engineer \                         # session IS the role; no "use the subagent" hop
  --model "$model" --permission-mode acceptEdits --max-budget-usd "$cap" \
  --setting-sources project --strict-mcp-config \   # don't inherit the human's plugins/skills/MCP
  --output-format stream-json --verbose             # full transcript for .transcripts/
# verifier adds:  --json-schema "$LOOP_HOME/templates/verdict.schema.json"
#                 --disallowedTools Edit Write NotebookEdit   (+ existing detached worktree)
```
- `researcher` stays a true subagent (the engineer fans out to it) — it ships in the same plugin.
- `plan_verdict()` becomes a JSON field read; the grep remains only as fallback for Codex.
- For `glm`/`local` engines add `--bare` (hermetic, smaller context) once verified with a
  dummy `ANTHROPIC_API_KEY`; never for `frontier` (bare mode cannot use subscription auth).

### 5.4 Third-party / local LLM driving the harness

Unchanged concept: role → engine chain (`provider:tier|…`), cooldown failover, call log.
Two cleanups:
1. **One implementation of provider env.** `loop engine-exec glm:high -- <claude args>`;
   the `.zshrc` wrappers become one-liners over it (`claude-glm() { loop engine-exec glm:high -- "$@"; }`).
2. **Try to delete ccr.** Z.AI already has a native Anthropic endpoint (primer "Approach B").
   If the Ollama box and OpenRouter expose Anthropic-compatible `/v1/messages` (§7), `glm`
   and `local` reduce to `ANTHROPIC_BASE_URL` + token: no daemon, no `_ccr_up`, no
   key-injected config file. Keep `ccr` as a provider *type* for anything OpenAI-only.

### 5.5 Unattended and CI

- launchd/cron: `schedule.sh` writes the **absolute** path to `loop` (no reliance on shell rc files).
- CI: one step — `git clone --depth 1 -b "$LOOP_REF" https://github.com/rksabde/loop-scaffold ~/.loop-scaffold`.
  Auth via `claude setup-token` → repo secret (subscription) or an API key.
- Versioning: git tags; `loop.conf: LOOP_MIN_VERSION=`; `loop doctor` checks tool version,
  auth, provider reachability, worktree dir. Exact pinning (A5 wrapper) deferred until needed.

### 5.6 `agent-skeleton`

Drop the subtree. Template = `AGENTS.md`, `CLAUDE.md`, `plans/{README,000-EXAMPLE,PROGRESS}.md`,
`loop.conf`, `.env.example`, `.gitignore`. The global `~/.claude/CLAUDE.md` note and
`/scaffold-agents` change from "run `.loop-scaffold/loop/install.sh .`" to "run `loop init`".

### 5.7 Interactive sugar (optional, A2-lite)

`claude plugin marketplace add rksabde/loop-scaffold && claude plugin install loop` gives
`/loop:status`, `/loop:promote`, `/loop:blocked` and the roles in interactive sessions. Safe
because the gate hook self-guards on `LOOP_WORKER=1`. Skip entirely if not wanted.

## 6. Migration plan

| Phase | Work | Done when |
|---|---|---|
| P0 | Resolve §7 unknowns with throwaway runs | Checklist answered; spec amended |
| P1 | Restructure scaffold repo (`bin/ lib/ adapters/ plugin/ templates/`); `LOOP_HOME`/`LOOP_PROJECT_ROOT` split; adapter uses `--plugin-dir` | Existing stub suites (merge-race, kill-9 sweep, DRY diff, call-log, transcripts) pass against new layout; `claude plugin validate plugin/` clean |
| P2 | `loop init` (writes config/data only) and `loop migrate` (deletes vendored files, moves `loop/logs,state` → `.loop/`, strips `LOOPS.md` import + pointer block + hook entry) | Idempotent on a scratch copy of `amboli-website-claude` |
| P3 | Migrate `claude-framework`, then `amboli-website-claude`; one real cheap plan end-to-end each | `git ls-files loop .loop-scaffold .claude/agents` empty; plan reaches `done` with transcript + call-log line |
| P4 | `agent-skeleton`: remove subtree; update global note + `/scaffold-agents`; `setup-claude-stack.sh` installs `loop` | Fresh template spawn + `loop init` + dry-run fleet works |
| P5 | Quality upgrades enabled by §3: `--json-schema` verdict, `--agent` roles, `stream-json` transcripts, `--setting-sources` slimming, `setup-token` in CI | Verifier verdict read as JSON; transcripts show every turn; worker context no longer lists user plugins |
| P6 | Optional: marketplace manifest; `engine-exec` unification; ccr removal | — |

Plans: P0 → `plans/009`, P1 → `010`, P2 → `011`, P3 → `012`, P4 → `013`, P5 → `014`,
§8.2 interactive gate → `015`, P6 → `016`. Order: 009 → 010 → 011 → 012 → 013, then 014/015
(independent), 016 last. 009/012/013 need a logged-in terminal (not fleet-runnable).

Old vendored repos keep working untouched until migrated (the one upside of vendoring), so
the cut-over can be one repo at a time.

## 7. Verified facts (probed 2026-09-17, Claude Code 2.1.233, `loop/tests/probe-cli.sh` + targeted re-runs)

| # | Question | Result |
|---|---|---|
| 1 | `--agent` + plugin-provided agent | **PASS** — resolves by bare name: `--plugin-dir P --agent engineer` (no `plugin:` prefix needed) |
| 2 | Plugin hooks under `-p` | **PASS** — `hooks/hooks.json` from a `--plugin-dir` plugin fires headless; `${CLAUDE_PLUGIN_ROOT}` expands in the command AND is set in the hook's env. (First run was inconclusive: haiku answered "Done." without calling Write; re-run on sonnet wrote the file and both markers fired.) |
| 3 | `--setting-sources project --strict-mcp-config` | **PASS** — subscription auth survives; user scope dropped: plugins 2→0, MCP servers 1→0, tools 39→31, skills 22→19, slash commands 56→51 |
| 4 | `--json-schema` + `stream-json` | **PASS** — validated object at `result_event.structured_output` (also mirrored as a JSON string in `.result`) |
| 5 | `--bare` for 3P engines | **PASS, and better than asked** — works **direct to OpenRouter, no ccr**: `ANTHROPIC_BASE_URL=https://openrouter.ai/api` + `ANTHROPIC_API_KEY=<openrouter key>` + `--bare --model z-ai/glm-4.7` → `pong`, `modelUsage` = `z-ai/glm-4.7`. Reported input tokens for a "pong" prompt: **6 with `--bare` vs 32,482 without** — the default harness context is ~32k tokens per worker call, which a 3P/local model pays for on every turn. (ccr path untested: the daemon was down.) |
| 6 | Native Anthropic endpoints | **PASS on both.** OpenRouter: `POST https://openrouter.ai/api/v1/messages` answers with `Authorization: Bearer` **and** `x-api-key`. Ollama (localhost, v0.32.5): `POST /v1/messages` → 200 `message` (thinking + text blocks); end-to-end `claude --bare` with `ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_API_KEY=ollama --model gpt-oss:20b` → `pong` in ~5s, no ccr. |

Consequences:
- 010 uses `--plugin-dir` + `--agent <role>` as designed; no fallbacks needed.
- 014: verdict = `structured_output`; slimming flags are safe on subscription runs.
- 016: **both `glm` and `local` go `direct` transport — ccr is removable entirely** (kept only
  as an optional transport for OpenAI-only providers). Local default is now Ollama on
  `localhost:11434` with `gpt-oss:20b` (the old GPU box `ollama-gpu.home.arpa` / `qwen3.6:27b`
  is reachable only from the 192.168.1.x LAN — set `OLLAMA_HOST`/`LOCAL_MODEL` in `.env` to use it). 3P engines run `--bare` — the 32k→~0 context cut is the
  single biggest cost/quality lever for cheap and local models. `--bare` skips CLAUDE.md
  discovery and plugins by default, so the adapter must pass context explicitly
  (`--plugin-dir`, `--add-dir`/`--append-system-prompt-file` for AGENTS.md) — verify hooks
  still fire under `--bare --plugin-dir` in 010.
- Headless auth: nested/launchd/CI contexts cannot rely on the keychain login (observed:
  "OAuth session expired and could not be refreshed"). Use `claude setup-token` → 0600 file
  `~/.config/claude/oauth-token` → exported as `CLAUDE_CODE_OAUTH_TOKEN` for frontier calls
  only (never forwarded to 3P routes). 010 moves this from the probe into `engine.sh`.

## 8. Decisions

1. **`rksabde/loop-scaffold` goes public** — DECIDED 2026-09-17. No secrets in it; removes the CI deploy-key/PAT step. (Audit history for keys before flipping visibility.)
2. **Gate on interactive sessions — opt-in per repo, default off.** One hook (in the plugin), guard:
   `LOOP_WORKER=1` **or** `GATE_INTERACTIVE=1` in the repo's `loop.conf`. Interactive mode runs
   `GATE_INTERACTIVE_CMD` (fast subset, e.g. lint + typecheck, no tests) and skips non-code paths
   (`*.md`, `plans/`, `inbox/`). Rationale — always-on for humans has real costs: mid-refactor red
   states make the model thrash on errors the next edit would fix; doc edits trigger the test suite;
   an installed plugin's hook is machine-wide so it needs the `loop.conf` guard anyway; and a second
   hook in project settings would double-fire inside workers.
3. **Keep `codex.sh`, delete the `opencode.sh` stub** — DECIDED 2026-09-17. Re-add when OpenCode is installed.
4. **MCP:** not adopted now. Revisit only if multi-harness becomes a real goal or loop state should be drivable from other apps (desktop/mobile) — then as a *thin state/verdict server*, never as the orchestrator.
