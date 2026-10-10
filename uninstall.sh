#!/bin/bash
set -euo pipefail

LABEL="com.tim.orbstack-docker-watchdog"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$TARGET"
echo "Uninstalled $LABEL"
