# OpenMM runner image (hosted accelerated tier)

Same pull-runner contract as `../runner-gpu` (see `hosted/CONTRACT.md`): the pod boots, fetches one
job with a one-shot token, runs the job spec's `launch` line in `/work`, uploads a results tarball,
POSTs `done`, exits. No inbound network, no ssh, no public IP needed.

The difference from the LAMMPS image is only what is on PATH:

| | LAMMPS image | OpenMM image |
|---|---|---|
| binary | `/usr/local/bin/lmp` (KOKKOS/CUDA) | `/opt/conda/bin/python3` with `openmm` |
| default `launch` | `{lmp} -in {input} -k on g 1 -sf kk …` | `python3 {input}` |
| per-GPU-arch build | yes (`KOKKOS_ARCH`) | **no** — OpenMM JITs its CUDA kernels at runtime |
| job `input` | a LAMMPS deck | a Python script |

Job spec shape:

```json
{"input": "run.py", "launch": "python3 {input}", "gpu": "any", "wall_limit_s": 3600}
```

Ships: openmm 8.x, openmmforcefields, pdbfixer, mdtraj, mdanalysis, numpy, scipy (conda-forge,
`cuda-version=12.*`). `OPENMM_CPU_THREADS=1` — one GPU, one job, one pod.

Build: `gh workflow run runner-openmm.yml` (no GPU needed to build). The image must be **public** on
GHCR so Community pods can pull it anonymously; it contains only upstream packages and these two
scripts.

Smoke test on a pod: `start.sh` prints the GPU and the OpenMM version before serving ssh (dev mode,
no `MDE_JOB_ID`).
