#!/usr/bin/env bash
# Build SkylightService.app with a STABLE signing identity so TCC grants
# survive rebuilds. Ad-hoc signing would reduce the designated requirement
# to the cdhash and lose Accessibility/Screen Recording on every build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/SkylightService.app"

# Resolve the identity BEFORE building or touching build/: a failed lookup
# after the copy used to leave an unsigned bundle behind that a following
# install-launchagent.sh happily installed — ad-hoc signature, TCC grants
# gone. Same preference order as skylight-install so a checkout and a keg
# install sign identically (which is what keeps the grants across upgrades).
IDENTITY="${SKYLIGHT_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for name in "Skylight Dev" "Developer ID Application" "Apple Development"; do
        IDENTITY="$(printf '%s\n' "$identities" | sed -n "s/.*\"\($name[^\"]*\)\".*/\1/p" | head -1)"
        [ -n "$IDENTITY" ] && break
    done
fi
if [ -z "$IDENTITY" ] || ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "error: no codesigning identity found${IDENTITY:+ (wanted '$IDENTITY')}." >&2
    echo "Create one once in Keychain Access > Certificate Assistant > Create a Certificate" >&2
    echo "  (Name: Skylight Dev, Identity Type: Self-Signed Root, Certificate Type: Code Signing)," >&2
    echo "or set SKYLIGHT_SIGNING_IDENTITY to an Apple Development identity." >&2
    exit 1
fi

swift build -c release --product SkylightService

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp .build/release/SkylightService "$APP/Contents/MacOS/SkylightService"

codesign --force --sign "$IDENTITY" --identifier com.skylight.SkylightService "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP with identity '$IDENTITY'"
