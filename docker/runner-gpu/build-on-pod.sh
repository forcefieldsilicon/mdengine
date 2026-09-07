#!/bin/bash
# Build LAMMPS+KOKKOS/CUDA directly on a RunPod pod (same recipe as the Dockerfile; used when
# we build on the rented box instead of in CI). Run as root on a runpod/pytorch *-devel image.
#   KOKKOS_ARCH=ADA89 bash build-on-pod.sh   -> /opt/lammps, tarball /workspace/lammps-kokkos-<arch>.tar.gz
set -euo pipefail
LAMMPS_TAG=${LAMMPS_TAG:-stable_29Aug2024}
KOKKOS_ARCH=${KOKKOS_ARCH:-ADA89}
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/cuda/bin:$PATH   # ssh shells on runpod images lack the CUDA PATH
JOBS=${JOBS:-16}                       # nproc reports the HOST cores (64); the pod gets ~12
apt-get update -qq && apt-get install -y -qq --no-install-recommends git cmake g++ make python3 rsync > /dev/null
[ -d /src ] || git clone --depth 1 --branch "$LAMMPS_TAG" https://github.com/lammps/lammps.git /src
cmake -S /src/cmake -B /build \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_CXX_COMPILER=/src/lib/kokkos/bin/nvcc_wrapper \
  -D PKG_KOKKOS=yes -D Kokkos_ENABLE_CUDA=yes -D Kokkos_ENABLE_OPENMP=yes \
  -D Kokkos_ARCH_${KOKKOS_ARCH}=yes \
  -D BUILD_OMP=yes -D PKG_OPENMP=yes \
  -D PKG_MANYBODY=yes -D PKG_MOLECULE=yes -D PKG_KSPACE=yes \
  -D PKG_REAXFF=yes -D PKG_QEQ=yes -D PKG_RIGID=yes \
  -D PKG_EXTRA-DUMP=yes -D PKG_MISC=yes -D PKG_EXTRA-FIX=yes
cmake --build /build -j "$JOBS"
cmake --install /build --prefix /opt/lammps
mkdir -p /opt/lammps/share/lammps && cp -r /src/potentials /opt/lammps/share/lammps/
/opt/lammps/bin/lmp -h | grep -E "KOKKOS|REAXFF|MANYBODY|OPENMP" | head
tar -C /opt -czf /workspace/lammps-kokkos-${KOKKOS_ARCH}.tar.gz lammps
ls -la /workspace/lammps-kokkos-${KOKKOS_ARCH}.tar.gz
echo BUILD-OK
