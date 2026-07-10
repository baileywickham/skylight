#!/usr/bin/env bash
# Build SkylightService.app with a STABLE signing identity so TCC grants
# survive rebuilds. Ad-hoc signing would reduce the designated requirement
# to the cdhash and lose Accessibility/Screen Recording on every build.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SKYLIGHT_SIGNING_IDENTITY:-Skylight Dev}"
APP="build/SkylightService.app"

swift build -c release --product SkylightService

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp .build/release/SkylightService "$APP/Contents/MacOS/SkylightService"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "error: no codesigning identity named '$IDENTITY'." >&2
    echo "Create one once in Keychain Access > Certificate Assistant > Create a Certificate" >&2
    echo "  (Name: Skylight Dev, Identity Type: Self-Signed Root, Certificate Type: Code Signing)," >&2
    echo "or set SKYLIGHT_SIGNING_IDENTITY to an Apple Development identity." >&2
    exit 1
fi

codesign --force --sign "$IDENTITY" --identifier com.skylight.SkylightService "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP with identity '$IDENTITY'"
