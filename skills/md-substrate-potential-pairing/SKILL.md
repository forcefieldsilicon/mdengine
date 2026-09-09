---
name: md-substrate-potential-pairing
description: The substrate–potential pairing rule — a slab/surface/tip model and its interatomic potential are validated TOGETHER before any production run (density, lattice, surface energy, no sinking, timestep); the step-0 preflight checklist and what to record. Use before launching, resuming or re-decking any run whose substrate or potential changed.
---

# Substrate ↔ potential pairing rule

A substrate built for one potential is not a substrate for another. Converting a slab (new element
mapping, new lattice constant, new surface termination, new potential family) means re-validating the
PAIR before production — the sinking surfaces, cavities and lost atoms of 2026-08/09 all came from
skipping this.

## Step-0 preflight (every time the pair changes)
1. **Lattice/density**: minimise + short NVT at the target T; density within 2 % of the reference for
   that potential (not the experimental value — the potential's own equilibrium), lattice constant
   likewise. Amorphous models: report the fill fraction against the bulk density (RSA tips reach ~72 %).
2. **Surface**: the top layer stays a surface — no sinking, no spontaneous reconstruction beyond what the
   literature reports for that potential; surface energy within ~20 % of the potential's published value
   when available.
3. **Timestep & thermostat**: ReaxFF ≤ 0.25 fs; EAM/Buckingham 1–2 fs; charged/hydroxylated INTERFACE
   surfaces need PME or a long real-space cutoff; note the barostat coupling for slabs (z only or none).
4. **Cross terms**: for mixed systems (bio–inorganic, ceramic–metal) state how cross interactions are
   built (INTERFACE/CHARMM-METAL tables, Lorentz–Berthelot guesses, MLIP) — a guess is allowed only
   when labelled.
5. **Charges**: a surface model without partial charges captures dispersion/steric adhesion only; in
   water, oxides and nitrides are hydroxylated and charged at pH 7 (IEP ≈ 4–6 for Si₃N₄) — the
   electrostatic + hydration half of adsorption is missing. Use INTERFACE FF hydroxylated-silica-type
   terminations (with the pH-dependent deprotonation fraction) or say the number is rank-order only.
   Caveat: a one-parameter IEP model (fraction = 1/(1+10^(IEP−pH))) saturates — 99.6 % deprotonated at pH 7.4
   for IEP 5 — which is far above a site-binding treatment; set the deprotonated fraction explicitly (a few
   per cent to ~20 % of silanols at pH 7 is the usual range) and report it.
6. **Fixture on record**: keep the validation run (log + one frame) next to the potential in
   `delivery/potentials.yaml`; the advisor prints the fixture path with every `forcefield: auto` choice.

## Record in every run
Potential name/file/reference, the fixture that validated the pair, the timestep, the cross-term rule,
and the surface charge model — in `outcomes.json` (or `hostdiag`) so the report cannot omit it.

## Pointers
skills/md-potentials (what to choose), skills/md-adhesion-afm (tip/substrate models), md-production
skill (Gitinama, LAMMPS runs), delivery/potentials.yaml + potential_advisor.py (GJOB-155).
