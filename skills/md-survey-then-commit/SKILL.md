---
name: md-survey-then-commit
description: The planning pattern behind every expensive step in MDEngine work — survey cheaply, then commit GPU hours, DFT or human attention only where the survey says it matters. Use when sequencing a study, a pull-off campaign, a FEP network, kinetics runs, or any hosted spend.
---

# Survey cheaply, then commit effort where it matters

Every expensive step gets a cheap predecessor whose job is to say where NOT to spend.

| expensive step | cheap survey that must precede it | tool / job |
|---|---|---|
| any hosted GPU job | local CPU dry run of the same deck for a few steps | `dry_run` in every protocol; GJOB-161 |
| a pull-off (SMD or AFM) | pose stability check (short unrestrained run: RMSD + contacts hold) | Conformation + Adhesion tools; GJOB-163 |
| confirm-rate pulls (≤ 1 Å/ns) | screen-rate pulls (50 Å/ns) rank the ligands | smd_pull screen/confirm split |
| τRAMD (hours) and FEP (days) | SMD screen F*, contact stability, MM/GBSA rank → top-N only | GJOB-159 triage |
| 15 τRAMD replicas | batches of 5 with bootstrap CI; stop when the ranking is stable | GJOB-160 |
| a 24 GPU-h FEP edge | 2–3 window / 50 ps pilot per edge → overlap and mixing prediction | GJOB-158 |
| an AFM pull | static landing-site map + charged-tip approach grid | GJOB-157 site screen |
| DFT on contact motifs | gate zero (zero-shot MLIP vs classical forces), then SVP before TZVP | GJOB-154/156 |
| PTM on every atom | a-CNA everywhere, PTM only where a-CNA says "other" | GJOB-162 |
| production on a new substrate/potential pair | step-0 pairing preflight | skills/md-substrate-potential-pairing |
| full-frame analysis during playback | strided preview; full compute on expand/export | the governor (design §1b) |
| 4K video | 640×360 GIF preview | render defaults |

## Rules
- The survey must be able to say "no": it needs a threshold and a recorded verdict in the run's
  `outcomes.json`/study record, not just a number.
- The survey uses the same potential and the same groups as the committed step, or its ranking is not
  transferable (a bare-LJ tip screen ranks the wrong spots for a charged tip).
- Surveys are cheap enough to repeat; when the committed step surprises you, re-run the survey with the
  new knowledge before re-running the expensive step (the AFM "unreachable pocket" finding sent the
  work back to the site map, not to a longer pull).
- Budget arithmetic is part of the survey: velocity × distance × throughput before launching anything.
