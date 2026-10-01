#!/usr/bin/env bash
# loop/schedule.sh — register an UNATTENDED scheduler for THIS repo's loop.
# Runs triage.sh (intake → draft plans; fleet → 'ready' plans only) on a schedule.
# Reusable across repos: the schedule is keyed to the repo path, so each repo gets
# its own job. macOS → launchd user agent; Linux → crontab line.
#
#   ./loop/schedule.sh install [HH:MM]   # register (default 09:00, daily)
#   ./loop/schedule.sh uninstall
#   ./loop/schedule.sh status
#   ./loop/schedule.sh run               # run triage once now (foreground)
#
# Safe by design: intake is content-hash idempotent (no-ops when nothing changed) and
# the fleet runs ONLY status: ready plans — so freshly-discovered drafts wait for a human.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

REPO="$SCAFFOLD_ROOT"
cmd="${1:-status}"
TIME="${2:-09:00}"; HH="$((10#${TIME%%:*}))"; MM="$((10#${TIME##*:}))"
ID="$(printf '%s' "$REPO" | shasum | cut -c1-8)"
LABEL="com.loopscaffold.$ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$REPO/loop/logs/cron.log"
RUN="cd $REPO && ./loop/triage.sh"

case "$(uname -s)" in
Darwin)
  case "$cmd" in
    install)
      mkdir -p "$HOME/Library/LaunchAgents" "$REPO/loop/logs"
      cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-lc</string><string>$RUN</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HH</integer><key>Minute</key><integer>$MM</integer></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST"
      log "[schedule] launchd job '$LABEL' installed — triage daily at $(printf '%02d:%02d' "$HH" "$MM")"
      log "[schedule]   plist: $PLIST"
      log "[schedule]   log:   $LOG   (uninstall: ./loop/schedule.sh uninstall)" ;;
    uninstall)
      launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"
      log "[schedule] removed launchd job '$LABEL'" ;;
    status)
      if [ -f "$PLIST" ]; then
        if launchctl list 2>/dev/null | grep -q "$LABEL"; then log "[schedule] ACTIVE (loaded) — $LABEL"
        else log "[schedule] installed but not loaded — $LABEL"; fi
      else log "[schedule] not installed for this repo"; fi ;;
    run) cd "$REPO" && exec ./loop/triage.sh ;;
    *) log "usage: schedule.sh install|uninstall|status|run [HH:MM]"; exit 2 ;;
  esac ;;
*)  # Linux / cron
  LINE="$MM $HH * * * $RUN >> $LOG 2>&1   # loop-scaffold:$ID"
  case "$cmd" in
    install)   mkdir -p "$REPO/loop/logs"; ( crontab -l 2>/dev/null | grep -v "loop-scaffold:$ID"; echo "$LINE" ) | crontab -
               log "[schedule] cron installed: $LINE" ;;
    uninstall) crontab -l 2>/dev/null | grep -v "loop-scaffold:$ID" | crontab -; log "[schedule] cron removed" ;;
    status)    crontab -l 2>/dev/null | grep -q "loop-scaffold:$ID" && log "[schedule] ACTIVE (cron)" || log "[schedule] not installed" ;;
    run)       cd "$REPO" && exec ./loop/triage.sh ;;
    *) log "usage: schedule.sh install|uninstall|status|run [HH:MM]"; exit 2 ;;
  esac ;;
esac
