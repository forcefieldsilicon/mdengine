---
name: tool-deformation
description: MDEngine analysis tool `deformation` — Deformation (Mechanics & deformation). Where did the material yield: per-atom shear and volumetric strain vs a reference frame, D²min (plastic rearrangement), displacement, MSD, von Mises stress when stress columns exist.
---

# Deformation (`deformation`)

**Category:** Mechanics & deformation · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** referenceFrame

## When to use
Where did the material yield: per-atom shear and volumetric strain vs a reference frame, D²min (plastic rearrangement), displacement, MSD, von Mises stress when stress columns exist.

## Decisions that matter
Needs a reference frame (frame 0 default; app picker / MCP reference_frame / CLI --reference). `cutoff` in the REFERENCE frame; `quantity`: shear | volumetric | d2min | displacement | rearranged | vonmises_stress; `d2minThreshold` for the rearranged map.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `24` | see Method in the manual section |
| `cutoff` | `3.5` | see Method in the manual section |
| `d2minThreshold` | `0.5` | see Method in the manual section |
| `profileAxis` | `z` | see Method in the manual section |
| `quantity` | `shear` | see Method in the manual section |
| `stressColumns` | `true` | see Method in the manual section |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Deformation; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze deformation <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "deformation", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "deformation"}` when the tool publishes a field.

## Reading the result
Mean/95th-percentile shear, volumetric strain, mean D²min, fraction rearranged, displacement/MSD, box strain, von Mises stress mean; field per `quantity`; scalar = mean of the chosen quantity.

## Caveats
Atoms with < 3 non-coplanar reference neighbours get no fit (counted). The fitted matrix is transposed to the true gradient so rotations are strain-free.

## Validation
Analytic uniform strain and simple shear; zero on rigid translation (through PBC) and rotation; single displaced atom lights only its neighbourhood.

## Pointers
- Manual: docs/manual/html/tools.html#deformation (section “deformation — Deformation”)
- Source & tests: Sources/LAMMPSCore/Analysis/DeformationTool.swift, Linalg3.swift; Tests/AppTests/DeformationToolTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
