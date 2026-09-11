#!/usr/bin/env bash
# Run a deck on the MDEngine GPU tier with nothing but curl and tar. Works from Linux, macOS, WSL, Git Bash.
#
#   export MDENGINE_API_KEY=mde_...          # from your credit pack (shown once after checkout)
#   scripts/hosted-curl.sh path/to/in.lmp    # the deck's whole directory is uploaded; keep it self-contained
#
# Options (env): MDE_GPU=any|rtx4090  MDE_WALL_HOURS=4  MDE_LABEL="my run"  MDE_RUNNER=lammps|openmm
#                MDE_API=https://api.forcefieldsilicon.com/v1
# Exit code is the job's exit code (0 = done). Results land in ./<job id>/ next to where you ran this.
set -euo pipefail

API=${MDE_API:-https://api.forcefieldsilicon.com/v1}
KEY=${MDENGINE_API_KEY:?set MDENGINE_API_KEY=mde_... (your key from the credit pack)}
INPUT=${1:?usage: hosted-curl.sh <deck input file>}
GPU=${MDE_GPU:-any}; WALL_H=${MDE_WALL_HOURS:-4}; LABEL=${MDE_LABEL:-$(basename "$INPUT")}; RUNNER=${MDE_RUNNER:-}
need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 2; }; }
need curl; need tar; need python3
[ -f "$INPUT" ] || { echo "no such input: $INPUT" >&2; exit 2; }
DECK_DIR=$(cd "$(dirname "$INPUT")" && pwd); DECK_FILE=$(basename "$INPUT")
auth=(-H "Authorization: Bearer $KEY"); json=(-H "Content-Type: application/json")
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)"; }   # jq without jq

# 0. Account: balance and rate, and the most this job can cost (wall limit x rate).
ME=$(curl -fsS "${auth[@]}" "$API/me")
BAL=$(echo "$ME" | jq_ "['balance_usd']"); RATE=$(echo "$ME" | jq_ "['rate_table'].get('$GPU', d['rate_table']['any'])")
echo "balance \$$BAL · gpu $GPU at \$$RATE/h · cap $WALL_H h = \$$(python3 -c "print(round($WALL_H*$RATE,2))") max"

# 1. Create the job. The reply carries a one-hour upload URL for the deck tarball.
WALL_S=$(python3 -c "print(int($WALL_H*3600))")
SPEC=$(python3 -c "import json,sys; s={'input':sys.argv[1],'label':sys.argv[2],'gpu':sys.argv[3],'wall_limit_s':int(sys.argv[4]),'estimate_s':3600,'launch':'default'}
r=sys.argv[5]
if r: s['runner']=r
print(json.dumps(s))" "$DECK_FILE" "$LABEL" "$GPU" "$WALL_S" "$RUNNER")
CREATED=$(curl -fsS "${auth[@]}" "${json[@]}" -X POST "$API/jobs" -d "$SPEC")
JOB=$(echo "$CREATED" | jq_ "['id']"); UPLOAD_URL=$(echo "$CREATED" | jq_ "['upload_url']")
echo "created $JOB"

# 2. Upload the deck directory as a gzipped tarball (trajectories, checkpoints and logs left out).
TARBALL=$(mktemp "${TMPDIR:-/tmp}/mde-deck.XXXXXX")
tar -C "$DECK_DIR" -czf "$TARBALL" --exclude='*.lammpstrj' --exclude='*.dcd' --exclude='*.xtc' --exclude='*.traj' \
    --exclude='*.restart*' --exclude='*.ckpt*' --exclude='log.lammps' --exclude='results' .
curl -fsS -X PUT --data-binary @"$TARBALL" "$UPLOAD_URL" >/dev/null; rm -f "$TARBALL"
echo "uploaded"

# 3. Start. Billing runs from the first heartbeat; launch overhead is free. The reply carries a preflight advisory.
START=$(curl -fsS "${auth[@]}" -X POST "$API/jobs/$JOB/start")
echo "$START" | python3 -c "import sys,json; d=json.load(sys.stdin); pf=d.get('preflight') or {}
print('started ->', d.get('state'), '· runner', d.get('runner') or 'default')
for s in (pf.get('summary') or [])[:6]: print('  preflight:', s)"

# 4. Poll. thermo_tail is the last <=20 log lines the pod reported; cost_usd is what has been billed so far.
LAST=""
while :; do
  S=$(curl -fsS "${auth[@]}" "$API/jobs/$JOB")
  LINE=$(echo "$S" | python3 -c "import sys,json; d=json.load(sys.stdin); t=(d.get('thermo_tail') or [''])[-1]
print('%s · %ss · \$%.4f · %s' % (d['state'], d.get('billed_s') or 0, d.get('cost_usd') or 0, t.strip()[:80]))")
  [ "$LINE" != "$LAST" ] && echo "$LINE"; LAST=$LINE
  STATE=$(echo "$S" | jq_ "['state']")
  case "$STATE" in done|failed|cancelled) break;; esac
  sleep 15
done
EXIT=$(echo "$S" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('exitcode') if d.get('exitcode') is not None else (0 if d['state']=='done' else 1))")
ERR=$(echo "$S" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error') or '')")
[ -n "$ERR" ] && echo "error: $ERR (jobs that fail on our side are not billed)"

# 5. Results: a short-lived download URL for work/ + log.lammps + exitcode, kept 30 days.
R=$(curl -fsS "${auth[@]}" "$API/jobs/$JOB/results") || { echo "no results for $JOB"; exit "${EXIT:-1}"; }
URL=$(echo "$R" | jq_ "['download_url']")
mkdir -p "$JOB"; curl -fsS "$URL" | tar -xzf - -C "$JOB"
echo "results in ./$JOB/ ($(ls "$JOB" | tr '\n' ' '))"
exit "${EXIT:-0}"
