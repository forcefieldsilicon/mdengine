---
name: tool-campaign_matrix
description: MDEngine analysis tool `campaign_matrix` — Campaign matrix (tiers) (Adhesion & binding). Which of my ligands, on which receptor: the ligand × receptor grid from a screening campaign as tiers with error bars — not a rank order — plus selectivity ratios, resolution floor, coverage and compromises.
---

# Campaign matrix (tiers) (`campaign_matrix`)

**Category:** Adhesion & binding · **Produces:** scalar, timeSeries · **Requires:** sideFile

## When to use
A customer's question is a grid — their ligand set against their receptor panel — not a run. This tool reads
the `matrix.json` a whole campaign produced and answers "which ligand, on which receptor, and how sure are we".

## Decisions that matter
Produce `matrix.json` with `delivery/module1/campaign.py matrix <campaign>` (schema `dsuite.matrix/1`).
`sortBy`: tier | value | band (band = widest first = the re-run queue). `receptor` picks the column the
chart's frame axis walks; null = the campaign's primary receptor. **Tiers, not a rank order:** two cells are
separated only when their IQR/2 bands do not overlap, so the order *within* a tier is not measured and must
not be quoted. **An undelivered cell is absent, never zero** — a campaign's normal state is a few delivered
cells and a prep queue, because system prep, not GPU time, is the bottleneck.

## Parameters (defaults from the registry — keep in sync; a test checks these keys)
| key | default | meaning |
|---|---|---|
| `sortBy` | `tier` | order of the walked column: tier (producer order) / value / band |
| `receptor` | null | which receptor column the frame axis walks; null = primary |
| `jsonPath` | null | matrix.json; null = locate near the trajectory or up at the campaign root |

## How to run
- App: Inspector ▸ Tools ▸ + Add tool ▸ Campaign matrix (tiers); sections compute only while expanded.
- CLI: `mdengine analyze campaign_matrix <campaign dir or matrix.json> [--frame N] [--param sortBy=band]`
- MCP: `analyze {path, tool: "campaign_matrix", frame, params}`

- The path may be the campaign directory, a seed directory inside it, or `matrix.json` itself: no trajectory
  is needed. With a side file, `--frame N` / MCP `frame` means cell index N within the walked column.

## Reading the result
Coverage (n of N cells) and the resolution floor come first — they qualify every number below them. Then one
row per ligand across every receptor, where a cell shows either `[tier] value ± band (n=seeds)` or its state
(`needs-prep`, `prepared`, `partial`, `failed`). Then the walked column with the scrub marker, then the
selectivity ratios vs the primary receptor, each flagged when its band includes the null (no selectivity).
Notes carry the tiers-not-ordinal rule, the count and names of absent cells, and every high-severity
compromise behind the numbers.

## Caveats
Tiers and selectivity are computed over the delivered subset only — an absent cell is not a weak cell. The
band is IQR/2 over a few seeds: a coarse band, not a σ. Everything the underlying protocol compromised
(screen-rate velocity, truncated caps, implicit solvent) is unioned into the notes and belongs on the front
page of anything a customer reads.

## Validation
Schema/ordering/absent-cell/unresolved-selectivity tests plus an empty-campaign render; verified end to end
through the CLI on `delivery/runs/campaigns/gnrhr-panel-20260909` (10 ligands × 3 receptors, 1/30 delivered).

## Pointers
- Manual: docs/manual/html/tools.html#campaign_matrix (section “campaign_matrix — Campaign matrix (tiers)”)
- Source & tests: Sources/LAMMPSCore/Analysis/CampaignMatrixTool.swift, CampaignMatrix.swift; Tests/AppTests/CampaignMatrixToolTests.swift; delivery/module1/campaign.py
- Contract: Sources/LAMMPSCore/Analysis/AnalysisTool.swift (AnalysisTool / ToolResult)
- Subject skills: skills/md-adhesion-afm, skills/tools/fep_results (its sibling), ~/.claude/skills/dsuite-campaign

_Rule: any change to this tool's parameters, outputs or method updates this file in the same commit (Tests/AppTests/ToolSkillsTests.swift enforces the parameter keys and the manual anchor)._
