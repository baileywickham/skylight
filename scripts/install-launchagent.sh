#!/usr/bin/env bash
# Install the packaged app to ~/Applications and register the LaunchAgent.
# The daemon must be launched by launchd (or `open -a`), NEVER as a terminal
# child, so TCC attributes grants to SkylightService itself.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/SkylightService.app"
LABEL="com.skylight.SkylightService"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Applications/SkylightService.app"

[ -d "$APP" ] || { echo "error: $APP missing — run scripts/package-app.sh first" >&2; exit 1; }

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/skylight"

# Stop the running daemon BEFORE touching its bundle: replacing the bundle out
# from under a live process leaves it executing a binary that no longer exists
# at that path.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Locate the skylight CLI, which performs the swap via FileManager.replaceItemAt.
# Keg layout puts it in bin/; a repo checkout has it under .build/.
SKYLIGHT_BIN=""
for candidate in "bin/skylight" ".build/release/skylight" ".build/debug/skylight" "$(command -v skylight || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { SKYLIGHT_BIN="$candidate"; break; }
done

# Stage the new bundle beside the destination (same volume, so the swap is a
# rename) under a dot-name so a half-copied bundle is never mistaken for the app.
STAGE="$HOME/Applications/.SkylightService.app.incoming.$$"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

if [ -n "$SKYLIGHT_BIN" ]; then
  # Atomic: the destination path always holds exactly one complete bundle.
  # This is what preserves Accessibility/Screen Recording across upgrades —
  # macOS keys TCC grants to signature + bundle id + path, and a bundle that
  # disappears (even briefly) reads as the app going away.
  "$SKYLIGHT_BIN" install-app "$STAGE" "$DEST"
else
  # Fallback for a checkout where the CLI has not been built yet: two renames
  # still beat rm -rf + cp -R, leaving the destination absent for microseconds
  # instead of the seconds a recursive copy takes.
  echo "warning: skylight CLI not found — using rename fallback (TCC grants may not survive)" >&2
  OLD="$HOME/Applications/.SkylightService.app.old.$$"
  [ -d "$DEST" ] && mv "$DEST" "$OLD"
  mv "$STAGE" "$DEST"
  rm -rf "$OLD"
fi
trap - EXIT

sed "s|__HOME__|$HOME|g" "packaging/$LABEL.plist" > "$AGENT"

launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl kickstart "gui/$(id -u)/$LABEL"
echo "Installed and started $LABEL"
