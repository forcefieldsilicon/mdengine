---
name: tool-rdf
description: MDEngine analysis tool `rdf` — Radial distribution (Structure & order). How is the material packed: pair distribution g(r) for chosen species, first peak/minimum, per-atom coordination number.
---

# Radial distribution (`rdf`)

**Category:** Structure & order · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** nothing

## When to use
How is the material packed: pair distribution g(r) for chosen species, first peak/minimum, per-atom coordination number.

## Decisions that matter
Set `speciesA/speciesB` for partial RDFs (Fe–Fe, Al–O); `rMax` ≤ half the box; `bins` 200 default (0.05 Å) — noisy for small systems, lower it.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `200` | see Method in the manual section |
| `rMax` | `10` | see Method in the manual section |
| `coordinationCutoff` | null | Å; null = first minimum of g(r) |
| `speciesA` | null | element; null = all |
| `speciesB` | null | element; null = all |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Radial distribution; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze rdf <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "rdf", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "rdf"}` when the tool publishes a field.

## Reading the result
First peak position/height, first minimum, mean coordination at the cutoff, number density; field = coordination number; scalar = first-peak position.

## Caveats
Without a box the normalisation uses the bounding-box density (noted) — g(r) tails are wrong at large r for finite clusters.

## Validation
fcc first peak 2.875 Å vs a/√2 2.864 (+0.39 %), coordination exactly 12; ideal gas g ≈ 1.

## Pointers
- Manual: docs/manual/html/tools.html#rdf (section “rdf — Radial distribution”)
- Source & tests: Sources/LAMMPSCore/Analysis/RDFTool.swift; Tests/AppTests/MaterialsToolsTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
