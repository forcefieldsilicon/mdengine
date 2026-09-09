---
name: md-adhesion-afm
description: MD-AFM single-molecule pull-off — Si3N4/Au tips, substrates, adsorbed ligands; curvature scaling to a real probe (sagitta + JKR/DMT); implicit vs explicit water; what to report. Use for any "pull X off Y with an AFM tip" or adhesion-force question.
---

# MD-AFM pull-off (adhesion) — the MDEngine way

## Decide these first
1. **Question**: rank-order (which residue/tip/surface sticks more) or an absolute force for a paper?
   Rank-order → implicit solvent, one seed per condition, displacement control.
   Absolute → explicit water + ions, ≥ 5 seeds, report distributions, still displacement control.
2. **Cantilever**: displacement control with an infinitely stiff cantilever (tip frozen, moved by the
   "piezo"; force = sum of forces on tip atoms). Say so in the report: loading-rate framing (Bell–Evans)
   then uses the measured force–distance slope as the effective stiffness.
3. **Geometry**: real apex radii are 10–50 nm; MD tips are 1–3 nm. Use the sagitta rule below to pick
   flat-periodic, curved cap, or pyramid, and convert with contact mechanics afterwards.

## Pocket ligand or surface ligand? (decide before building a tip)
A bare tip cannot reach a ligand bound inside a receptor pocket: on the GnRH receptor the apex touched
the extracellular surface after 0.2 Å of descent with the peptide still 16 Å away (GPCR pockets are
deeper and narrower than any nanometre apex). Contact mode then measures tip–receptor adhesion — a
valid number for the wrong question. For pocket ligands use **tethered mode** (the experimental
single-molecule force spectroscopy geometry): the ligand is linked to the apex through a harmonic
tether standing in for the PEG linker, the receptor is immobilised, the tip retracts and the force is
tether extension × stiffness while the tip still interacts sterically with the surface. Use **contact
mode** only for ligands adsorbed on a substrate (gold, silica, nitride, graphene).

### Tethered mode details (afm_pull.py, 2026-09-08)
`afm.mode: tethered`, `tether_atom` (N-term | C-term | `name X` | `resSeq n name X`), `tether_k_kJ_mol_nm2`
(500 ≈ PEG-linker), `tether_length_nm`, `tether_slack_nm`. The linker is a harmonic force on the tether
atom toward the tip apex (the anchor moves with the piezo). If the configured rest length cannot span
from a clearance-safe apex to the tether atom (GnRH: 31.5 Å), the protocol lengthens it to start at
rest + slack instead of pre-tensioning — physically "use a longer PEG spacer", recorded in
`outcomes.tether`. In tethered mode `force_pN` = tether tension (what the cantilever reads) and
`n_contacts_total` = ligand–receptor contacts (what ruptures); the tip's own force is `tip_force_pN`.
Outcomes: `afm_rupture_force_pN`, `afm_rupture_frame`, `afm_work_kJ_mol`, `afm_detachment_mode`
(ligand-out | tether-limit).

## Sagitta rule (how flat is flat enough)
Over the ligand footprint L (lateral size of what touches the tip), a sphere of radius R deviates
from flat by h = L² / (8R). If h < ~0.1 nm (below the interaction range and thermal roughness) the
contact is flat at molecular scale → simulate a **periodic flat slab** (no edge-atom artefacts).
If h is a few tenths of a nm → **curved cap**; to shrink atoms keep L²/R constant (geometric
similarity of the sagitta), not R itself. A 1 nm pyramid is a picture, not a probe: its
low-coordination edge atoms dominate adhesion.

## Converting to the real probe
Simulate the intensive quantity, work of adhesion W (J/m²) = adhesion work / contact area, plus the
force–distance curve. Pull-off force for a real apex radius R:
F = 1.5 π R W (JKR, compliant/large adhesion) or F = 2 π R W (DMT, stiff/small adhesion). Report both
and the regime (Tabor parameter) — never report the raw nanotip force as "the AFM force".

## Water
Implicit (GBn2/OBC2) captures screening and a crude desolvation penalty. It misses structured water
on oxides/nitrides, water-mediated H-bonds, the hydrophobic effect and ions at charged surfaces
(silica, mica). Use explicit TIP3P + ions for headline numbers (~10× cost); keep the tip frozen and
size the periodic box to the slab.

## Protocol + tools (delivery/module1)
- `afm_pull.py` (run dir: inputs/ + config.json; blocks `tip`, `afm`, later `substrate`, `ligand`):
  approach → indent to `indent_force_pN` → dwell → retract at `retract_A_per_ns`. Outputs
  `force_curve.csv` (pulloff_energetics-compatible), `contacts.csv`, `outcomes.json`, extended-XYZ
  trajectory with tip chain `T` (Si/N) and `chain resname resid name` labels.
- MDEngine tools on the trajectory: `adhesion` with two group pairs (tip = elements Si,N vs ligand
  chain; ligand vs substrate) — contacts, H-bonds, salt bridges, π, hydrophobic, occupancy/lifetime;
  `pulloff_energetics` (F*, W, rupture frame; Bell–Evans only with ≥ 3 velocities; Jarzynski only
  with ≥ 10 pulls at ≤ 1 Å/ns); `render_image overlay:adhesion bonds:true` for figures.
- Detachment mode matters: "tip–peptide" (tip lets go) vs "peptide–substrate" (ligand comes off with
  the tip). Both are results; say which happened and at what force.

## Gotchas from the first runs (2026-09-08, GnRH + Si₃N₄ pyramid)
- Group the tip by **chain `T`**, not by elements Si,N: an element group also captures every protein
  nitrogen (2730 vs 2319 atoms, 198 fake contacts).
- Random-sequential-addition tips jam at ~72 % of bulk density: shape and surface chemistry are right,
  bulk density is low — say so; absolute adhesion scales with it.
- GBn2 accepts Born radii only in 1.0–2.0 Å and its table is fixed at createSystem: tip Si is clamped
  to 2.0 Å. Tip–tip nonbonded pairs are excluded via a CustomNonbondedForce interaction group (zero ε
  in the main force), not millions of explicit exceptions.
- Budget arithmetic first: 25 Å at 5 Å/ns is 5 ns of retraction; CPU implicit-solvent throughput for
  7.5 k atoms was ~4 ns/day (18 s/ps). Halving distances is not a substitute for choosing a velocity.
- `force_pN` is instantaneous and swings by hundreds of pN between frames; window-average before
  quoting a rupture force, and report the velocity next to it.
- Placement needs a clearance guard (`afm.min_clearance_A`): a pyramid's flanks hit the protein before
  its apex does, and an overlapping first frame produces NaN energies.

## Report checklist
tip material/shape/R and the sagitta h; solvent model; velocities and seeds; F* distribution (median
[IQR]); W in J/m² and the JKR/DMT-scaled force; detachment mode; which residues/sites carried the
adhesion (fingerprint table); the standard caveat: SMD/MD-AFM rates are 10⁶–10⁹× experiment.

## Tool skills
See `skills/tools/adhesion`, `skills/tools/pulloff_energetics`, `skills/tools/conformation`.
