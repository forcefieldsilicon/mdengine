#!/usr/bin/env bash
# livetest_ttl.sh — GJOB-099 acceptance test 3: the pod-side TTL in start.sh really stops the container.
#
#   DOCKER_DEFAULT_PLATFORM=linux/amd64 ./livetest_ttl.sh [--wall 60]   # on an arm64 Mac: the image is amd64-only [--image IMG] [--grace 120] [--dry-run]
#   ./livetest_ttl.sh verdict <exit_code> <elapsed_s> [wall_s] [grace_s]   # pure verdict logic, no docker
#
# CONTRACT "Pod lifecycle" #3: start.sh runs the runner under `timeout --signal=TERM --kill-after=60
# $((MDE_WALL_LIMIT_S + 600))`, so a pod whose runner hangs with the endpoint unreachable still ends by
# itself — GPU billing is bounded with no outside help. This test runs the real runner image with
# MDE_WALL_LIMIT_S=60 and /usr/local/bin/runner.sh replaced by a script that hangs forever, and asserts
# the container exits on the TTL (exit 124, or 137 if it had to be killed) at about wall+600 s.
#
# No endpoint, no job, no RunPod: the hanging runner never talks to anything. Cost is one local container
# for wall+600 s (~11 min at the default wall=60) on whatever host runs it — no GPU is required, the
# container only sleeps. Run it on a docker host; --dry-run prints the docker command and stops.
set -uo pipefail

WALL=60
GRACE=120                       # slack on top of wall+600: timeout's --kill-after is 60 s, plus teardown
IMAGE=${MDE_RUNNER_IMAGE:-ghcr.io/forcefieldsilicon/mdengine-runner-gpu:ADA89}
DRY=0

# ------------------------------------------------------------------ pure verdict (unit-tested via this subcommand)
verdict() {                     # exit_code elapsed_s [wall] [grace] -> JSON on stdout, 0 = PASS
  local code=$1 elapsed=$2 wall=${3:-$WALL} grace=${4:-$GRACE}
  local ttl=$(( wall + 600 )) hi ok_code=0 ok_time=0 v
  hi=$(( ttl + grace ))
  case "$code" in 124|137) ok_code=1 ;; esac                 # 124 = timeout fired, 137 = SIGKILL after --kill-after
  if [ "$elapsed" -ge "$wall" ] && [ "$elapsed" -le "$hi" ]; then ok_time=1; fi
  if [ "$ok_code" = 1 ] && [ "$ok_time" = 1 ]; then v=PASS; else v=FAIL; fi
  printf '{"verdict":"%s","exit_code":%s,"elapsed_s":%s,"ttl_s":%s,"window_s":[%s,%s],"ttl_exit_code":%s,"in_window":%s,"criterion":"exit 124/137 at wall+600 s (CONTRACT Pod lifecycle #3)"}\n' \
    "$v" "$code" "$elapsed" "$ttl" "$wall" "$hi" "$ok_code" "$ok_time"
  [ "$v" = PASS ]
}

if [ "${1:-}" = "verdict" ]; then shift; verdict "$@"; exit $?; fi

while [ $# -gt 0 ]; do
  case "$1" in
    --wall) WALL=$2; shift 2 ;;
    --image) IMAGE=$2; shift 2 ;;
    --grace) GRACE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mde-ttl-XXXXXX")
HANG="$WORK/runner.sh"
cat > "$HANG" <<'EOF'
#!/bin/sh
# a runner that hangs: the only thing that may end this container is start.sh's timeout
echo "hanging runner: pid $$, MDE_WALL_LIMIT_S=${MDE_WALL_LIMIT_S:-unset}"
while :; do sleep 3600; done
EOF
chmod 0755 "$HANG"
NAME="mde-ttl-livetest-$$"
JOB="MDJOB-TTLTEST-$(date -u +%H%M%S)"
CMD=(docker run --rm --name "$NAME"
     -e "MDE_JOB_ID=$JOB" -e MDE_JOB_TOKEN=not-a-real-token -e MDE_ENDPOINT=http://127.0.0.1:1
     -e "MDE_WALL_LIMIT_S=$WALL"
     -v "$HANG:/usr/local/bin/runner.sh:ro"
     "$IMAGE")

if [ "$DRY" = 1 ]; then
  printf '%q ' "${CMD[@]}"; printf '\n'
  printf '{"dry_run":true,"wall_s":%s,"ttl_s":%s,"image":"%s","hang_script":"%s"}\n' "$WALL" "$(( WALL + 600 ))" "$IMAGE" "$HANG"
  exit 0
fi

command -v docker >/dev/null || { echo "docker not found" >&2; rm -rf "$WORK"; exit 2; }
printf '{"start":"%s","job":"%s","wall_s":%s,"expect_exit_at_s":%s}\n' "$(date -u +%FT%TZ)" "$JOB" "$WALL" "$(( WALL + 600 ))"
T0=$(date +%s)
"${CMD[@]}"; CODE=$?
ELAPSED=$(( $(date +%s) - T0 ))
docker rm -f "$NAME" >/dev/null 2>&1 || true          # --rm should have, but never leave the thing under test running
rm -rf "$WORK"
verdict "$CODE" "$ELAPSED" "$WALL" "$GRACE"
exit $?
