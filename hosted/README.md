# MDEngine hosted tier (GJOB-088)

- `CONTRACT.md` — job contract v1: the one spec the runner, endpoint, and CLI/MCP/app clients share.
- `mock/mock_endpoint.py` — stdlib local mock of the endpoint (sqlite + local blob store). Dev only.
- Runner (pod side): `../docker/runner-gpu/runner.sh`, baked into the runner-gpu image; runs when
  `MDE_JOB_ID` is set, otherwise the image is an sshd dev box.

## Offline end-to-end (verified 2026-09-05 on rakhsh, CPU lmp standing in for the pod)
```
python3 hosted/mock/mock_endpoint.py --port 8787 --data /tmp/mde-mock &      # key mde_test, $20
# client: POST /v1/jobs -> PUT deck tarball to upload_url -> POST /v1/jobs/{id}/start
# pod:    set -a; . /tmp/mde-mock/launch.env; MDE_WORK=/tmp/pod/work LMP=/opt/homebrew/bin/lmp_serial docker/runner-gpu/runner.sh
# client: GET /v1/jobs/{id} -> done; GET /v1/jobs/{id}/results -> download_url
```
Production endpoint (VPS + object storage + RunPod launcher) = GJOB-094; not in this repo yet.
