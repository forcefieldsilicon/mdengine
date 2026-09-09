---
name: tool-adhesion
description: MDEngine analysis tool `adhesion` — Adhesion (Adhesion & binding). Is the ligand still bound, and why: A–B contacts, hydrogen bonds, salt bridges, π-stacking, cation–π, hydrophobic contacts, COM/min distance, per-residue map, H-bond occupancy and lifetimes over the trajectory, rupture frame; MM/GBSA rows when mmgbsa.py side files exist.
---

# Adhesion (`adhesion`)

**Category:** Adhesion & binding · **Produces:** perAtomField, scalar, timeSeries · **Requires:** groups

## When to use
Is the ligand still bound, and why: A–B contacts, hydrogen bonds, salt bridges, π-stacking, cation–π, hydrophobic contacts, COM/min distance, per-residue map, H-bond occupancy and lifetimes over the trajectory, rupture frame; MM/GBSA rows when mmgbsa.py side files exist.

## Decisions that matter
Groups: `{kind: label, name: chain, values: [A]}`, `{kind: elements, elements: [Si, N]}` (AFM tip), `{kind: slab, axis: z, min, max}`, `{kind: all}`. `quantity: contacts | interactions` picks the overlay field. Match `contactCutoff` to the protocol (smd_pull uses 4.0 Å). Fingerprint types need `name` + `resname` labels.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `contactCutoff` | `4.5` | see Method in the manual section |
| `hbondAngle` | `120` | see Method in the manual section |
| `hbondDistance` | `3.5` | see Method in the manual section |
| `lifetimes` | `true` | see Method in the manual section |
| `perResidue` | `true` | see Method in the manual section |
| `quantity` | `contacts` | see Method in the manual section |
| `saltBridgeCutoff` | `4` | see Method in the manual section |
| `groupA` | null | GroupSelector; null = auto (chains → resnames → elements) |
| `groupB` | null | GroupSelector; null = auto |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Adhesion; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze adhesion <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "adhesion", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "adhesion"}` when the tool publishes a field.

- AFM runs: select the tip by `{kind: label, name: chain, values: [T]}` — an element group (Si, N) also matches protein nitrogen.

- Per-residue rows are chain-qualified when the file carries chain labels (`A:ASP 3`), so both chains can have a residue 1 and downstream tools (DFT motif clusters) can map a row back to atoms (2026-09-08).

## Reading the result
Counts per interaction type, top residues, occupancy/lifetime table (fraction of frames, mean run length), contact frequency; scalar = contact count (chart = binding history; rupture = first frame contacts stay 0). MM/GBSA ΔG_bind and per-residue ΔE when `mmgbsa.csv`/`interaction_energy.csv` are beside the trajectory.

## Caveats
Rank-order energetics only (MM/GBSA single-trajectory); no water in implicit runs; π geometry criteria are PLIP-style defaults.

## Validation
Hand-built pairs for every interaction type; 200-atom brute-force contact count; protocol gate: contacts identical to force_curve.csv on all 45 frames of the helix rerun.

## Pointers
- Manual: docs/manual/html/tools.html#adhesion (section “adhesion — Adhesion”)
- Source & tests: Sources/LAMMPSCore/Analysis/AdhesionTool.swift, Fingerprint.swift, Groups.swift, InteractionEnergy.swift; Tests/AppTests/AdhesionToolTests.swift, FingerprintTests.swift; delivery/module1/mmgbsa.py
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
