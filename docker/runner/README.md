# MDEngine runner image

Reproducible, locked-down LAMMPS (OpenMP) for running untrusted decks — the
execution backend for MDEngine's hosted tier, and a reproducibility artifact
for local use.

A LAMMPS deck is a program (it can invoke `shell`), so the container flags in
the Dockerfile header are not optional niceties — together they are the
sandbox: no network, read-only filesystem outside the mounted `/work`, CPU /
memory / process caps, non-root. Wrap invocations in `timeout` for a
wall-clock cap.

GPU (KOKKOS) variant lands as a separate stage when the hosted GPU tier
starts; this image is deliberately CPU-only.
