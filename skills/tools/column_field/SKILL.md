---
name: tool-column_field
description: MDEngine analysis tool `column_field` — Colour by column (Rendering & export). Colour atoms by any per-atom quantity (x/y/z, charge, c_pe, vx …) and profile its mean along an axis. Also the smoke tool for the overlay path.
---

# Colour by column (`column_field`)

**Category:** Rendering & export · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** nothing

## When to use
Colour atoms by any per-atom quantity (x/y/z, charge, c_pe, vx …) and profile its mean along an axis. Also the smoke tool for the overlay path.

## Decisions that matter
Fix `rangeMin/rangeMax` when comparing frames or files, otherwise every frame rescales. Columns come from the dump/extended-XYZ header; `mdengine info <file>` lists them.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `24` | see Method in the manual section |
| `colormap` | `viridis` | see Method in the manual section |
| `column` | `z` | see Method in the manual section |
| `profileAxis` | `z` | see Method in the manual section |
| `rangeMax` | null | fixed colour range max; null = frame max |
| `rangeMin` | null | fixed colour range min; null = frame min |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Colour by column; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze column_field <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "column_field", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "column_field"}` when the tool publishes a field.

## Reading the result
Min/mean/max/std of the column, colour range used; field = the column; profile = mean per bin along `profileAxis`; scalar = mean.

## Caveats
Extended-XYZ `charge` lands in the column store, not on the atom record, so use column `charge` explicitly.

## Validation
Tests on synthetic frames (z default, data column, fixed range, registry JSON round trip).

## Pointers
- Manual: docs/manual/html/tools.html#column_field (section “column_field — Colour by column”)
- Source & tests: Sources/LAMMPSCore/Analysis/ColumnFieldTool.swift; Tests/AppTests/ColumnFieldToolTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
