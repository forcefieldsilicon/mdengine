---
name: tool-conformation
description: MDEngine analysis tool `conformation` — Conformation (RMSD · Rg · DSSP · clusters) (Structure & order). Is the protein holding its fold: RMSD to a reference, radius of gyration, per-atom RMSF, DSSP secondary structure, frame clustering, PCA.
---

# Conformation (RMSD · Rg · DSSP · clusters) (`conformation`)

**Category:** Structure & order · **Produces:** perAtomField, scalar, timeSeries · **Requires:** nothing

## When to use
Is the protein holding its fold: RMSD to a reference, radius of gyration, per-atom RMSF, DSSP secondary structure, frame clustering, PCA.

## Decisions that matter
`selection`: ca (default) | backbone | heavy | all — ca/backbone need the `name` column (extended XYZ from smd_pull ≥ 2026-09-08), else heavy fallback with a note. `quantity` field: rmsf | dssp | displacement. Reference = frame 0 unless a reference frame is set (app picker, MCP reference_frame, CLI --reference).

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `clusterCount` | `4` | see Method in the manual section |
| `pcaComponents` | `2` | see Method in the manual section |
| `quantity` | `rmsf` | see Method in the manual section |
| `selection` | `ca` | see Method in the manual section |
| `clusterRMSDCutoff` | null | Å; null = k-medoids with clusterCount, set = cutoff (gromos) clustering |
| `group` | null | GroupSelector; null = all atoms |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Conformation (RMSD · Rg · DSSP · clusters); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze conformation <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "conformation", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "conformation"}` when the tool publishes a field.

## Reading the result
RMSD (fit) vs no-fit, Rg, cluster id + populations, PC1/PC2 projection with variance explained, secondary-structure percentages; scalar = RMSD (chart over frames). Trajectory-level results are cached per file load.

## Caveats
DSSP helix ends are never H (needs two consecutive 4-turns); >400 frames subsamples the RMSD matrix for clustering (noted).

## Validation
Ideal helix interior 100 % H; antiparallel sheet 62.5 % E; RMSD 0 on rigid motion; RMSF only on the wiggling atom; real GnRH pull: 65 % helix at frame 44.

## Pointers
- Manual: docs/manual/html/tools.html#conformation (section “conformation — Conformation (RMSD · Rg · DSSP · clusters)”)
- Source & tests: Sources/LAMMPSCore/Analysis/ConformationTool.swift, Superposition.swift, SecondaryStructure.swift; Tests/AppTests/ConformationToolTests.swift, ProteinFixtures.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
