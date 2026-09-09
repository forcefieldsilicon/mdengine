# MDEngine skills — subject playbooks for Claude sessions

Each folder is a `SKILL.md` that a user's Claude session (Claude Code, Claude.ai with the
MDEngine connector, or any MCP client) can load to work on a subject the MDEngine way: the
method, the decisions that matter, the tools that produce the numbers, and the caveats that
must reach the report. They are written for the agent, not the human — short, decision-first,
with the commands and tool ids spelled out.

| skill | subject |
|---|---|
| `md-adhesion-afm/` | MD-AFM pull-off: tip and substrate models, curvature scaling to a real probe, solvent choice, what to report |
| `md-accuracy-loop/` | MD → contact motifs → DFT clusters → fine-tuned MLIP → MD at scale; gate zero before spend |
| `md-potentials/` | how force fields / potentials are chosen per system class, and how to record the choice |
| `md-survey-then-commit/` | the planning pattern: a cheap survey with a recorded verdict before every GPU-hour, DFT point or long run |
| `md-substrate-potential-pairing/` | validate a slab/tip model and its potential together before production; step-0 preflight; surface charge models |

**One skill per analysis tool** (`skills/tools/<id>/SKILL.md`, enforced by `Tests/AppTests/ToolSkillsTests.swift`):

| skill | tool |
|---|---|
| `tools/adhesion/` | Adhesion — Is the ligand still bound, and why |
| `tools/column_field/` | Colour by column — Colour atoms by any per-atom quantity (x/y/z, charge, c_pe, vx …) and profile its mean along an axis. Also the smoke tool for the overlay path. |
| `tools/conformation/` | Conformation (RMSD · Rg · DSSP · clusters) — Is the protein holding its fold |
| `tools/crystallinity/` | Crystallinity — Is my oxide/metal amorphous or crystalline, and which phase |
| `tools/deformation/` | Deformation — Where did the material yield |
| `tools/diffusion/` | Diffusion (MSD) — How mobile are the atoms |
| `tools/fep_results/` | FEP results (ΔΔG) — Which compound to make next |
| `tools/kinetics_tramd/` | Unbinding kinetics (τRAMD) — How long does it stay bound |
| `tools/ptm/` | PTM (orientation & grains) — Grains and orientation |
| `tools/pulloff_energetics/` | Pull-off energetics — What did the pull cost |
| `tools/rdf/` | Radial distribution — How is the material packed |
| `tools/thermo/` | Thermo (log.lammps) — What did the LAMMPS run report |
| `tools/z_profile/` | Z-profile — Deposition/oxidation |

Install for Claude Code: copy a folder into `~/.claude/skills/` (or point `skills` at this
directory). The MCP tools referenced (`analyze`, `render_image`, hosted runs) are the ones
`mdengine-mcp` exposes; the CLI equivalents are `mdengine analyze …`.
