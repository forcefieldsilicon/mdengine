---
name: tool-diffusion
description: MDEngine analysis tool `diffusion` — Diffusion (MSD) (Mechanics & deformation). How mobile are the atoms: unwrapped MSD vs time, Einstein diffusion coefficient with standard error.
---

# Diffusion (MSD) (`diffusion`)

**Category:** Mechanics & deformation · **Produces:** perAtomField, scalar, timeSeries · **Requires:** referenceFrame

## When to use
How mobile are the atoms: unwrapped MSD vs time, Einstein diffusion coefficient with standard error.

## Decisions that matter
Needs a reference frame (frame 0 default). Time = dump timestep × `timestep_fs`, else frame index × `frameInterval_ps`. Keep `unwrap` on for periodic boxes. `fitStartFraction` 0.2 skips the ballistic/initial part.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `fitStartFraction` | `0.2` | see Method in the manual section |
| `frameInterval_ps` | `1` | see Method in the manual section |
| `timestep_fs` | `1` | see Method in the manual section |
| `unwrap` | `true` | see Method in the manual section |
| `species` | null | element; null = all |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Diffusion (MSD); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze diffusion <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "diffusion", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "diffusion"}` when the tool publishes a field.

## Reading the result
MSD now, D ± se in Å²/ps and cm²/s (MSD = 6Dt), fit range; scalar = MSD (chart over frames).

## Caveats
D from one trajectory is a single sample; report the fit se and compare seeds. 1 Å²/ps = 1e-4 cm²/s.

## Validation
Random walk D within 1 %; unwrapped MSD equals the never-wrapped truth.

## Pointers
- Manual: docs/manual/html/tools.html#diffusion (section “diffusion — Diffusion (MSD)”)
- Source & tests: Sources/LAMMPSCore/Analysis/DiffusionTool.swift; Tests/AppTests/MaterialsToolsTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
