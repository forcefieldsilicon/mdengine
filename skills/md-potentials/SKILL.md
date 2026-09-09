---
name: md-potentials
description: How MDEngine/delivery protocols choose force fields and interatomic potentials per system class (protein, small molecule, metal, oxide, ceramic–metal impact, bio–inorganic interface, MLIP fallback), the pairing rule, and how to record the choice with references and validation. Use before any run whose potential is not already fixed by the user's deck.
---

# Choosing the potential

## Now: `forcefield: auto` (GJOB-155, 2026-09-08)
The delivery protocols (smd_pull, tramd, mmgbsa, afm_pull) no longer hardcode a force field. `forcefield:
auto` (the default) calls `delivery/potential_advisor.py`, which inspects the input (standard residues,
HETATM/nonstandard residues, small molecules, inorganic chains such as the AFM tip, lattices) against the
registry `delivery/potentials.yaml` (23 entries, each with reference, validation fixture, failure modes,
cost tier, surface charge model) and writes `outcomes.json["potential"]` = {chosen, why, caveats,
fixtures}. An explicit XML list still wins and is recorded as "chosen by hand, no fixture". Small-molecule
templates (OpenFF Sage / GAFF via openmmforcefields) need `openff-toolkit`, which is conda-forge only —
the scratch micromamba env used for OpenFE has it; the pip venv does not, and the advisor says so.

## Before 2026-09-08 (kept for context; superseded by the advisor)
- **Bio protocols (OpenMM, delivery/module1)**: amber14 (ff14SB) for proteins, implicit `gbn2`/`obc2`
  or explicit TIP3P-FB; small molecules need OpenFF Sage / GAFF2 — available in the FEP environment
  (`delivery/fep`), not yet wired into `smd_pull.py`/`afm_pull.py`. Nonstandard residues (pGlu,
  D-amino acids, C-terminal amides) need templates before a run — say when they were dropped.
- **Inorganic tip/substrate in AFM runs**: UFF Lennard-Jones (Si σ 3.83 Å ε 0.40 kcal/mol; N σ 3.26 Å
  ε 0.069), no charges, frozen atoms. Adequate for rank-order; INTERFACE FF (Heinz) or CHARMM-METAL
  for anything quoted as an energy.
- **Materials (LAMMPS decks)**: the deck carries the potential; the hosted preflight only checks the
  style exists. Pairing rule (md-production skill): the substrate and the potential must be validated
  together — a slab converted to a new potential is re-equilibrated and checked (density, surface,
  no sinking) before production.
  - Al metal: EAM (Mishin 1999 / Foiles). Al₂O₃ mechanical: Matsui or Vashishta Buckingham. Al/O
    reactive (oxidation, oxide fracture, alumina–alumina impact exposing metal): **ReaxFF Al/O
    (Hong & van Duin 2015)**, validated in-house 2026-09-04; COMB3 as the alternative.
  - Si₃N₄/SiO₂: Vashishta or Tersoff for bulk mechanics; ReaxFF Si/O/N for chemistry.
- **Fallback for anything unparametrised**: a foundation MLIP (MACE-MP-0 inorganic, MACE-OFF23
  organic, UMA/eSEN both) zero-shot, with gate zero from `md-accuracy-loop` before trusting it.

## Pairing rule
See `skills/md-substrate-potential-pairing` — the slab and the potential are validated together (step-0 preflight) before production; uncharged surface models are rank-order only.

## Selection rule of thumb
1. What must be reproduced: structure/mechanics → classical (EAM/Buckingham/Tersoff); bond
   breaking/oxidation → ReaxFF or MLIP; biomolecule conformations/binding → amber/CHARMM/OpenFF.
2. Mixed systems (bio–inorganic, ceramic–metal): a potential validated for BOTH sides or a MLIP;
   otherwise state that cross terms are Lorentz–Berthelot guesses.
3. Record: potential name + file + reference + validation fixture + known failure modes in
   `outcomes.json` (or the run's `hostdiag`). The planned `potentials.yaml` registry + `forcefield:
   auto` advisor (GJOB-155) will do this automatically; until then, write it by hand.

## Never
Present a UFF/LJ-only inorganic–bio adhesion energy as quantitative; run ReaxFF with a timestep
above 0.25 fs; change the potential mid-study without re-running the fixtures.

## Tool skills
See `skills/tools/crystallinity`, `skills/tools/ptm`, `skills/tools/rdf`, `skills/tools/thermo (validation fixtures per potential)`.
