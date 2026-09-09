---
name: tool-z_profile
description: MDEngine analysis tool `z_profile` — Z-profile (Surfaces & deposition). Deposition/oxidation: where did the deposited species end up — penetrated, at the surface, in flight; depth histogram relative to the substrate's top plane.
---

# Z-profile (`z_profile`)

**Category:** Surfaces & deposition · **Produces:** profile, scalar, timeSeries · **Requires:** nothing

## When to use
Deposition/oxidation: where did the deposited species end up — penetrated, at the surface, in flight; depth histogram relative to the substrate's top plane.

## Decisions that matter
Pick substrate and probe explicitly when the two most abundant elements are not the slab and the deposit. `profileOf` = composition (counts) | charge | {kind: field, name: <column>} to bin any per-atom column (e.g. c_pe, crystallinity field) by depth.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `12` | see Method in the manual section |
| `profileOf` | `{"kind": "composition"}` | see Method in the manual section |
| `probe` | null | element token; null = second most abundant |
| `substrate` | null | element token; null = most abundant |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Z-profile; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze z_profile <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "z_profile", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "z_profile"}` when the tool publishes a field.

## Reading the result
Surface plane z (top 5 % of substrate atoms), penetrated/at-surface/above counts, min/mean/max depth, bound-probe mean charge (when q exists); profile bins are `z − surface`. Scalar (chart over frames) = max penetration.

## Caveats
A single stray adatom is not the surface (the 5 % rule handles it); bin width has a 0.5 Å floor so bin counts can exceed `bins`.

## Validation
Unit fixtures (slab + probes at known depths); export goes through the shared ToolExport (CSV / Excel via the pure-Swift Zip writer, ToolExportTests + ZipTests). Since GJOB-164 the registered tool is the only Z-profile in the app — the fixed inspector section is gone; MCP `z_profile` is a deprecated alias of `analyze(tool: "z_profile")`.

## Pointers
- Manual: docs/manual/html/tools.html#z_profile (section “z_profile — Z-profile”)
- Source & tests: Sources/LAMMPSCore/Analysis/ZProfileTool.swift, ZProfileAnalysis.swift; Tests/AppTests/ZProfileTests.swift, AnalysisFoundationTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
