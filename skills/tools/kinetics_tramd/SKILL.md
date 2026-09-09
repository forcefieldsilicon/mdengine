---
name: tool-kinetics_tramd
description: MDEngine analysis tool `kinetics_tramd` — Unbinding kinetics (τRAMD) (Adhesion & binding). How long does it stay bound: τRAMD residence time with bootstrap CI from tramd_times.csv, survival curve over replicas.
---

# Unbinding kinetics (τRAMD) (`kinetics_tramd`)

**Category:** Adhesion & binding · **Produces:** scalar, timeSeries · **Requires:** sideFile

## When to use
How long does it stay bound: τRAMD residence time with bootstrap CI from tramd_times.csv, survival curve over replicas.

## Decisions that matter
Run `delivery/module1/tramd.py` (replicas × seeds; dry_run for smoke). Scalar = fraction still bound at the frame's time.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `temperature_K` | `300` | see Method in the manual section |
| `csvPath` | null | tramd_times.csv; null = locate near the trajectory |
| `frameTime_ps` | null | frame → time when the file has no time axis |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Unbinding kinetics (τRAMD); sections compute only while expanded (frozen during playback; the overlay keeps following).
- CLI: `mdengine analyze kinetics_tramd <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "kinetics_tramd", frame|frames, params, reference_frame}`; figures: `render_image {overlay: "kinetics_tramd"}` when the tool publishes a field.

- The path may be the run directory or the side file itself (`.json`/`.csv`/`log.lammps`): no trajectory is needed. With a side file, `--frame N` / MCP `frame` means row or edge index N (use the trajectory for `--all`/`frames`).

## Reading the result
τ (ps) with 95 % CI, per-seed τ, replica count, censored fraction; a single replica's τ reads as half its time (CDF anchored at zero).

## Caveats
τRAMD is a k_off rank order within a series; calibrate against measured values for absolute rates. Full runs are minutes on the hosted GPU, hours on CPU.

## Validation
Synthetic replica sets (interpolation, bootstrap reproducibility, censoring, CRLF, locate); CPU dry run on the helix complex.

## Pointers
- Manual: docs/manual/html/tools.html#kinetics_tramd (section “kinetics_tramd — Unbinding kinetics (τRAMD)”)
- Source & tests: Sources/LAMMPSCore/Analysis/KineticsTool.swift, RAMDResults.swift; Tests/AppTests/KineticsToolTests.swift; delivery/module1/tramd.py
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult); governor rules: LAMMPSApp/design/analysis-tools-2026-09-08.md §1b
- Subject skills: skills/md-adhesion-afm, skills/md-accuracy-loop, skills/md-potentials

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
