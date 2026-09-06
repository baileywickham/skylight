#!/bin/bash
# Build SkylightService.app (daemon + `skylight` CLI + `skylight-run` + the TS
# client source), sign it, and produce the DMG/ZIP a release ships. Mirrors
# ArtWall's scripts/build.sh; the cask in baileywickham/homebrew-tap installs
# the DMG's app to /Applications and symlinks the two CLIs into brew's bin.
#
#   scripts/build.sh <version>          # CODESIGN_IDENTITY, NOTARY_PASSWORD,
#                                       # APPLE_ID, APPLE_TEAM_ID from env
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
BUILD_DIR="$(pwd)/.build-app"
APP_NAME="SkylightService"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
BUNDLE_ID="com.skylight.SkylightService"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

# Releases must never ship ad-hoc signed; only allow the fallback locally.
if [ -z "${SIGN_IDENTITY}" ] && [ -n "${CI:-}" ]; then
    echo "ERROR: CODESIGN_IDENTITY must be set in CI builds" >&2
    exit 1
fi

echo "==> Building ${APP_NAME} v${VERSION}..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# The daemon reports SkylightVersion.current; make it match the tag for this
# build only (restored afterwards so a local build leaves the tree clean).
VERSION_FILE="Sources/SkylightCore/Version.swift"
cp "${VERSION_FILE}" "${BUILD_DIR}/Version.swift.orig"
trap 'cp "${BUILD_DIR}/Version.swift.orig" "${VERSION_FILE}"' EXIT
sed -i '' "s/public static let current = \".*\"/public static let current = \"${VERSION}\"/" "${VERSION_FILE}"

swift build -c release --product SkylightService
swift build -c release --product skylight

# Bundle layout:
#   Contents/MacOS/SkylightService        daemon (launchd runs this)
#   Contents/MacOS/skylight               CLI; Bundle.main == the .app, which is
#                                         what SMAppService needs for `register`
#   Contents/Resources/bin/skylight-run   driver/MCP wrapper (shell)
#   Contents/Resources/ts/                @skylight/sky client source (no
#                                         node_modules; installed on first run
#                                         under ~/Library/Application Support)
#   Contents/Library/LaunchAgents/…plist  bundled LaunchAgent
mkdir -p "${APP_BUNDLE}/Contents/MacOS" \
         "${APP_BUNDLE}/Contents/Resources/bin" \
         "${APP_BUNDLE}/Contents/Resources/ts" \
         "${APP_BUNDLE}/Contents/Library/LaunchAgents"
cp ".build/release/SkylightService" "${APP_BUNDLE}/Contents/MacOS/SkylightService"
cp ".build/release/skylight"        "${APP_BUNDLE}/Contents/MacOS/skylight"
cp scripts/skylight-run             "${APP_BUNDLE}/Contents/Resources/bin/skylight-run"
cp packaging/${BUNDLE_ID}.plist     "${APP_BUNDLE}/Contents/Library/LaunchAgents/"
cp packaging/Info.plist             "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff-index --quiet HEAD -- ":!${VERSION_FILE}" 2>/dev/null || GIT_COMMIT="${GIT_COMMIT}-dirty"
/usr/libexec/PlistBuddy -c "Add :SkylightGitCommit string ${GIT_COMMIT}" "${APP_BUNDLE}/Contents/Info.plist"

# TS client: source + lockfile only. node_modules is installed per-user on first
# run (scripts/skylight-run) so nothing is ever written inside the signed bundle.
cp -R ts/src ts/sky.d.ts ts/package.json ts/package-lock.json ts/tsconfig.json \
      "${APP_BUNDLE}/Contents/Resources/ts/"

# Sign inside-out: the CLI, then the bundle (which seals the daemon + resources).
if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Code signing with identity: ${SIGN_IDENTITY}"
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}/Contents/MacOS/skylight"
    codesign --force --options runtime --timestamp --identifier "${BUNDLE_ID}" --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> CODESIGN_IDENTITY not set; using ad-hoc signature for local testing"
    codesign --force --sign - "${APP_BUNDLE}/Contents/MacOS/skylight"
    codesign --force --identifier "${BUNDLE_ID}" --sign - "${APP_BUNDLE}"
fi
codesign --verify --strict --deep "${APP_BUNDLE}"
echo "==> App bundle created at ${APP_BUNDLE}"

# DMG with an Applications symlink for drag-to-install
DMG_NAME="${APP_NAME}-${VERSION}-macOS.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
DMG_TEMP="${BUILD_DIR}/${APP_NAME}-temp.dmg"
echo "==> Creating DMG..."
rm -f "${DMG_TEMP}" "${DMG_PATH}"
hdiutil detach "/Volumes/${APP_NAME}" 2>/dev/null || true
hdiutil create -size 50m -fs HFS+ -volname "${APP_NAME}" "${DMG_TEMP}"
hdiutil attach "${DMG_TEMP}" -nobrowse -mountpoint "/Volumes/${APP_NAME}"
cp -R "${APP_BUNDLE}" "/Volumes/${APP_NAME}/"
ln -s /Applications "/Volumes/${APP_NAME}/Applications"
hdiutil detach "/Volumes/${APP_NAME}"
hdiutil convert "${DMG_TEMP}" -format UDZO -o "${DMG_PATH}"
rm -f "${DMG_TEMP}"
echo "==> DMG created at ${DMG_PATH}"

ZIP_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
echo "==> Zip created at ${ZIP_PATH}"

if [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${SIGN_IDENTITY}" ]; then
    NOTARY_ARGS="--apple-id ${APPLE_ID} --team-id ${APPLE_TEAM_ID} --password ${NOTARY_PASSWORD}"
    echo "==> Notarizing DMG..."
    DMG_RESULT=$(xcrun notarytool submit "${DMG_PATH}" ${NOTARY_ARGS} --wait --timeout 30m 2>&1) || true
    echo "${DMG_RESULT}"
    DMG_ID=$(echo "${DMG_RESULT}" | grep "id:" | head -1 | awk '{print $2}')
    if ! echo "${DMG_RESULT}" | grep -q "status: Accepted"; then
        echo "==> Notarization failed, fetching log..."
        xcrun notarytool log "${DMG_ID}" ${NOTARY_ARGS} || true
        exit 1
    fi
    xcrun stapler staple "${DMG_PATH}"
    echo "==> DMG notarized and stapled"
elif [ -n "${NOTARY_PASSWORD:-}" ]; then
    echo "==> Ad-hoc signed build; skipping notarization"
else
    echo "==> NOTARY_PASSWORD not set, skipping notarization"
fi
echo "==> Done!"
