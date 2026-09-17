# 016 — One provider-env implementation (`loop engine-exec`); retire ccr where possible; marketplace manifest

status: draft
worktree: engine-exec-and-ccr-exit

## Goal (verifiable)
1. **`loop engine-exec <provider:tier> -- <claude args…>`** is the ONLY place that maps an
   engine to env + `--model`. The claude adapter calls it; the `.zshrc` wrappers become
   one-liners over it (`claude-glm() { loop engine-exec glm:high -- "$@"; }` etc., written by
   `claude-framework/scripts/setup-claude-stack.sh`).
2. **Provider transport is per-provider config, not hardwired ccr**: `direct` (native
   Anthropic-compatible endpoint: base URL + token file) or `ccr` (shim). Defaults chosen
   from probes 009.5/.6 — any provider that answers `/v1/messages` natively goes `direct`;
   `ccr` stays available as a transport for OpenAI-only providers. `--bare` added for
   non-frontier engines if probe 009.5 passed.
3. **Marketplace manifest**: `.claude-plugin/marketplace.json` at repo root listing `plugin/`
   so `claude plugin marketplace add rksabde/loop-scaffold && claude plugin install loop`
   works (interactive sugar; hook stays guarded per 015).

## Constraints
- Token files are read at exec time and passed via env only — never logged, never written
  into another config file. `loop doctor` reports provider reachability without printing secrets.
- Engine chains / cooldown / call-log semantics unchanged. Frontier path unchanged
  (strip `ANTHROPIC_*` overrides; never `--bare`).
- If NO provider passes the native-endpoint probes, ship items 1 and 3 only and record
  "ccr retained" in the spec — do not force it.

## Acceptance
- [ ] `grep -rn "ANTHROPIC_BASE_URL" adapters/ lib/ bin/` → matches only inside the engine-exec implementation
- [ ] `LOOP_DRYRUN=1 loop engine-exec glm:high -- -p x` prints the resolved transport, base URL host, and model — and no token
- [ ] Dry-run routing matrix (frontier/glm/local × high/mid/low + a failover chain) identical to pre-change capture
- [ ] `zsh -n ~/.zshrc` clean; `type claude-glm` shows the one-liner
- [ ] `claude plugin validate .` (marketplace) exits 0
- [ ] Real cheap run on one non-frontier engine via its chosen transport returns a result; calls.jsonl `model_actual` non-empty

## Notes
Depends on 010 and probes 009.5/.6. Lowest priority (P6) — pure cleanup; skip if ccr is working fine and the duplication isn't hurting.
