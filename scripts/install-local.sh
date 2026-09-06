#!/bin/bash
# Dev install: build SkylightService.app from this checkout, put it in
# /Applications (where the cask installs it too), register the LaunchAgent, and
# start the daemon. Signs with the first Developer ID / Apple Development
# identity in the keychain unless CODESIGN_IDENTITY is set — a stable identity
# is what lets TCC grants survive rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for name in "Developer ID Application" "Apple Development"; do
        CODESIGN_IDENTITY="$(printf '%s\n' "$ids" | sed -n "s/.*\"\($name[^\"]*\)\".*/\1/p" | head -1)"
        [ -n "$CODESIGN_IDENTITY" ] && break
    done
    export CODESIGN_IDENTITY
fi
[ -n "${CODESIGN_IDENTITY:-}" ] && echo "==> signing with '$CODESIGN_IDENTITY'" \
    || echo "warning: no signing identity; ad-hoc signature (TCC grants will not persist across builds)" >&2

VERSION="${1:-0.0.0-dev}"
NOTARY_PASSWORD="" scripts/build.sh "$VERSION"

APP=/Applications/SkylightService.app
launchctl kickstart -k "gui/$(id -u)/com.skylight.SkylightService" >/dev/null 2>&1 || true
pkill -TERM -f SkylightService.app/Contents/MacOS/SkylightService 2>/dev/null || true
rm -rf "$APP"
cp -R .build-app/SkylightService.app "$APP"
"$APP/Contents/MacOS/skylight" register
