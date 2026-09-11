# MDEngine GPU tier from any OS, with curl

You do not need the Mac app, the CLI, or an AI agent to run a deck on our GPUs. The tier is a plain
HTTPS API: five calls, one API key. This page is the whole contract a customer needs; the full
server-side contract is `hosted/CONTRACT.md` in the source tree.

Base URL: `https://api.forcefieldsilicon.com/v1`. Auth: `Authorization: Bearer mde_…` on every call.
The key is shown once after checkout at <https://forcefieldsilicon.com/mdengine>. Windows users:
Git Bash, WSL, or PowerShell's `curl.exe` all work; the script below needs bash, curl, tar, python3.

## No terminal at all

<https://api.forcefieldsilicon.com/run> is the same flow in a browser page served by the endpoint: paste
the key, drop the deck folder, watch state and cost, download the results. Chrome, Edge, Firefox 113+ or
Safari 16.4+ (the tarball is built in the page). Nothing is installed and the key stays in that tab.

## The one-command version

```sh
export MDENGINE_API_KEY=mde_...
curl -fsSLO https://raw.githubusercontent.com/forcefieldsilicon/mdengine/main/scripts/hosted-curl.sh
bash hosted-curl.sh path/to/in.lmp          # uploads the deck's directory, runs, polls, downloads results
```

`MDE_GPU=rtx4090`, `MDE_WALL_HOURS=2`, `MDE_LABEL="Al slab"`, `MDE_RUNNER=openmm` are the knobs.
Exit code is the job's exit code. Results land in `./<job id>/`.

## The five calls

```sh
API=https://api.forcefieldsilicon.com/v1
H="Authorization: Bearer $MDENGINE_API_KEY"

# 0. Balance and the rate table. The most a job can cost is wall_limit_s/3600 × rate.
curl -s -H "$H" $API/me
# {"balance_usd": 25.0, "rate_table": {"any": 2.0, "rtx4090": 2.0}, ...}

# 1. Create a job. `input` is the deck file's path INSIDE the tarball you upload next.
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $API/jobs -d '{
  "input": "in.lmp", "label": "LJ melt", "gpu": "any",
  "wall_limit_s": 14400, "estimate_s": 3600, "launch": "default"
}'
# {"id": "MDJOB-20260909-K3F9QZ", "upload_url": "https://api.../blob/MDJOB-...in.tar.gz?exp=...&sig=...", ...}

# 2. Upload the deck directory as a .tar.gz (self-contained: data files, potentials, includes).
tar -C deck/ -czf deck.tar.gz .
curl -s -X PUT --data-binary @deck.tar.gz "$UPLOAD_URL"

# 3. Start. Billing begins at the pod's first heartbeat; image pull and boot are free.
curl -s -H "$H" -X POST $API/jobs/$JOB/start
# {"id": ..., "state": "queued", "runner": "lammps", "preflight": {"summary": [...], ...}}

# 4. Poll until state is done | failed | cancelled. thermo_tail = last 20 log lines, cost_usd = billed so far.
curl -s -H "$H" $API/jobs/$JOB
# {"state": "running", "billed_s": 812, "cost_usd": 0.45, "thermo_tail": ["Step Temp ...", ...], ...}

# 5. Results: a short-lived download URL for work/ + log.lammps + exitcode (kept 30 days).
curl -s -H "$H" $API/jobs/$JOB/results
# {"download_url": "https://api.../blob/MDJOB-...out.tar.gz?exp=...&sig=...", "bytes": 1048576}
curl -s "$DOWNLOAD_URL" | tar -xzf - -C results/
```

Cancel: `curl -s -H "$H" -X DELETE $API/jobs/$JOB` (billed to the cancel time). List: `GET $API/jobs`.

## Fields worth knowing

| Field | Meaning |
|---|---|
| `gpu` | `any` (cheapest available) or a named class from `rate_table`. |
| `wall_limit_s` | Hard cap, ≤ 86400. The job is stopped and billed to the cap. This is your spend ceiling. |
| `estimate_s` | Your guess; used only to check the balance before creating the job (≥ 15 min at rate). |
| `launch` | `default` lets the server pick the LAMMPS launch line (KOKKOS on the GPU, or plain `lmp` for decks that cannot run under `-sf kk`). Any other string is used verbatim. |
| `runner` | Omit for LAMMPS. `openmm` runs `python3 <input>` on the OpenMM image for biomolecular protocols. |
| `state` | `created → uploaded → queued → launching → running → uploading → done`, or `failed` / `cancelled`. |
| `error` | `wall_limit`, `no_capacity`, `launch_timeout`, `pod_lost`, `gpu_unavailable`, `lammps_error`, `cancelled`. Failures on our side (`no_capacity`, `launch_timeout`, `pod_lost`, `gpu_unavailable`) are never billed. |

Preflight before spend: `GET $API/capabilities` (no key needed) lists every LAMMPS style each runner
image supports and whether it is GPU-accelerated. `start` echoes the same check for your deck as
`preflight`; the server never blocks on it, so read `summary` before you wait on a CPU-only deck.

## Limits

Tarball ≤ 2 GB, relative paths only, no symlinks. Results are kept 30 days, then deleted (or sooner
on request). Credits never expire. Billing is per second at the rate in `rate_table`, no minimum.
