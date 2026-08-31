#!/bin/bash
# Assemble /Applications/MDEngine.app from a release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=/Applications/MDEngine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MDEngine" "$APP/Contents/MacOS/MDEngine"
cp -R "$BIN/MDEngine_MDEngine.bundle" "$APP/Contents/Resources/"

# Manual ships inside the bundle from the repo source.
mkdir -p "$APP/Contents/Resources/doc/manual/html"
cp docs/manual/html/index.html "$APP/Contents/Resources/doc/manual/html/index.html"

# Icon (regenerate only if missing)
if [ ! -f scripts/AppIcon.icns ]; then
  ICONDIR=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONDIR"
  swift scripts/make_icon.swift "$ICONDIR/icon_512x512@2x.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONDIR/icon_512x512@2x.png" --out "$ICONDIR/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICONDIR/icon_512x512@2x.png" --out "$ICONDIR/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONDIR" -o scripts/AppIcon.icns
fi
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MDEngine</string>
    <key>CFBundleIdentifier</key><string>com.gitinama.mdengine</string>
    <key>CFBundleName</key><string>MDEngine</string>
    <key>CFBundleDisplayName</key><string>MDEngine</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "installed: $APP"
