#!/usr/bin/env bash
# lib/init.sh — `loop init [dir] [--ci]` (spec §5.1, plan 011).
#
# Writes ONLY project-owned config + data from $LOOP_HOME/templates/, never clobbering:
#   loop.conf  .env.example  plans/{README,000-EXAMPLE,PROGRESS}.md
#   AGENTS.md (lean) + CLAUDE.md (@AGENTS.md)   — only if absent
#   .gitignore block (marker "# loop-scaffold"): .loop/ .env .intake.sha AGENTS.override.md wt/
#   --ci: .github/workflows/loop.yml (from templates/ci/loop.yml)
# Writes NO scripts, agents, hooks or LOOPS.md — those live in the tool and are attached
# per worker. Re-running is a no-op. One line per action: add / edit / skip.
#
# Also sourced by lib/migrate.sh, which reuses loop_init_project with LOOP_DRY=1 support.
set -uo pipefail

_INIT_LOOP_HOME="${LOOP_HOME:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOOP_GITIGNORE_MARKER="# loop-scaffold"
LOOP_GITIGNORE_ENTRIES=(.loop/ .env .intake.sha AGENTS.override.md wt/)
INIT_TOUCHED=()          # repo-relative paths init created/edited (migrate stages these)

# _say <verb> <what> — one line per action; under LOOP_DRY=1 actions print as "would: …".
_say() {
  if [ "${LOOP_DRY:-0}" = "1" ] && [ "$1" != "skip" ] && [ "$1" != "warn" ]; then
    printf 'would: %-6s %s\n' "$1" "$2"
  else
    printf '%-6s %s\n' "$1" "$2"
  fi
}
_dry() { [ "${LOOP_DRY:-0}" = "1" ]; }

# _init_file <root> <rel> <template-rel | "-" (stdin content)>
_init_file() {
  local root="$1" rel="$2" src="$3"
  if [ -e "$root/$rel" ]; then _say skip "$rel (exists)"; return 0; fi
  _say add "$rel"
  INIT_TOUCHED+=("$rel")
  _dry && return 0
  mkdir -p "$(dirname "$root/$rel")"
  if [ "$src" = "-" ]; then cat > "$root/$rel"; else cp "$_INIT_LOOP_HOME/templates/$src" "$root/$rel"; fi
}

# loop_gitignore_ensure <root> — append any missing loop entries under the marker.
loop_gitignore_ensure() {
  local root="$1" gi="$1/.gitignore" e missing=() verb=add
  for e in "${LOOP_GITIGNORE_ENTRIES[@]}"; do
    grep -qxF "$e" "$gi" 2>/dev/null || missing+=("$e")
  done
  if [ "${#missing[@]}" -eq 0 ]; then _say skip ".gitignore (loop entries present)"; return 0; fi
  [ -e "$gi" ] && verb=edit
  _say "$verb" ".gitignore (+ ${missing[*]})"
  INIT_TOUCHED+=(".gitignore")
  _dry && return 0
  {
    # keep the file newline-terminated before appending
    if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then printf '\n'; fi
    if ! grep -qxF "$LOOP_GITIGNORE_MARKER" "$gi" 2>/dev/null; then
      [ -s "$gi" ] && printf '\n'
      printf '%s\n' "$LOOP_GITIGNORE_MARKER"
    fi
    printf '%s\n' "${missing[@]}"
  } >> "$gi"
}

# loop_init_project <root> <ci:0|1>
loop_init_project() {
  local root="$1" ci="${2:-0}"
  _init_file "$root" loop.conf           loop.conf
  _init_file "$root" .env.example        .env.example
  _init_file "$root" plans/README.md     plans/README.md
  _init_file "$root" plans/000-EXAMPLE.md plans/000-EXAMPLE.md
  _init_file "$root" plans/PROGRESS.md   plans/PROGRESS.md
  _init_file "$root" AGENTS.md           AGENTS.md
  printf '@AGENTS.md\n' | _init_file "$root" CLAUDE.md -
  loop_gitignore_ensure "$root"
  if [ "$ci" = "1" ]; then
    _init_file "$root" .github/workflows/loop.yml ci/loop.yml
  fi
}

# loop_resolve_root <dir> <cmd> — echo the git toplevel containing <dir>, or exit 1.
loop_resolve_root() {
  local dir="$1" cmd="$2" r
  [ -d "$dir" ] || { echo "loop $cmd: no such directory: $dir" >&2; exit 1; }
  r="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$r" ] || {
    echo "loop $cmd: $dir is not inside a git repository (run 'git init' first)" >&2; exit 1; }
  (cd -P "$r" && pwd)
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dir="" ci=0
  for a in "$@"; do
    case "$a" in
      --ci) ci=1 ;;
      -h|--help) echo "usage: loop init [dir] [--ci]"; exit 0 ;;
      -*) echo "loop init: unknown option '$a'" >&2; echo "usage: loop init [dir] [--ci]" >&2; exit 2 ;;
      *) [ -z "$dir" ] || { echo "loop init: too many arguments" >&2; exit 2; }; dir="$a" ;;
    esac
  done
  root="$(loop_resolve_root "${dir:-.}" init)" || exit 1
  echo "loop init → $root"
  loop_init_project "$root" "$ci"
  if [ "${#INIT_TOUCHED[@]}" -eq 0 ]; then echo "nothing to do (already initialised)"
  else echo "next: edit loop.conf (LINT_CMD/TEST_CMD), write plans/NNN-*.md, then: loop fleet"; fi
fi
