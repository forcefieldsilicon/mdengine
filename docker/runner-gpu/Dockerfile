# MDEngine GPU runner — LAMMPS + KOKKOS/CUDA for the hosted accelerated tier (GJOB-088).
#
# Deployment model (MVP): this image IS the rented pod (RunPod / Vast / Lambda). It runs sshd,
# so mdengine-mcp's P0.5 transport (ssh + rsync, hosts.json) drives it with no new code:
#   hosts.json entry: { "ssh": "root@<pod-ip>", "ssh_options": ["-p", "<port>"], "workdir": "/work",
#                       "lmp": "/usr/local/bin/lmp", "threads": 1,
#                       "launch": "{lmp} -in {input} -k on g 1 -sf kk -pk kokkos newton on neigh half -log {log}" }
# One pod per job, destroyed after fetch: the pod is the sandbox (it holds nothing of ours but
# this image). Per-job `docker run --network none` hardening (see ../runner) applies only where
# we control the docker host (Lambda/Vast VM) — not inside a RunPod pod.
#
# Build (x86_64 host with nvcc; NO GPU needed to compile — CI or any rented box):
#   docker build --build-arg KOKKOS_ARCH=ADA89 -t mdengine-runner-gpu:ada89 docker/runner-gpu
# KOKKOS_ARCH must match the rented GPU (one arch per build):
#   ADA89 = RTX 4090 / L4 / L40   AMPERE80 = A100   AMPERE86 = RTX 3090 / A10   HOPPER90 = H100
# Estimate: ~45-60 min on 4 cores (log it in tools/build_estimates.jsonl, feature-class lammps-kokkos-cuda).

# ---------- build stage ----------
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS build
ARG LAMMPS_TAG=stable_29Aug2024
ARG KOKKOS_ARCH=ADA89
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates git cmake g++ make python3 \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${LAMMPS_TAG} https://github.com/lammps/lammps.git /src
RUN cmake -S /src/cmake -B /build \
      -D CMAKE_BUILD_TYPE=Release \
      -D CMAKE_CXX_COMPILER=/src/lib/kokkos/bin/nvcc_wrapper \
      -D PKG_KOKKOS=yes -D Kokkos_ENABLE_CUDA=yes -D Kokkos_ENABLE_OPENMP=yes \
      -D Kokkos_ARCH_${KOKKOS_ARCH}=yes \
      -D BUILD_OMP=yes -D PKG_OPENMP=yes \
      -D PKG_MANYBODY=yes -D PKG_MOLECULE=yes -D PKG_KSPACE=yes \
      -D PKG_REAXFF=yes -D PKG_QEQ=yes -D PKG_RIGID=yes \
      -D PKG_EXTRA-DUMP=yes -D PKG_MISC=yes -D PKG_EXTRA-FIX=yes \
 && cmake --build /build -j "$(nproc)" \
 && cmake --install /build --prefix /opt/lammps

# ---------- runtime stage ----------
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgomp1 openssh-server rsync ca-certificates curl python3 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /work /root/.ssh && chmod 700 /root/.ssh
COPY --from=build /opt/lammps/bin/lmp /usr/local/bin/lmp
COPY --from=build /src/potentials /usr/local/share/lammps/potentials
COPY start.sh runner.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/runner.sh
ENV LAMMPS_POTENTIALS=/usr/local/share/lammps/potentials \
    OMP_NUM_THREADS=1
WORKDIR /work
EXPOSE 22
# Two modes: (a) MDE_JOB_ID set -> pull-runner (production, hosted/CONTRACT.md); (b) otherwise dev mode:
# PUBLIC_KEY env (RunPod convention) -> authorized_keys; then sshd in the foreground.
# Running `lmp` directly (no sshd) also works: docker run --gpus all ... mdengine-runner-gpu lmp -in deck.in -k on g 1 -sf kk
CMD ["/usr/local/bin/start.sh"]
