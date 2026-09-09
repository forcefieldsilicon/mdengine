#!/bin/bash
# Print `lmp -h` from the runner image on a machine WITHOUT a GPU (CI, laptop). The binary links
# libcuda.so.1 (the driver, injected only on GPU hosts), so we synthesise a stub exporting every cu*
# symbol lmp references; -h never calls into CUDA. Used by .github/workflows/runner-manifest.yml:
#   docker run --rm -v "$PWD/docker/runner-gpu:/tools:ro" --entrypoint /bin/bash IMAGE /tools/lmp-help-nogpu.sh
set -euo pipefail
LMP=${LMP:-/usr/local/bin/lmp}
if "$LMP" -h >/tmp/lmp-h.txt 2>/dev/null; then cat /tmp/lmp-h.txt; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends gcc libc6-dev binutils >/dev/null 2>&1
mkdir -p /tmp/stub
nm -D --undefined-only "$LMP" | awk '$1=="U" || $2=="U" {print $NF}' | sed 's/@.*//' | grep -E '^cu[A-Z]' | sort -u > /tmp/stub/syms.txt
{ echo 'void __mde_stub(void){}'; while read -r s; do echo "void $s(void){}"; done < /tmp/stub/syms.txt; } > /tmp/stub/stub.c
gcc -shared -fPIC -o /tmp/stub/libcuda.so.1 /tmp/stub/stub.c
echo "stubbed $(wc -l < /tmp/stub/syms.txt) libcuda symbols" >&2
LD_LIBRARY_PATH=/tmp/stub "$LMP" -h
