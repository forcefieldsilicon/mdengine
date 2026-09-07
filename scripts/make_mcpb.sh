#!/bin/bash
# Package mdengine-mcp as an MCP Bundle: dist/mdengine-mcp-<version>-macos-<arch>.mcpb
# The manifest (mcpb/manifest.json) is generated from mcpb/manifest.template.json plus
# the live tools/list of the built server, so titles/descriptions never drift.
# With DEVELOPER_ID set, the binary is signed (hardened runtime, timestamped); with
# NOTARY_PROFILE, notarized as a zip (bare executables cannot be stapled).
# Requires: swift build -c release; npm i -g @anthropic-ai/mcpb
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' scripts/make_app.sh)
ARCH=$(uname -m)
BIN=.build/release/mdengine-mcp
[ -x "$BIN" ] || { echo "run: swift build -c release" >&2; exit 1; }
command -v mcpb >/dev/null || { echo "npm install -g @anthropic-ai/mcpb" >&2; exit 1; }

STAGE=$(mktemp -d)/mdengine-mcp
mkdir -p "$STAGE/server" dist
cp "$BIN" "$STAGE/server/mdengine-mcp"
cp LICENSE PRIVACY.md "$STAGE/"
sips -s format png -z 512 512 scripts/AppIcon.icns --out "$STAGE/icon.png" >/dev/null 2>&1 || true

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$STAGE/server/mdengine-mcp"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ZIP=$(mktemp -d)/mdengine-mcp.zip
    ditto -c -k "$STAGE/server" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
fi

# Generate manifest: template + version + tools from the server itself.
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make_mcpb","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$BIN" 2>/dev/null > "$STAGE/.tools.jsonl"
VERSION="$VERSION" STAGE="$STAGE" python3 - <<'PY'
import json, os
stage, version = os.environ["STAGE"], os.environ["VERSION"]
tools = []
for line in open(f"{stage}/.tools.jsonl"):
    line = line.strip()
    if not line: continue
    m = json.loads(line)
    if m.get("id") == 2:
        tools = [{"name": t["name"], "description": t["description"]} for t in m["result"]["tools"]]
assert tools, "tools/list returned nothing"
man = json.load(open("mcpb/manifest.template.json"))
man["version"] = version
man["tools"] = tools
if not os.path.exists(f"{stage}/icon.png"): man.pop("icon", None)
json.dump(man, open(f"{stage}/manifest.json", "w"), indent=2)
json.dump(man, open("mcpb/manifest.json", "w"), indent=2)  # committed copy, for review
PY
rm -f "$STAGE/.tools.jsonl"

mcpb validate "$STAGE/manifest.json"
OUT="dist/mdengine-mcp-$VERSION-macos-$ARCH.mcpb"
rm -f "$OUT"
mcpb pack "$STAGE" "$OUT"
echo "packaged: $OUT"
echo "sha256:   $(openssl dgst -sha256 "$OUT" | awk '{print $NF}')"
