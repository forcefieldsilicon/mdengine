---
name: tool-pulloff_energetics
description: MDEngine analysis tool `pulloff_energetics` — Pull-off energetics (Adhesion & binding). What did the pull cost: F(t) from the SMD/AFM protocol's force_curve.csv, rupture force F*, work of separation W, rupture frame; Bell–Evans across velocities and Jarzynski only when the data justify it.
---

# Pull-off energetics (`pulloff_energetics`)

**Category:** Adhesion & binding · **Produces:** scalar, timeSeries · **Requires:** sideFile

## When to use
What did the pull cost: F(t) from the SMD/AFM protocol's force_curve.csv, rupture force F*, work of separation W, rupture frame; Bell–Evans across velocities and Jarzynski only when the data justify it.

## Decisions that matter
Row i ↔ frame i by default (the protocol writes both at the same cadence). Pool run directories in `runDirs` for Bell–Evans (≥ 3 distinct velocities) / Jarzynski (≥ 10 pulls at ≤ 1 Å/ns). `temperature_K` sets kT.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `frameAlignment` | `row` | see Method in the manual section |
| `runDirs` | `[]` | see Method in the manual section |
| `temperature_K` | `300` | see Method in the manual section |
| `csvPath` | null | force_curve.csv; null = locate beside the trajectory / results*/ / one level up |
| `frameInterval_ps` | null | for frameAlignment: time |
| `seed` | null | which seed's rows; null = best frame-count match |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Pull-off energetics; sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze pulloff_energetics <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "pulloff_energetics", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "pulloff_energetics"}` when the tool publishes a field.

- The path may be the run directory or the side file itself (`.json`/`.csv`/`log.lammps`): no trajectory is needed. With a side file, `--frame N` / MCP `frame` means row or edge index N (use the trajectory for `--all`/`frames`).

## Reading the result
Row values at the frame, F* with its frame, W (CSV ∫F·dx_ref and trapezoid check), rupture frame, per-seed median [IQR], the gate rows (n/a with the reason). Scalar = force. The result also carries the WHOLE force curve as a frame-indexed series (`ToolResult.series`, label "Spring force (pN)"), so in the app the F(t) chart appears the moment the tool is added and its cursor follows playback — no "Chart over all frames" pass needed; that button re-runs per frame if you want to double-check the alignment. Under time alignment the series is placed at round((t − t₀)/frameInterval).

## Caveats
Always carry the note: SMD/AFM-MD loading rates are 10⁶–10⁹× experiment; F* is not an experimental number. Displacement-controlled AFM runs write tip displacement into ref_disp_nm.

## Validation
Synthetic CSVs (F*, W, gates, CRLF); helix run: F* 288.6 pN @ frame 36, W 59.17 kJ/mol, rupture 37 = outcomes.json.

## Pointers
- Manual: docs/manual/html/tools.html#pulloff_energetics (section “pulloff_energetics — Pull-off energetics”)
- Source & tests: Sources/LAMMPSCore/Analysis/PullOffEnergeticsTool.swift, ForceCurve.swift; Tests/AppTests/PullOffEnergeticsTests.swift; delivery/module1/smd_pull.py, afm_pull.py
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
