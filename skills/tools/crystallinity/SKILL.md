---
name: tool-crystallinity
description: MDEngine analysis tool `crystallinity` — Crystallinity (Structure & order). Is my oxide/metal amorphous or crystalline, and which phase: fcc/hcp/bcc/icosahedral/other per atom (adaptive CNA), crystalline fraction, q̄6 amorphicity, profile along z.
---

# Crystallinity (`crystallinity`)

**Category:** Structure & order · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** nothing

## When to use
Is my oxide/metal amorphous or crystalline, and which phase: fcc/hcp/bcc/icosahedral/other per atom (adaptive CNA), crystalline fraction, q̄6 amorphicity, profile along z.

## Decisions that matter
`method: acna` (default, cutoff-free) for structure types; `method: q6` for a continuous order parameter (q̄6 ≥ `q6Threshold` counts as ordered). Prefer `ptm` on hot frames (thermal noise): a-CNA degrades above ~0.15 Å iid displacement while PTM holds.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `24` | see Method in the manual section |
| `method` | `acna` | see Method in the manual section |
| `profileAxis` | `z` | see Method in the manual section |
| `q6Threshold` | `0.5` | see Method in the manual section |
| `cutoff` | null | fixed CNA cutoff Å; null = adaptive (a-CNA) |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Crystallinity; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze crystallinity <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "crystallinity", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "crystallinity"}` when the tool publishes a field.

## Reading the result
Fractions per type, crystalline fraction = 1 − other, mean q̄6/q̄4 (perfect fcc: q̄6 0.575, q̄4 0.191), profile of crystalline fraction along `profileAxis`. Overlay colours follow OVITO (fcc green, hcp red, bcc blue, ico yellow, other grey).

## Caveats
Surfaces and open boundaries classify as other (correct, not a bug); no box needed. a-CNA bcc cutoff uses the 8+6 neighbour combination (Stukowski 2012).

## Validation
Perfect fcc/bcc/hcp 100 %, liquid < 10 %; OVITO 3.16 cross-check: fcc 100 %/100 %, Fe/O frame 24.6 % vs 24.55 % bcc (design/perf-2026-09-08/ovito-*.txt).

## Pointers
- Manual: docs/manual/html/tools.html#crystallinity (section “crystallinity — Crystallinity”)
- Source & tests: Sources/LAMMPSCore/Analysis/CrystallinityTool.swift, BondOrder.swift; Tests/AppTests/CrystallinityToolTests.swift, Fixtures.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
