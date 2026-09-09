---
name: tool-ptm
description: MDEngine analysis tool `ptm` — PTM (orientation & grains) (Structure & order). Grains and orientation: template matching robust to thermal noise, per-atom lattice orientation (IPF hue), grain boundaries by disorientation, grain count — and structure type when a-CNA is too noisy.
---

# PTM (orientation & grains) (`ptm`)

**Category:** Structure & order · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** nothing

## When to use
Grains and orientation: template matching robust to thermal noise, per-atom lattice orientation (IPF hue), grain boundaries by disorientation, grain count — and structure type when a-CNA is too noisy.

## Decisions that matter
`quantity`: structure | orientation | rmsd | gb | shear. `rmsdThreshold` 0.1 (paper default); `gbAngle` 5° (low-angle boundaries need smaller). `templates` subset to speed up (each template costs ~55 µs/atom).

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `24` | see Method in the manual section |
| `gbAngle` | `5` | see Method in the manual section |
| `profileAxis` | `z` | see Method in the manual section |
| `quantity` | `structure` | see Method in the manual section |
| `rmsdThreshold` | `0.1` | see Method in the manual section |
| `templates` | `["fcc", "hcp", "bcc", "ico"]` | see Method in the manual section |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ PTM (orientation & grains); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze ptm <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "ptm", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "ptm"}` when the tool publishes a field.

## Reading the result
Type fractions, mean RMSD of matched atoms, GB fraction, grain count, mean disorientation at boundaries. Orientation hue is an inverse-pole-figure mapping of the crystal direction along lab z (cubic), c-axis tilt for hcp.

## Caveats
No Weinberg canonical forms: 25 µs/atom on perfect crystals, ~220 µs/atom worst case → deferred during playback at 100 k atoms. iid noise above ~0.2 Å favours a-CNA; real thermal motion is gentler.

## Validation
Perfect lattices 100 %/1 grain; 20° rotation recovered < 0.5°; bicrystal → 2 grains; hot frame 95.3 % vs a-CNA 90.6 %.

## Pointers
- Manual: docs/manual/html/tools.html#ptm (section “ptm — PTM (orientation & grains)”)
- Source & tests: Sources/LAMMPSCore/Analysis/PTMTool.swift, TemplateMatching.swift, Quaternion.swift; Tests/AppTests/PTMToolTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
