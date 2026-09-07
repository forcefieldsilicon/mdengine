# MDEngine — development guide

macOS MD workbench: `MDEngine` (SwiftUI+Metal viewer), `mdengine-cli`,
`mdengine-mcp` (MCP stdio server, detached LAMMPS job runner). Shared core:
`Sources/LAMMPSCore` (parsers, writer, Arv). Brand: ForceField Silicon
(Gitinama Inc.).

## Commands
- Build: `swift build` · Tests: `swift test` (20 cases, keep green)
- Release: `swift build -c release` — **ALWAYS run after changes**:
  `/opt/homebrew/bin/mdengine` and `mdengine-mcp` are symlinks into
  `.build/release/`; a debug-only build leaves every other session running
  stale binaries (this caused a false bug report once).
- App: `./scripts/make_app.sh` → signed `/Applications/MDEngine.app`
  (ad-hoc unless `DEVELOPER_ID`/`NOTARY_PROFILE` set). DMG: `./scripts/make_dmg.sh`.
- MCP protocol smoke: pipe JSON-RPC lines into `.build/release/mdengine-mcp`
  (initialize → tools/list → tools/call).
- Remote execution (`Sources/MDEngineMCP/RemoteJobs.swift`): hosts in
  `~/.mdengine/hosts.json`; test bed = `localhost-test` host over ssh to this Mac
  (own key in ~/.ssh/authorized_keys). `lmp` must be an absolute path — no login
  PATH over ssh. Release packaging: `make_tools.sh` (CLI+MCP tarball). `make_mcpb.sh` = signed MCP Bundle (manifest generated from live tools/list; needs `npm i -g @anthropic-ai/mcpb`).
- MCP Registry (registry.modelcontextprotocol.io): listed as `com.forcefieldsilicon/mdengine`
  via `server.json`. Per release: bump `version` + package `identifier` URL + `fileSha256`
  (from make_mcpb output), attach the .mcpb to the GitHub release FIRST, then
  `mcp-publisher publish`. `description` ≤ 100 chars (422 otherwise). Auth = DNS TXT on
  forcefieldsilicon.com; `mcp-publisher login dns --domain forcefieldsilicon.com --private-key ...`
  with the key kept outside git (~/mdengine-hosted/mcp-registry/).
- Tool `title` + annotations live in `toolMeta` (main.swift) — add an entry for every new tool.
- Hosted MCP remote = `hosted/endpoint/mde_mcp.py` (tools) + `mde_oauth.py` (OAuth 2.1: DCR + CIMD,
  PKCE S256, consent page takes the API key once, mat_/mrt_ tokens hashed in sqlite). Unknown
  `/.well-known/*` MUST 404 (a 401 there makes Claude.ai demand OAuth it can't find); tools/call
  without a credential = 401 + WWW-Authenticate resource_metadata. Directory portal reads the
  tool title from `annotations.title` and the icon from `/favicon.ico`. Deploy to prod
  (`deploy/deploy.sh root@mde-api`) is arvand-only (classifier); 57 tests in test_endpoint.py.
- Notarize bare binaries as a zip (`NOTARY_PROFILE=mdengine-notary`); tickets are online-only.
- Hosted GPU tier (`Sources/LAMMPSCore/HostedClient.swift`, `hosted/CONTRACT.md`): dev
  loop = `python3 hosted/mock/mock_endpoint.py --port 8788 --data <dir>` +
  `MDENGINE_HOSTED_URL=http://127.0.0.1:8788/v1 MDENGINE_HOSTED_LAUNCH="{lmp} -in {input} -log log.lammps"`,
  pod stand-in = `docker/runner-gpu/runner.sh` with `MDE_WORK`/`LMP` (see hosted/README.md).

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
