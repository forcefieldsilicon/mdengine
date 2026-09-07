# MDEngine GPU runner image (hosted accelerated tier, GJOB-088)

LAMMPS + KOKKOS/CUDA (REAXFF, QEQ, MANYBODY/EAM, MOLECULE, KSPACE, RIGID) with sshd, so a
rented GPU pod is driven by the existing `mdengine-mcp` remote transport (`submit_lammps host=`,
`fetch_job`) — the pod is just a `hosts.json` host.

## Per-job flow (MVP, manual → scripted)
1. Start a pod from this image on the provider (RunPod/Vast/Lambda); pass `PUBLIC_KEY`.
2. Add it to `~/.mdengine/hosts.json` (`ssh`, `ssh_options: ["-p", port]`, `workdir: /work`,
   `lmp: /usr/local/bin/lmp`, `launch` template with
   `-k on g 1 -sf kk -pk kokkos newton on neigh half` — exact entry in the Dockerfile header).
3. `submit_lammps host=<pod>` → `job_status` → `fetch_job`.
4. Destroy the pod. GPU-seconds used = the metered quantity (step 4 of the build order).

## Build
Needs an x86_64 host with nvcc (no GPU required to compile). Do NOT build on rakhsh
(arm64 + QEMU = many hours). Options: GitHub Actions on the public repo → ghcr.io, or a
$0.50 rented box. Pick `KOKKOS_ARCH` to match the GPU you will rent (header of Dockerfile).

## KOKKOS notes
- ReaxFF and QEq have `/kk` variants (`pair reaxff/kk`, `fix qeq/reaxff/kk`) — `-sf kk` picks them.
- EAM (`eam/alloy/kk`) supported. SMTBQ has NO KOKKOS path — CPU-only forever.
- `OMP_NUM_THREADS=1` in the image: one GPU, one host thread; `-pk kokkos` overrides.
- `-k on g 1` = 1 GPU. Multi-GPU needs MPI (not in this image on purpose — one pod, one GPU, one job).

## Security model
Decks are programs (`shell`). On a rented pod the sandbox is the pod: ephemeral, one job,
holds no credentials (the operator's public key only), destroyed after fetch. Where we control
the docker host, wrap `lmp` with the `../runner` hardening flags plus `--gpus all`.
