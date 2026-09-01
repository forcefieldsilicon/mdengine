# MDEngine — development guide

macOS MD workbench: `MDEngine` (SwiftUI+Metal viewer), `mdengine-cli`,
`mdengine-mcp` (MCP stdio server, detached LAMMPS job runner). Shared core:
`Sources/LAMMPSCore` (parsers, writer, Arv). Brand: ForceField Silicon
(Gitinama Inc.).

## Commands
- Build: `swift build` · Tests: `swift test` (11 cases, keep green)
- Release: `swift build -c release` — **ALWAYS run after changes**:
  `/opt/homebrew/bin/mdengine` and `mdengine-mcp` are symlinks into
  `.build/release/`; a debug-only build leaves every other session running
  stale binaries (this caused a false bug report once).
- App: `./scripts/make_app.sh` → signed `/Applications/MDEngine.app`
  (ad-hoc unless `DEVELOPER_ID`/`NOTARY_PROFILE` set). DMG: `./scripts/make_dmg.sh`.
- MCP protocol smoke: pipe JSON-RPC lines into `.build/release/mdengine-mcp`
  (initialize → tools/list → tools/call).

## Gotchas that already bit
- SPM does NOT prune deleted resources from an existing
  `.build/*/MDEngine_MDEngine.bundle` — `rm -rf` the bundle dirs and rebuild.
- Product names `MDEngine` vs `mdengine` collide on case-insensitive APFS —
  hence `mdengine-cli`.
- LAMMPS OpenMP needs `-sf omp -pk omp N`; bare `OMP_NUM_THREADS` is a no-op.
- Apple's D-U-N-S/enrollment street field strips `#`.
- Trajectory parsers must stay safe on in-flight dumps (truncated tail =
  ignore) and drop non-finite rows — tests cover both; don't regress.

## Rules
- Sim decks are programs (LAMMPS `shell`): keep the README security note intact.
- Landauer/thermodynamic accounting stays out of this codebase (research-side
  layer separation).
- Bundled examples must be generic (LJ argon, Fe/O with LAMMPS-shipped
  force fields) — never research decks/data.
