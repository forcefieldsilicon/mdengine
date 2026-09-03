#!/bin/bash
# Package /Applications/MDEngine.app into dist/MDEngine-<version>.dmg.
# Run scripts/make_app.sh first (with DEVELOPER_ID/NOTARY_PROFILE for release).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/MDEngine.app
[ -d "$APP" ] || { echo "build the app first: scripts/make_app.sh" >&2; exit 1; }
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)

STAGE=$(mktemp -d)/MDEngine
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="dist/MDEngine-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MDEngine $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Release: sign the disk image too, and notarize + staple it so Gatekeeper is
# satisfied at the DMG level, not only for the stapled app inside.
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --timestamp -s "$DEVELOPER_ID" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
echo "packaged: $DMG"
