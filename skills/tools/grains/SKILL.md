---
name: tool-grains
description: MDEngine analysis tool `grains` — Grain boundaries (Structure & order). Grain-level answers from PTM orientations: how many grains, how big, how much of the solid is boundary, and the misorientation distribution across those boundaries.
---

# Grain boundaries (`grains`)

**Category:** Structure & order · **Produces:** perAtomField, profile, scalar, timeSeries · **Requires:** nothing

## When to use
After a deposition, an anneal or a grain-growth run, when the question is about grains rather than
about atoms: how many, how big, what fraction of the solid is boundary, and what angles those
boundaries carry. Use `ptm` instead when you want the structure type or the per-atom orientation
itself; this tool is the grain summary built on the same orientations.

## Decisions that matter
`gbAngle` 5° is the usual low-angle cut — it is both the clustering cut and the cut below which two
touching clusters are merged back into one grain, so raising it merges grains and lowering it splits
them. `structure` fcc/bcc/hcp searches one template instead of three and costs a third as much; use
`any` only when you do not know the phase. `minimumGrainSize` 4 drops single atoms that happen to
match inside a melt. `rmsdThreshold` 0.1 is PTM's default; raise it with temperature. `profileAxis`
picks between the misorientation distribution and a boundary-fraction profile along `x`/`y`/`z`, and
`bins` (18) is that histogram's resolution. `quantity` chooses the per-atom field.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `bins` | `18` | histogram bins; the misorientation histogram spans a fixed 0–62.8° (cubic) |
| `gbAngle` | `5` | degrees of disorientation that separate two grains |
| `minimumGrainSize` | `4` | clusters smaller than this are not grains |
| `profileAxis` | `misorientation` | `misorientation` distribution, or `x`/`y`/`z` boundary-fraction profile |
| `quantity` | `grain` | `grain` (id, 0 = boundary) · `gb` (boundary flag) · `misorientation` (degrees) |
| `rmsdThreshold` | `0.1` | PTM fit residual above which an atom matches nothing |
| `structure` | `any` | `any` · `fcc` · `bcc` · `hcp` |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Grain boundaries; colour by grain with `quantity: grain`.
- CLI: `mdengine analyze grains <trajectory> [--frame N|--all] [--param k=v] [--params '<json>'] [--csv out]`
- MCP: `analyze {path, tool: "grains", frame|frames, params}`; figures: `render_image {overlay: "grains"}`.

## Reading the result
Grain count is the scalar, so `--all` / `frames:` plots grain growth directly (a falling count).
Then: grain-boundary atom fraction, crystalline fraction, mean and median grain size in atoms and —
with a box — as an equivalent spherical diameter, mean misorientation over the boundary contacts,
and how many contacts that mean is over. The profile is the misorientation distribution by default.

## Caveats
Cost is PTM's match loop: ~55 µs per atom per template, so name the `structure` when you know it.
The equivalent spherical diameter divides the cell volume evenly among all atoms — with a big vacuum
or gas region it is an overestimate. Boundary atoms are found through the unmatched interface layer
(an atom touching two grains), which is why a sharp high-angle boundary shows up here even though a
neighbour-to-neighbour test sees nothing across it. A strided preview matches only every nth atom;
the rest take no part in the grain analysis, so read the count as a preview, not an answer.

## Validation
Synthetic polycrystals: perfect crystal → 1 grain, 0 % boundary; 30° bicrystal → 2 grains, mean
misorientation 30° ± 2°, boundary atoms within 1.5 lattice spacings of the interface; tricrystal
(0/20/40°) → 3 grains; 2 % thermal noise changes neither count nor angle.

## Pointers
- Manual: docs/manual/html/tools.html#grains (section “grains — Grain boundaries”)
- Source & tests: Sources/LAMMPSCore/Analysis/GrainBoundaryTool.swift, GrainSegmentation.swift (shared with `ptm`), PTMTool.swift; Tests/AppTests/GrainBoundaryToolTests.swift
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult)
- Related tools: `ptm` (orientation, structure type), `crystallinity` (a-CNA)

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
