#!/bin/sh
# Removes the spike S6 LaunchAgent and its copy of PermissionProbe. Keeps the logs.
PLIST="$HOME/Library/LaunchAgents/app.farside.permprobe.check.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Library/Application Support/Farside/PermissionProbe.app"
echo "Removed. Logs stay in ~/Library/Logs/Farside/s6"
