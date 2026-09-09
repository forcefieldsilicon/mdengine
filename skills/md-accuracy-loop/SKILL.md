---
name: md-accuracy-loop
description: Two-stage accuracy loop for interface MD — cheap MD finds contact motifs, DFT cluster scans cover the motif types, a foundation MLIP (MACE-OFF/MACE-MP/UMA) is fine-tuned and run at scale; gate zero (zero-shot MLIP vs classical forces) before any DFT spend. Use when "MD energetics are not accurate enough".
---

# MD → motifs → DFT → MLIP → MD (the accuracy loop)

## The one correction people need
Do **not** ask DFT to make the two partners "touch at every spot". Contact configurations are millions;
contact **motif types** are dozens (amine–silanol, carboxylate–metal, aromatic ring–surface, backbone
amide–oxide, water bridge). DFT covers the motif types on small cluster models; "every spot" coverage
comes from MD statistics run with the improved potential.

## Stages
0. **Gate zero (free).** Run a zero-shot foundation MLIP (MACE-OFF23 for organics, MACE-MP-0 for
   inorganics, UMA/eSEN for both) on 30–50 saved MD frames and compare forces with the classical FF:
   RMSE (kcal/mol/Å), cosine similarity, interface vs bulk split, and the vacuum-vs-implicit
   difference as a yardstick. If the MLIP already agrees within the classical model's own solvent
   sensitivity, you may not need DFT for the question at hand.
1. **Cheap MD** (amber14/OpenFF + UFF/INTERFACE for the inorganic side). Tools: `adhesion` with
   `quantity: interactions` → per-residue/site motif counts, occupancy, lifetimes; `conformation`.
2. **Motif clusters.** For each motif with occupancy above a threshold: cut a 100–400-atom cluster
   (ligand fragment + surface patch, capped), several geometries from MD, a distance scan along the
   contact normal (±1.5 Å in 0.25 Å steps).
3. **DFT** on the clusters: PBE-D3(BJ) or r²SCAN-D4, plane-wave (CP2K/Quantum ESPRESSO) for surfaces,
   ORCA for molecular pairs; def2-TZVP-quality or 500 eV cutoffs. Record energies AND forces.
   Foundations for the choices (basis sets, HF/DFT limits, geometry optimisation) are in arvand's
   molecular-modeling course notes (~/Documents/Classes-2/Molecular Modeling/Course Material) —
   consult before quoting an accuracy.
4. **Fine-tune** the foundation MLIP on the DFT points (few hundred configurations suffice); validate on
   held-out scans; report force RMSE per element.
5. **MD at scale** with the fine-tuned MLIP: LAMMPS `pair_style mace` (ML-IAP) or OpenMM via
   `openmm-ml`; hosted GPU runner. Re-run the adhesion/pull-off analysis; the Bell–Evans/Jarzynski
   gating in `pulloff_energetics` applies unchanged.

## Gate-zero result on record (2026-09-08, GnRH pull run, 45 frames)
MACE-OFF23 zero-shot vs amber14: force RMSE 10.9 kcal/mol/Å (vacuum) / 12.0 (OBC2), cosine 0.79; the
classical vacuum-vs-implicit yardstick is 3.0 → the gap is 3.7× a solvent model and **uniform**
(interface 11.8 vs bulk 10.8). Cause: the MLIP is short-range (no long-range Coulomb) and the system
is +1e, off MACE-OFF's neutral-organics training set. Consequence: cluster-motif fine-tuning alone
cannot repair a missing 1/r tail — stage 4 needs a model with explicit electrostatics (MACE +
point charges/long-range term, UMA/eSEN with charge handling) or a delta-learning hybrid (classical
electrostatics + MLIP short range). Details: ~/Gitinama/delivery/mlip/gate0-report.md.

## DFT-stage results on record (2026-09-08, delivery/dft)
- PBE-D3(BJ) benzene–water vs the S22 reference −3.29 kcal/mol: def2-SVP −4.51, def2-TZVP −4.21,
  **TZVP + counterpoise −3.29**. Counterpoise is required at triple zeta for interaction energies, not
  optional; SVP is a screen only.
- Vacuum salt-bridge scans are unscreened Coulomb: a neutral ion-pair cluster from the GnRH run was
  monotonically repulsive across −0.5…+0.75 Å (minimum below the window). Charged/ionic motifs need
  continuum solvent (ddCOSMO/PCM) and a wider negative window, or they teach the model gas-phase
  electrostatics.
- Net-charged clusters (−1) at SVP without diffuse functions did not converge in 18 min/point; recut
  to a neutral ion pair (35 atoms) → 102 s/point on CPU. Cut clusters neutral where possible.
- `pyscf-dispersion` is broken against numpy ≥ 2.3; use the `dftd3` Python bindings and add D3(BJ) to
  energy and gradient by hand. The macOS arm64 pyscf wheel is single-threaded — real scans belong on the
  hosted `dft` runner (GPU4PySCF).
- Motif rows from the Adhesion tool are chain-qualified (`A:ASP 3`) so clusters map back to atoms.

## Caveats that must reach the report
- DFT noncovalent errors ~1–2 kcal/mol (dispersion correction choice matters); no water unless modelled.
- A foundation MLIP is only as good as its training domain: check element coverage and net charge
  (MACE-OFF is trained on neutral organics — charged peptides need care).
- Fine-tuning improves the motifs you sampled; extrapolation to unsampled chemistry is unvalidated.
- Cost: cluster DFT is hours on a GPU node per motif set; state the budget before starting stage 3.

## Tool skills
See `skills/tools/adhesion (motif discovery)`, `skills/tools/pulloff_energetics`, `skills/tools/deformation`.
