#!/bin/bash
# Package the CLI + MCP server into dist/mdengine-tools-<version>-macos-<arch>.tar.gz.
# Run after scripts/make_app.sh (reads the version from the installed app). With
# DEVELOPER_ID set, the binaries are signed (hardened runtime, timestamped) and,
# with NOTARY_PROFILE, notarized as a zip (bare executables cannot be stapled;
# Gatekeeper checks the notarization record online).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/MDEngine.app
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
ARCH=$(uname -m)
BIN=.build/release
[ -x "$BIN/mdengine-cli" ] && [ -x "$BIN/mdengine-mcp" ] || { echo "run: swift build -c release" >&2; exit 1; }

STAGE=$(mktemp -d)/mdengine-tools-$VERSION
mkdir -p "$STAGE" dist
cp "$BIN/mdengine-cli" "$STAGE/mdengine"
cp "$BIN/mdengine-mcp" "$STAGE/mdengine-mcp"
cp README.md LICENSE "$STAGE/"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$STAGE/mdengine" "$STAGE/mdengine-mcp"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ZIP=$(mktemp -d)/mdengine-tools.zip
    ditto -c -k "$STAGE" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
fi

OUT="dist/mdengine-tools-$VERSION-macos-$ARCH.tar.gz"
rm -f "$OUT"
tar -C "$(dirname "$STAGE")" -czf "$OUT" "$(basename "$STAGE")"
echo "packaged: $OUT"
