#!/bin/bash
# Smoke test for the agent-facing analysis surface (GJOB-135): the MCP `analyze`
# tool and the `mdengine analyze` CLI verb, both over the LAMMPSCore tool
# registry. Run from anywhere; it works in the repo root and needs no network.
set -euo pipefail
cd "$(dirname "$0")/.."

TRAJ="Sources/MDEngine/Resources/lj_melt.xyz"
MCP=".build/release/mdengine-mcp"
CLI=".build/release/mdengine-cli"
CSV="${TMPDIR:-/tmp}/mdengine_smoke_analyze.csv"

echo "== build (release) =="
swift build -c release

fail() { echo "FAIL: $1"; exit 1; }
# expect <label> <needle> <file>
expect() { grep -qF -- "$2" "$3" || fail "$1: missing '$2'"; }

echo "== MCP: initialize / tools/list / analyze =="
MCPOUT="$(mktemp)"
trap 'rm -f "$MCPOUT"' EXIT
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"analyze\",\"arguments\":{\"path\":\"$TRAJ\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"analyze\",\"arguments\":{\"path\":\"$TRAJ\",\"tool\":\"column_field\",\"params\":{\"column\":\"z\"}}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"analyze\",\"arguments\":{\"path\":\"$TRAJ\",\"tool\":\"column_field\",\"frames\":\"all\"}}}" \
  | "$MCP" > "$MCPOUT"

[ "$(wc -l < "$MCPOUT")" -eq 5 ] || fail "expected 5 JSON-RPC responses, got $(wc -l < "$MCPOUT")"
expect "tools/list" '"name":"analyze"' "$MCPOUT"
expect "tools/list" 'Analyze (registry tool)' "$MCPOUT"
expect "tools/list" '"name":"z_profile"' "$MCPOUT"            # existing tools intact
expect "catalogue" 'supports_strided_preview' "$MCPOUT"
expect "catalogue" 'default_parameters' "$MCPOUT"
expect "catalogue" 'column_field' "$MCPOUT"
expect "catalogue" 'Surfaces & deposition' "$MCPOUT"
expect "single frame" 'Std. dev.' "$MCPOUT"
expect "single frame" 'legendTitle' "$MCPOUT"
expect "single frame" 'colormapName' "$MCPOUT"
# the tool payload is a JSON string inside the JSON-RPC frame, hence \" here
expect "time series" '\"frames\" :' "$MCPOUT"
expect "time series" '\"scalar\" :' "$MCPOUT"
if grep -qF '"isError":true' "$MCPOUT"; then fail "an analyze call returned isError"; fi
echo "   MCP ok ($(wc -c < "$MCPOUT" | tr -d ' ') bytes over 5 responses)"

echo "== CLI: catalogue =="
CLIOUT="$("$CLI" analyze)"
echo "$CLIOUT" | grep -qF 'column_field' || fail "catalogue: no column_field"
echo "$CLIOUT" | grep -qF 'z_profile' || fail "catalogue: no z_profile"
echo "$CLIOUT" | grep -qF 'colormap=viridis' || fail "catalogue: no default parameters"

echo "== CLI: single frame, --param + --json =="
JSONOUT="$("$CLI" analyze column_field "$TRAJ" --param column=x --json)"
echo "$JSONOUT" | grep -qF '"legendTitle" : "x"' || fail "--param column=x did not reach the tool"
echo "$JSONOUT" | grep -qF '"count" : 4000' || fail "field values were not summarised to a count"

echo "== CLI: --all --csv =="
"$CLI" analyze column_field "$TRAJ" --all --csv "$CSV" > /dev/null
LINES="$(wc -l < "$CSV" | tr -d ' ')"
[ "$LINES" -gt 3 ] || fail "CSV has $LINES lines (expected > 3)"
grep -qF '# frames' "$CSV" || fail "CSV has no per-frame section"
echo "   CSV ok ($LINES lines → $CSV)"

echo "PASS: analyze smoke (MCP + CLI)"
