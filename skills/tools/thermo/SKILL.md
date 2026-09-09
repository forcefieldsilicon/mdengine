---
name: tool-thermo
description: MDEngine analysis tool `thermo` — Thermo (log.lammps) (Mechanics & deformation). What did the LAMMPS run report: thermo columns aligned to frames; stress–strain and Young's modulus when stress and box columns exist.
---

# Thermo (log.lammps) (`thermo`)

**Category:** Mechanics & deformation · **Produces:** scalar, timeSeries · **Requires:** sideFile

## When to use
What did the LAMMPS run report: thermo columns aligned to frames; stress–strain and Young's modulus when stress and box columns exist.

## Decisions that matter
`alignBy: step` (frame timestep ↔ Step, default) or `index`. `yColumns` any thermo names; `stressStrain` needs Pxx/Pyy/Pzz (or c_/v_ named) + Lx/Ly/Lz; `elasticStrain` sets the modulus fit range.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `alignBy` | `step` | see Method in the manual section |
| `elasticStrain` | `0.02` | see Method in the manual section |
| `stressStrain` | `true` | see Method in the manual section |
| `xColumn` | `Step` | see Method in the manual section |
| `yColumns` | `["Temp", "PotEng", "Press"]` | see Method in the manual section |
| `logPath` | null | path; null = log.lammps / *.log next to the trajectory |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Thermo (log.lammps); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze thermo <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "thermo", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "thermo"}` when the tool publishes a field.

- The path may be the run directory or the side file itself (`.json`/`.csv`/`log.lammps`): no trajectory is needed. With a side file, `--frame N` / MCP `frame` means row or edge index N (use the trajectory for `--all`/`frames`).

## Reading the result
This frame's thermo values, strain/stress along the most-strained axis, E (GPa) and fit range, max stress, block info; scalar = first y column (or stress).

## Caveats
Multi-run logs are concatenated; WARNING lines are skipped; stress sign: σ = −P (bar → GPa × 1e-4).

## Validation
Synthetic log with two runs + CRLF; modulus 70.000 GPa recovered exactly.

## Pointers
- Manual: docs/manual/html/tools.html#thermo (section “thermo — Thermo (log.lammps)”)
- Source & tests: Sources/LAMMPSCore/Analysis/ThermoTool.swift, LammpsLog.swift; Tests/AppTests/MaterialsToolsTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
