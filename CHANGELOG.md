# Changelog

One entry per release, newest first. The **What's new** section on
[forcefieldsilicon.com/mdengine](https://forcefieldsilicon.com/mdengine/#whatsnew) is rendered
from this file (`~/LAMMPSApp/scripts/site_sections.py`), so a release note is written here once
and published, never typed into the page.

Format: `## <version> — <YYYY-MM-DD>` followed by one `- ` line per user-visible change. Keep
each line to one sentence a user can act on; internal refactors do not belong here.

## 0.7.0 — 2026-09-09

- Analysis tools in the inspector, the CLI and MCP: 13 tools that each answer one question — Adhesion (is the ligand still bound, and why), Pull-off energetics (what did the pull cost), Conformation (is the fold holding), Crystallinity, PTM (orientation and grains), Radial distribution, Diffusion, Deformation, Thermo (stress–strain from log.lammps), Z-profile, FEP results, Unbinding kinetics (τRAMD), Colour by column.
- Every tool result exports to CSV and Excel from its card; the Excel writer is pure Swift, so it works inside the macOS sandbox.
- `mdengine analyze <tool> <trajectory|run directory>` on the command line and an `analyze` verb over MCP, with one skill file per tool so an agent knows when to use which.
- Per-atom colour overlays with a baked legend in the viewer and in exported PNG, GIF and MP4; `render_image overlay:<tool>` over MCP.
- Covalent bonds and a backbone trace in the viewer and the renderer (`bonds:true`).
- Time-series charts follow playback: Pull-off energetics draws F(t) the moment it is added, with a cursor locked to the frame.
- A performance governor keeps the app at one draw per second when idle and schedules analysis under it; the Performance HUD shows what it is doing.
- Hosted GPU runs: submit and fetch pack and unpack tar.gz in-process, so the sandboxed app and iOS can use them; an Accelerated Runs toolbar button opens the hosted window.
- Hosted pricing groundwork: every finished job records its measured work (atom-steps) beside the metered charge; per-job prices come next and will never re-bill work already paid for.
- Hosted GPU runs refuse to bill when the pod has no working CUDA device, and relaunch once.
- Capability manifest and deck preflight before any spend: unsupported styles are routed to the full LAMMPS image or refused with the reason.
- OpenMM runner flavour for biomolecular protocols (steered pulls, AFM pull-off, τRAMD) on the same job contract as LAMMPS.
- Windows and Linux: the hosted tier works from any MCP client over HTTP with OAuth; Windows-made files (CRLF line endings) parse correctly in XYZ, dumps, decks and logs.
- MCP Registry listing carries the hosted remote; tool descriptions promise only what is offered.
- The hosted service's server code (endpoint, billing, GPU launcher) is no longer part of this repository; the client side of the hosted tier remains here under MIT.
- Fixes: a stale progress line during a long hosted fetch (stdout flush); chain-qualified residue keys in Adhesion so both chains can have a residue 1; CRLF files that parsed to zero frames.

## 0.6.3 — 2026-09-06

- MCP Registry listing (`com.forcefieldsilicon/mdengine`) gains the hosted remote at `POST /mcp` (Streamable HTTP, Bearer API key); notarized `.mcpb` bundle rebuilt.

## 0.6.2 — 2026-09-06

- MCP tool titles and annotations; signed MCP Bundle (`.mcpb`) for one-click install; first MCP Registry listing.

## 0.6.1 — 2026-09-05

- Hosted GPU tier from all three surfaces: `mdengine run --gpu`, MCP `host=cloud`, and Run Accelerated in the app, with an Accelerated Runs window and Settings tab; results open automatically.

## 0.6.0 — 2026-09-04

- Signed and notarized macOS app (DMG) and CLI + MCP tarball; detached job runner; remote transport over ssh.
