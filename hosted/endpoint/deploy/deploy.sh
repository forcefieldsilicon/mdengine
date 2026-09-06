#!/usr/bin/env bash
# Deploy the endpoint from a workstation:  deploy/deploy.sh root@HOST [PUBLIC_HOSTNAME]
# rsyncs mde_endpoint.py + mde_admin.py + deploy/ to the host, runs bootstrap.sh (idempotent),
# restarts the service, and checks https://PUBLIC_HOSTNAME/v1/health. Copies no secrets.
set -euo pipefail
TARGET=${1:?usage: deploy.sh root@HOST [PUBLIC_HOSTNAME]}
PUBLIC=${2:-api.forcefieldsilicon.com}
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$(dirname "$HERE")
STAGE=/root/mde-deploy

python3 -m py_compile "$SRC/mde_endpoint.py" "$SRC/mde_admin.py" "$SRC/mde_launcher.py"
( cd "$SRC" && python3 test_endpoint.py -q ) || { echo "tests failed; not deploying" >&2; exit 1; }

rsync -az --delete --exclude '__pycache__' --exclude '*.pyc' \
  "$SRC/mde_endpoint.py" "$SRC/mde_admin.py" "$SRC/mde_launcher.py" "$SRC/deploy" "$TARGET:$STAGE/"
ssh "$TARGET" "bash $STAGE/deploy/bootstrap.sh && systemctl restart mde-endpoint && sleep 1 && journalctl -u mde-endpoint -n 3 --no-pager"

echo "== public health"
curl -fsS --max-time 15 "https://$PUBLIC/v1/health" && echo || {
  echo "public health check failed: DNS for $PUBLIC not pointing here yet, or Caddy still fetching its certificate (journalctl -u caddy)" >&2; exit 2; }
