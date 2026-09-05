# MDEngine hosted job contract v1 (GJOB-094; consumed by GJOB-093 runner and GJOB-091 clients)

_Pinned 2026-09-05. Everything below is what the runner image, the endpoint, and the CLI/MCP/app
client agree on. Change it here first; code follows._

## Principles
- Same job model as the local runner (`~/.mdengine/jobs/<id>/`: `input`, `work/`, `log`, `exitcode`)
  and the P0.5 remote transport — the hosted tier is a **transport**, not a new product.
- Pods **pull**. The endpoint never connects to a pod. A pod holds one job, one one-shot token,
  nothing else of ours. A LAMMPS deck is untrusted code: the endpoint never executes anything.
- Files are exchanged via **presigned object-storage URLs**; the endpoint's VPS stores metadata only.

## Identifiers
- Job id: `MDJOB-<utc yyyymmdd>-<6 base32>` (same shape as local jobs; sortable).
- API key: `mde_` + 32 hex. Sent as `Authorization: Bearer mde_…`. Stored hashed (sha256) at rest.
- Job token (pod-side): `jt_` + 32 hex, single job, expires when the job reaches a terminal state.

## Client-facing API (base `https://api.forcefieldsilicon.com/v1`)
| Method | Path | Body / notes | Returns |
|---|---|---|---|
| GET  | `/me` | — | `{balance_usd, rate_table, keys_created}` |
| POST | `/jobs` | JSON `JobSpec` (below) | `201 {id, upload_url, upload_expires}` — client PUTs the deck tarball to `upload_url` then calls start |
| POST | `/jobs/{id}/start` | — | `202 {id, state:"queued"}` |
| GET  | `/jobs/{id}` | — | `JobStatus` (below) |
| GET  | `/jobs/{id}/results` | — | `{download_url, expires, bytes}` (tarball of `work/` + `log` + `exitcode`) |
| DELETE | `/jobs/{id}` | — | `202` → state `cancelled`; billed to cancel time |
| GET  | `/jobs?limit=&cursor=` | — | list, newest first |

### JobSpec (client → endpoint)
```json
{
  "input": "in.lmp",                    // relative path inside the tarball; deck must be self-contained
  "label": "Al slab oxidation",         // optional, free text ≤120 chars
  "gpu": "any",                         // "any" | "rtx4090" | "a100" — rate differs; "any" = cheapest available
  "wall_limit_s": 14400,                // hard cap, ≤ 86400; job fails at cap, billed to cap
  "estimate_s": 3600,                   // client's guess; used only for the balance pre-check (≥15 min at rate)
  "launch": "default"                   // "default" = "{lmp} -in {input} -k on g 1 -sf kk -pk kokkos newton on neigh half -log log.lammps"
}
```
Tarball limits: ≤ 2 GB (matches the MCP 2 GB guard); paths must be relative, no `..`, no symlinks.

### JobStatus (endpoint → client)
```json
{
  "id": "MDJOB-20260905-K3F9QZ", "state": "running",
  "states": "created|uploaded|queued|launching|running|uploading|done|failed|cancelled",
  "created": "…Z", "started": "…Z", "finished": null,
  "gpu": "rtx4090", "rate_usd_per_h": 2.0, "billed_s": 812, "cost_usd": 0.45,
  "thermo_tail": ["Step Temp PotEng …", "  1200  300.1  -20413.7 …"],   // last ≤ 20 lines, from heartbeat
  "exitcode": null, "error": null,                                        // error: "wall_limit" | "pod_lost" | "lammps_error" | "cancelled"
  "attempt": 1                                                            // 2 after one automatic relaunch on pod loss
}
```

## Pod-facing API (runner → endpoint; auth = job token as `Authorization: Bearer jt_…`)
| Method | Path | Notes |
|---|---|---|
| GET  | `/internal/jobs/{id}` | `{input_url (presigned GET), launch, wall_limit_s, results_put_url (presigned PUT)}` |
| POST | `/internal/jobs/{id}/heartbeat` | every 30 s: `{thermo_tail:[…], elapsed_s}`; 3 missed → `pod_lost` |
| POST | `/internal/jobs/{id}/done` | `{exitcode, elapsed_s, results_bytes}` → endpoint verifies the object exists, sets done/failed, **invalidates token**, terminates pod |

Runner sequence: boot → GET job → download + untar to `/work` → `timeout wall_limit lmp …` (heartbeat
thread) → tar `work/ log.lammps exitcode` → PUT results → POST done → exit 0. Any failure → POST done
with nonzero exitcode and `error`. Pod never needs inbound network, ssh, or a public IP.

## Billing (GJOB-095)
`billed_s` runs from `running` to terminal state. Launch/pull overhead not billed. Rate by `gpu`
from the endpoint's rate table (re-derived after the A100 test, GJOB-092). Refund on `pod_lost` past
the retry, or any endpoint-side failure. Submit refused if `balance < rate × max(estimate_s, 900)`.

## State machine
created → uploaded (client PUT ok) → queued (start) → launching (pod requested; DC fallback list) →
running (first heartbeat) → uploading (done received) → done | failed | cancelled.
Timeouts: launching > 10 min → next DC/GPU in fallback → after list exhausted `failed:no_capacity`
(not billed). running with 3 missed heartbeats → relaunch once (attempt 2) → then `failed:pod_lost`.

## Local mock
`hosted/mock/` (to build): same routes, sqlite, files on local disk with `file://`-style URLs, so
runner (docker) and clients develop offline before the VPS exists.
