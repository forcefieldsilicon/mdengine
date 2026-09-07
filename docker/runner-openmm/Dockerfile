# MDEngine GPU runner — OpenMM flavour. Same pull-runner contract as docker/runner-gpu (hosted/CONTRACT.md):
# the pod fetches one job by token, runs the job spec's `launch` line, uploads results, exits.
# The only difference is what is on PATH: here a python with OpenMM instead of `lmp`.
#   job spec: {"input": "run.py", "launch": "python3 {input}"}
# Build (no GPU needed):  docker build -t mdengine-runner-openmm docker/runner-openmm
# OpenMM's CUDA platform JITs its kernels through nvrtc at runtime, so one image runs on any NVIDIA
# host whose driver supports the bundled CUDA runtime — no per-architecture build (unlike KOKKOS).
FROM mambaorg/micromamba:1.5-jammy
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl tar gzip coreutils procps \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /work
# openmm + the module-1 toolchain: forcefields (CHARMM36m/Amber via openmmforcefields), structure
# repair (pdbfixer), trajectory analysis (mdtraj, mdanalysis). cuda-version MUST be pinned to the floor the
# launcher promises (MDE_MIN_CUDA=12.4): a newer nvrtc emits PTX the host driver cannot JIT
# (CUDA_ERROR_UNSUPPORTED_PTX_VERSION, seen live 2026-09-07 with cuda-version=12.* on a 570 driver).
RUN micromamba install -y -n base -c conda-forge \
      python=3.11 openmm=8.* "cuda-version=12.4.*" openmmforcefields pdbfixer mdtraj mdanalysis numpy scipy \
 && micromamba clean -ay
ENV PATH=/opt/conda/bin:$PATH \
    OPENMM_CPU_THREADS=1 \
    PYTHONUNBUFFERED=1
COPY start.sh runner.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/runner.sh \
 && python3 -c "import openmm, openmm.app, openmmforcefields, pdbfixer, mdtraj; print('openmm', openmm.__version__)"
WORKDIR /work
CMD ["/usr/local/bin/start.sh"]
