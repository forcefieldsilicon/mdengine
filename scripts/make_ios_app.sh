#!/bin/bash
# Assemble MDEngineRuns.app for the iOS Simulator and (by default) install + launch it.
#
# Same idea as make_app.sh: no Xcode project, just a compiler invocation and a hand-written bundle. The app
# is a thin shell (ios/RunsApp.swift) over the MDEngineRunsUI library target, so everything of substance is
# already covered by `swift test` on macOS and by
#   xcodebuild -scheme MDEngineRunsUI -destination 'generic/platform=iOS Simulator' build
#
#   scripts/make_ios_app.sh                 # build, install to a booted simulator, launch
#   scripts/make_ios_app.sh --no-launch     # build the .app only
#   scripts/make_ios_app.sh --device "iPhone 15"    # pick the simulator by name
#   scripts/make_ios_app.sh --open-key mde_xxxx…    # after launching, open the deep link (GJOB-121 check)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=""
LAUNCH=1
OPEN_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    --device) DEVICE="${2:?--device needs a name}"; shift ;;
    --open-key) OPEN_KEY="${2:?--open-key needs mde_…}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)                       # arm64 on Apple silicon, x86_64 on Intel
TARGET="${ARCH}-apple-ios17.0-simulator"
BUILD=.build/ios-sim
APP="$BUILD/MDEngineRuns.app"

echo "== compiling for $TARGET"
rm -rf "$APP" "$BUILD/lib"
mkdir -p "$APP" "$BUILD/lib"
LIB="$BUILD/lib"
# Three passes, because the sources say `import LAMMPSCore` and so the module has to actually exist: two
# static libraries with their .swiftmodule, then the shell linked against them. LAMMPSCore has no
# dependencies and no resource bundle, and MDEngineRunsUI depends only on it -- if either ever gains a
# dependency, this script must become a real build instead of a compiler invocation.
common=(-sdk "$SDK" -target "$TARGET" -O -whole-module-optimization)

# shellcheck disable=SC2046
xcrun swiftc "${common[@]}" \
  -module-name LAMMPSCore -emit-module -emit-module-path "$LIB/LAMMPSCore.swiftmodule" \
  -emit-library -static -o "$LIB/libLAMMPSCore.a" \
  $(find Sources/LAMMPSCore -name '*.swift')

# shellcheck disable=SC2046
xcrun swiftc "${common[@]}" -I "$LIB" \
  -module-name MDEngineRunsUI -emit-module -emit-module-path "$LIB/MDEngineRunsUI.swiftmodule" \
  -emit-library -static -o "$LIB/libMDEngineRunsUI.a" \
  $(find Sources/MDEngineRunsUI -name '*.swift')

xcrun swiftc "${common[@]}" -I "$LIB" \
  -parse-as-library -module-name MDEngineRuns \
  -o "$APP/MDEngineRuns" \
  ios/RunsApp.swift "$LIB/libMDEngineRunsUI.a" "$LIB/libLAMMPSCore.a"

cp ios/Info.plist "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null

# NOT signed with ios/Entitlements.plist. Attaching entitlements to this hand-assembled bundle makes its
# identity Invalid (the install record says so) and SBMainWorkspace then refuses to launch it, because an
# ad-hoc signature cannot back an application-identifier. The consequence is that the Keychain is
# unavailable in this build, so the app falls back to a file store AND SAYS SO on screen
# (CredentialStoreFactory.best). A real signed project for TestFlight (GJOB-124) is where the entitlements
# file gets used and the Keychain becomes the real store.
echo "== built $APP"

[ "$LAUNCH" -eq 1 ] || exit 0

# Pick a simulator: the one already booted, else the named device, else any available iPhone.
UDID=$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for runtime, devs in d.items():
    for x in devs:
        if x.get("state")=="Booted" and "iPhone" in x.get("name",""): print(x["udid"]); raise SystemExit
' || true)
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,os
want=os.environ.get("DEVICE") or ""
d=json.load(sys.stdin)["devices"]
best=None
for runtime, devs in sorted(d.items()):
    for x in devs:
        if not x.get("isAvailable"): continue
        if want and x.get("name")!=want: continue
        if "iPhone" not in x.get("name",""): continue
        best=x["udid"]            # last match wins => newest runtime
print(best or "")
' )
  [ -n "$UDID" ] || { echo "no available iPhone simulator${DEVICE:+ named \"$DEVICE\"}" >&2; exit 1; }
  echo "== booting simulator $UDID"
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b || true
fi
export DEVICE

echo "== installing"
xcrun simctl install "$UDID" "$APP"
echo "== launching"
xcrun simctl launch "$UDID" com.forcefieldsilicon.mdengine.runs

if [ -n "$OPEN_KEY" ]; then
  echo "== opening deep link mdengine://key/<key>"
  xcrun simctl openurl "$UDID" "mdengine://key/$OPEN_KEY"
fi
echo "== done. open Simulator.app to see it."
