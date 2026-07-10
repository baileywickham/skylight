#!/usr/bin/env bash
# Install the packaged app to ~/Applications and register the LaunchAgent.
# The daemon must be launched by launchd (or `open -a`), NEVER as a terminal
# child, so TCC attributes grants to SkylightService itself.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/SkylightService.app"
LABEL="com.skylight.SkylightService"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -d "$APP" ] || { echo "error: $APP missing — run scripts/package-app.sh first" >&2; exit 1; }

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/skylight"
rm -rf "$HOME/Applications/SkylightService.app"
cp -R "$APP" "$HOME/Applications/SkylightService.app"

sed "s|__HOME__|$HOME|g" "packaging/$LABEL.plist" > "$AGENT"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl kickstart "gui/$(id -u)/$LABEL"
echo "Installed and started $LABEL"
