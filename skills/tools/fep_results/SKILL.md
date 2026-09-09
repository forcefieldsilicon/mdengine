---
name: tool-fep_results
description: MDEngine analysis tool `fep_results` — FEP results (ΔΔG) (Adhesion & binding). Which compound to make next: ranked ΔΔG ± uncertainty from an OpenFE relative binding free energy run, overlap/convergence flags, cycle closure.
---

# FEP results (ΔΔG) (`fep_results`)

**Category:** Adhesion & binding · **Produces:** scalar, timeSeries · **Requires:** sideFile

## When to use
Which compound to make next: ranked ΔΔG ± uncertainty from an OpenFE relative binding free energy run, overlap/convergence flags, cycle closure.

## Decisions that matter
Produce results.json with `delivery/fep/rbfe_openfe.py plan → run --edge → analyze` (openfe is conda-forge only; PyPI `openfe` is an impostor). `sortBy`: rank | ddG | error. The chart's frame axis is the edge index.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `sortBy` | `rank` | see Method in the manual section |
| `jsonPath` | null | results.json; null = locate near the trajectory |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ FEP results (ΔΔG); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze fep_results <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "fep_results", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "fep_results"}` when the tool publishes a field.

- The path may be the run directory or the side file itself (`.json`/`.csv`/`log.lammps`): no trajectory is needed. With a side file, `--frame N` / MCP `frame` means row or edge index N (use the trajectory for `--all`/`frames`).

## Reading the result
Ranked ligand table (ΔG relative to the network mean unless cinnabar MLE), per-edge ΔΔG ± σ, overlap min, converged flag, cycle closure; notes list every edge failing a gate (overlap < 0.03, not converged, |closure| > 1 kcal/mol) — do not rank on those.

## Caveats
Absolute affinities need experimental anchors; ~1 kcal/mol is the realistic accuracy (Wang 2015).

## Validation
Schema/ordering/flag tests; first real openfe 1.12 run (CDK8 solvent leg) rendered with its unconverged flags.

## Pointers
- Manual: docs/manual/html/tools.html#fep_results (section “fep_results — FEP results (ΔΔG)”)
- Source & tests: Sources/LAMMPSCore/Analysis/FEPResultsTool.swift, FEPResults.swift; Tests/AppTests/FEPResultsToolTests.swift; delivery/fep/
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
