#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST="$ROOT/com.tim.orbstack-docker-watchdog.plist"
TARGET="$HOME/Library/LaunchAgents/com.tim.orbstack-docker-watchdog.plist"

chmod 755 "$ROOT/watchdog.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" \
  "$HOME/Library/Application Support/OrbStack Docker Watchdog"
sed \
  -e "s|__WATCHDOG_SCRIPT__|$ROOT/watchdog.sh|g" \
  -e "s|__WATCHDOG_STDOUT__|$HOME/Library/Logs/orbstack-docker-watchdog.launchd.log|g" \
  -e "s|__WATCHDOG_STDERR__|$HOME/Library/Logs/orbstack-docker-watchdog.launchd.err.log|g" \
  "$PLIST" > "$TARGET"

launchctl bootout "gui/$(id -u)/com.tim.orbstack-docker-watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"
launchctl kickstart -k "gui/$(id -u)/com.tim.orbstack-docker-watchdog"

echo "Installed and started com.tim.orbstack-docker-watchdog"
echo "Log: $HOME/Library/Logs/orbstack-docker-watchdog.log"
