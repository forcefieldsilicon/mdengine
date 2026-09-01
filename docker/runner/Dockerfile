# MDEngine runner — locked-down LAMMPS + OpenMP image for the hosted tier.
# Build:  docker build -t mdengine-runner docker/runner
# Run one job (the hardening flags ARE the sandbox — always use them all):
#   docker run --rm --network none --cpus 4 --memory 8g --pids-limit 256 \
#     --read-only --tmpfs /tmp --security-opt no-new-privileges \
#     -v "$PWD:/work" -w /work mdengine-runner \
#     -in deck.in -sf omp -pk omp 4
#
# --network none   a deck's `shell` command cannot reach the network
# --read-only      nothing outside /work and /tmp is writable
# --cpus/--memory/--pids-limit   resource caps; add `timeout` upstream
# non-root user    baked in below

# ---------- build stage ----------
FROM ubuntu:24.04 AS build
ARG LAMMPS_TAG=stable_29Aug2024
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates git cmake g++ make libomp-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${LAMMPS_TAG} https://github.com/lammps/lammps.git /src
RUN cmake -S /src/cmake -B /build \
      -D CMAKE_BUILD_TYPE=Release \
      -D BUILD_OMP=yes \
      -D PKG_OPENMP=yes -D PKG_OPT=yes \
      -D PKG_MANYBODY=yes -D PKG_MOLECULE=yes -D PKG_KSPACE=yes \
      -D PKG_REAXFF=yes -D PKG_QEQ=yes -D PKG_RIGID=yes \
      -D PKG_EXTRA-DUMP=yes -D PKG_MISC=yes \
 && cmake --build /build -j "$(nproc)" \
 && cmake --install /build --prefix /opt/lammps

# ---------- runtime stage ----------
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libomp5-18 libgomp1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --shell /usr/sbin/nologin runner
COPY --from=build /opt/lammps/bin/lmp /usr/local/bin/lmp
COPY --from=build /src/potentials /usr/local/share/lammps/potentials
ENV LAMMPS_POTENTIALS=/usr/local/share/lammps/potentials \
    OMP_NUM_THREADS=4
USER runner
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/lmp"]
