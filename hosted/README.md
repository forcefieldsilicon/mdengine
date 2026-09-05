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
## Clients (GJOB-091) — one `HostedClient` in LAMMPSCore, three surfaces
- CLI: `mdengine login mde_… [--endpoint URL]`, `mdengine run --gpu deck.in [--gpu-type any|rtx4090|a100] [--wall-hours H] [--no-wait]`,
  `mdengine account`, `mdengine jobs`, `mdengine job <id> [--fetch|--cancel|--wait]`.
- MCP: `submit_lammps host=cloud` (+ `gpu`, `wall_hours`); `job_status` / `job_log` / `job_files` / `cancel_job` / `fetch_job` all branch on the
  local `job.json` carrying `"cloud": true`; `list_hosts` shows the balance.
- App: File ▸ Run Accelerated… (⇧⌘R) and File ▸ Accelerated Runs (⇧⌘J) window with live thermo; a finished job's trajectory opens in the
  viewer by itself; Settings ▸ Accelerated holds the key. `MDEngine --run-accelerated deck.in` submits from the command line.
- Credentials: `$MDENGINE_API_KEY`, else `~/.mdengine/credentials` (0600). Dev: `$MDENGINE_HOSTED_URL` points at the mock,
  `$MDENGINE_HOSTED_LAUNCH="{lmp} -in {input} -log log.lammps"` drops the KOKKOS flags for a CPU stand-in pod.
- Verified 2026-09-05 against the mock from all three surfaces (submit → pod → done → results fetched → balance debited).

Production endpoint (VPS + object storage + RunPod launcher) = GJOB-094; not in this repo yet.
