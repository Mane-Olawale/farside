#!/bin/sh
# Spike S6: installs an hourly LaunchAgent that runs `PermissionProbe --check`, which appends one
# status line to ~/Library/Logs/Farside/s6/events.jsonl. Remove with uninstall-check-agent.sh.
set -e
SRC="${1:-.build/DerivedData/Build/Products/Release/PermissionProbe.app}"
DEST="$HOME/Library/Application Support/Farside/PermissionProbe.app"
PLIST="$HOME/Library/LaunchAgents/app.farside.permprobe.check.plist"
LOGS="$HOME/Library/Logs/Farside/s6"

mkdir -p "$(dirname "$DEST")" "$LOGS" "$(dirname "$PLIST")"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.farside.permprobe.check</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/PermissionProbe</string>
        <string>--check</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$LOGS/agent-stderr.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. App: $DEST"
