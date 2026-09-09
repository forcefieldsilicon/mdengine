#!/bin/bash
# MDEngine pull-runner (GJOB-093). Implements the pod side of hosted/CONTRACT.md v1.
# Env (set by the launcher on pod creation): MDE_ENDPOINT, MDE_JOB_ID, MDE_JOB_TOKEN.
# Sequence: GET job → download+untar input → run lmp under `timeout` with a heartbeat → tar results
# → PUT to presigned URL → POST done → exit. Never needs inbound network, ssh, or a public IP.
set -uo pipefail
: "${MDE_ENDPOINT:?}" "${MDE_JOB_ID:?}" "${MDE_JOB_TOKEN:?}"
LMP=${LMP:-/usr/local/bin/lmp}
export PATH=/usr/local/cuda/bin:$PATH
API="$MDE_ENDPOINT/internal/jobs/$MDE_JOB_ID"
AUTH="Authorization: Bearer $MDE_JOB_TOKEN"
WORK=${MDE_WORK:-/work}; mkdir -p "$WORK"; cd "$WORK"          # MDE_WORK: dev override (mac test)
RES=${MDE_WORK:+$WORK/../results.tar.gz}; RES=${RES:-/results.tar.gz}; IN=${MDE_WORK:+$WORK/../input.tar.gz}; IN=${IN:-/input.tar.gz}
if command -v timeout >/dev/null; then TMO=timeout; elif command -v gtimeout >/dev/null; then TMO=gtimeout; else TMO=""; echo "WARN: no timeout(1); wall limit unenforced (dev only)" >&2; fi
T0=$(date +%s)
elapsed() { echo $(( $(date +%s) - T0 )); }
finish() { # exitcode error
  local rc=$1 err=${2:-null}
  [ "$err" != null ] && err="\"$err\""
  local bytes=0; [ -f "$RES" ] && bytes=$(wc -c < "$RES" | tr -d " ")
  curl -sS -m 30 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"exitcode\":$rc,\"elapsed_s\":$(elapsed),\"results_bytes\":$bytes,\"error\":$err}" "$API/done" >/dev/null || true
  exit "$rc"
}
# 1. job spec
SPEC=$(curl -sS -m 30 -H "$AUTH" "$API") || finish 70 fetch_spec
jq_() { printf '%s' "$SPEC" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d$1; print(v if v is not None else '')"; }
INPUT_URL=$(jq_ "['input_url']"); PUT_URL=$(jq_ "['results_put_url']")
INPUT=$(jq_ "['input']"); WALL=$(jq_ "['wall_limit_s']"); LAUNCH=$(jq_ "['launch']")
[ -n "$INPUT_URL" ] && [ -n "$PUT_URL" ] && [ -n "$INPUT" ] || finish 70 bad_spec
# 2. input
curl -sS -m 600 -o "$IN" "$INPUT_URL" || finish 71 fetch_input
tar -tzf "$IN" | grep -Eq '(^|/)\.\.(/|$)|^/' && finish 72 unsafe_tarball
tar -xzf "$IN" -C "$WORK" || finish 72 untar
[ -f "$WORK/$INPUT" ] || finish 72 input_missing
# 2b. host diagnostics into the results (driver/GPU/CUDA visibility) — makes a bad host explainable
{ echo "== $(date -u +%FT%TZ) pod host diag"; nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1 | head -3
  echo "cuda devices: $(ls /dev/nvidia* 2>/dev/null | tr '\n' ' ')"; echo "libcuda: $(ls /usr/lib/x86_64-linux-gnu/libcuda.so.* 2>/dev/null | head -1)"
  echo "env: $(env | grep -E '^(NVIDIA|CUDA)' | tr '\n' ' ')"; } > "$WORK/hostdiag.txt" 2>&1
# 2c. GPU gate (GJOB-130): some hosts hand the container no CUDA device (NVIDIA_VISIBLE_DEVICES=void, driver libs
# not injected). LAMMPS/Kokkos would die at init and OpenMM would silently run on the CPU — both at the GPU rate. Probe
# the driver for real (cuInit + device count) and fail fast as gpu_unavailable: the endpoint does not bill it and
# relaunches once. hostdiag.txt is shipped so the failure stays explainable. MDE_GPU_GATE=off = dev override only.
gpu_probe() { python3 - <<'PY' 2>&1
import ctypes, sys
try: l = ctypes.CDLL("libcuda.so.1")
except OSError as e: print("libcuda: %s" % e); sys.exit(1)
rc = l.cuInit(0)
if rc: print("cuInit rc=%d" % rc); sys.exit(1)
n = ctypes.c_int(0); rc = l.cuDeviceGetCount(ctypes.byref(n))
if rc or n.value < 1: print("cuDeviceGetCount rc=%d n=%d" % (rc, n.value)); sys.exit(1)
print("ok, %d device(s)" % n.value)
PY
}
PROBE=$(gpu_probe); PRC=$?; echo "gpu probe: $PROBE (NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-unset})" >> "$WORK/hostdiag.txt"
if [ $PRC -ne 0 ] && [ "${MDE_GPU_GATE:-on}" != off ]; then
  tar -czf "$RES" -C "$WORK" . 2>/dev/null && curl -sS -m 120 -X PUT -H 'Content-Type: application/gzip' --upload-file "$RES" "$PUT_URL" >/dev/null || true
  finish 75 gpu_unavailable
fi
# 3. run with heartbeat (last 20 thermo-ish lines of the log)
[ -z "$LAUNCH" ] || [ "$LAUNCH" = default ] && LAUNCH='{lmp} -in {input} -k on g 1 -sf kk -pk kokkos newton on neigh half -log log.lammps'
CMD=${LAUNCH//\{lmp\}/$LMP}; CMD=${CMD//\{input\}/$INPUT}
hb() { local tail; tail=$(tail -n 20 "$WORK/log.lammps" 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().splitlines()))')
  curl -sS -m 10 -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"thermo_tail\":${tail:-[]},\"elapsed_s\":$(elapsed)}" "$API/heartbeat" >/dev/null || true; }
hb   # immediate: state -> running before the first 30 s tick
( while sleep 30; do hb; done ) & HB=$!

${TMO:+$TMO --signal=TERM --kill-after=30 "${WALL:-86400}"} bash -c "$CMD" > "$WORK/stdout.txt" 2>&1; RC=$?
kill $HB 2>/dev/null; wait $HB 2>/dev/null
echo "$RC" > "$WORK/exitcode"
ERR=null; [ $RC -eq 124 ] && ERR=wall_limit; { [ $RC -ne 0 ] && [ $RC -ne 124 ]; } && ERR=lammps_error
# 4. results (never ship the input tarball back; cap handled by the endpoint's presigned size limit)
tar -czf "$RES" -C "$WORK" . || finish 73 pack
curl -sS -m 1800 -X PUT -H 'Content-Type: application/gzip' --upload-file "$RES" "$PUT_URL" >/dev/null || finish 74 upload
finish "$RC" "$ERR"
