# MDEngine hosted endpoint — service + ops notes

Production implementation of `../CONTRACT.md` v1, evolved from `../mock/mock_endpoint.py` (same routes and
JSON shapes, so the CLI/MCP/app clients verified against the mock work unchanged). Python 3.12 stdlib only,
sqlite, one process behind Caddy.

```
mde_endpoint.py      the service           mde_admin.py        operator CLI (same sqlite)
mde_launcher.py      RunPod pod launcher   test_endpoint.py    unittest, fake Stripe, fake launcher
deploy/              Caddyfile, systemd unit, bootstrap, deploy, env example
```

## Run locally
```
cat > /tmp/mde.env <<EOF
MDE_DB=/tmp/mde/mde.sqlite
MDE_BLOBS=/tmp/mde/blobs
MDE_BIND=127.0.0.1:8080
MDE_PACKS=price_test:25:12.5
MDE_RUNNERS_OPEN=1
EOF
python3 hosted/endpoint/mde_endpoint.py --env-file /tmp/mde.env &
python3 hosted/endpoint/mde_admin.py --env-file /tmp/mde.env key new --email you@example.com --credit 20
MDENGINE_HOSTED_URL=http://127.0.0.1:8080/v1 mdengine account
python3 hosted/endpoint/test_endpoint.py -v
```

## Environment (`/etc/mde/endpoint.env`, see `deploy/endpoint.env.example`)
| Var | Meaning |
|---|---|
| `MDE_DB` | sqlite file (WAL). Tables: `keys`, `credits`, `jobs`, `pending_keys`, `meta`. |
| `MDE_BLOBS` | directory for deck/results tarballs served at `/blob/<name>` with signed URLs. |
| `MDE_BIND` | listener, default `127.0.0.1:8080` (Caddy fronts it). |
| `MDE_PUBLIC_URL` | scheme+host clients and pods can reach; embedded in upload/download URLs. |
| `STRIPE_SECRET_KEY` | used server-side to fetch Checkout Sessions (`/welcome` and the webhook). |
| `STRIPE_WEBHOOK_SECRET` | signing secret of the `checkout.session.completed` webhook endpoint. |
| `MDE_PACKS` | `price_id:usd:gpu_hours,...` — the price id decides the hours credited. |
| `MDE_RATES` | `gpu:usd_per_hour,...`; default `any:2,rtx4090:2`. Credited usd = hours x rate("any"). |
| `MDE_RUNNERS_OPEN` | `1` opens job submission; anything else returns 503 `gpu_runners_open_soon`. |
| `MDE_ADMIN_TOKEN` | optional bearer for `GET /v1/admin/stats`; unset disables the route. |
| `RUNPOD_API_KEY` | RunPod account API key (pods read/write). Unset = no launcher: `start` writes `launch.env` for a hand-run pod. |
| `MDE_RUNNER_IMAGE` | pod image; default `ghcr.io/forcefieldsilicon/mdengine-runner-gpu:ADA89` (`docker/runner-gpu`). |
| `MDE_GPU_LADDER` | fallback rungs `CLOUD:gpu id,...` tried in order at launch; default `COMMUNITY:NVIDIA GeForce RTX 4090,SECURE:NVIDIA GeForce RTX 4090`. |
| `MDE_POD_DISK_GB` | pod container disk, default `20`. |
| `MDE_MIN_CUDA` | `gpu.minCudaVersion` on the pod request, default `12.4` (the ADA89 image is built against CUDA 12.4). |
| `MDE_LAUNCH_TIMEOUT_S` | a job still `launching` with no heartbeat after this many seconds -> pod deleted, `failed:no_capacity` (unbilled). Default `600`. |
| `MDE_REAPER_INTERVAL_S` | how often the reaper lists the account's pods, default `300`. It also runs once at boot. |

Logs are one JSON object per line on stdout (`journalctl -u mde-endpoint -f`). Full API keys, job tokens and
Stripe secrets never appear in logs or in the database (keys are stored as sha256; `key_id` = first 8 hex).

## Routes
Client (Bearer `mde_...`): `GET /v1/me`, `POST /v1/jobs`, `POST /v1/jobs/{id}/start`, `GET /v1/jobs[?limit=&cursor=]`,
`GET /v1/jobs/{id}`, `GET /v1/jobs/{id}/results`, `DELETE /v1/jobs/{id}` — shapes per `../CONTRACT.md`.
Pod (Bearer `jt_...`, minted at `start`, invalidated at any terminal state): `GET /internal/jobs/{id}`,
`POST /internal/jobs/{id}/heartbeat`, `POST /internal/jobs/{id}/done`.
Blobs: `PUT|GET /blob/<job>.in.tar.gz|.out.tar.gz?exp=&sig=` (HMAC-signed, stands in for presigned object storage; 2 GB cap, streamed to disk).
Public: `GET /v1/health` -> `{"ok":true,"version":"...","runners":"open|closed","launcher":"runpod|none"}`;
`GET /welcome?session_id=`; `POST /v1/stripe/webhook`.

### Purchase flow
1. Stripe Payment Link redirects to `/welcome?session_id={CHECKOUT_SESSION_ID}`. The endpoint fetches the session
   (`expand[]=line_items`), requires `payment_status=paid`, maps the price id through `MDE_PACKS`, and:
   - `client_reference_id` equal to an existing `key_id` -> credits that key, page shows the new balance;
   - otherwise creates a key, credits it, shows the full key once with the `mdengine login mde_...` line and app steps.
2. The webhook runs the same handler. Both are idempotent on `session_id` (primary key of `credits`).
3. If the webhook lands before the buyer's browser does, the new key is parked in `pending_keys` and revealed on the
   first `/welcome` visit, then deleted. Unclaimed entries are purged after 7 days; `mde-admin pending` lists them and
   `mde-admin pending --reveal <session_id>` prints one for manual delivery (the only path where a plaintext key rests in
   the database, and only until it is shown).
4. Coupon-discounted payments grant the full pack hours. An unknown price id is honored at `amount_total` / rate and
   logged as `pack.unknown_price`.

Balance = sum(`credits.usd`) - sum(billed job cost). Jobs with `error` in `pod_lost`/`no_capacity` cost nothing;
cancelled jobs bill to cancel time; running jobs bill live.

### Pod launcher (`mde_launcher.py`, RunPod REST v2)
With `RUNPOD_API_KEY` set, `POST /v1/jobs/{id}/start` mints the job token, sets `queued`, and hands off to a background
thread so the HTTP response never waits on RunPod:
1. `RunPodLauncher.create` walks `MDE_GPU_LADDER`: one `POST /v2/pods` per rung with
   `{name:"mde-<job id>", image, cloud, gpu:{id,count:1,minCudaVersion}, disk, env:{MDE_ENDPOINT,MDE_JOB_ID,MDE_JOB_TOKEN}}`
   (no `dataCenterIds`: the scheduler picks). Each rung logs `launch.attempt` (status code, error body truncated to 300
   chars; never the request body, which carries the token). First 201 wins: job -> `launching`, `pod_id`, `launched_at`.
   Every rung refused -> `job.no_capacity`, job `failed:no_capacity`, token invalidated, nothing billed, no pod.
2. The pod boots `start.sh` -> `runner.sh`, whose first heartbeat flips the job to `running`.
3. Any terminal write (`done`, `failed` incl. `pod_lost`/`no_results`, `cancelled`, launch timeout) is followed by
   `DELETE /v2/pods/{pod_id}` in a background thread (`pod.deleted` / `pod.delete_failed`). 204 and 404 both count as
   deleted; 429/5xx retry 3x with backoff. A cancel that lands while the create call is in flight deletes the pod the
   moment the create returns.
4. Watchdog (every 30 s): `running` with no heartbeat for 120 s -> `failed:pod_lost` + pod deleted;
   `launching` past `MDE_LAUNCH_TIMEOUT_S` with no heartbeat -> `job.launch_timeout`, `failed:no_capacity` + pod deleted.
5. Reaper (`reaper_once`, every `MDE_REAPER_INTERVAL_S` and once at boot; CONTRACT "Pod lifecycle", GJOB-099): lists
   every pod on the account and deletes any `mde-*` pod whose job is terminal, missing (`pod_id` and name suffix both
   unknown), or whose age exceeds the job's `wall_limit_s` + 20 min (`reaper.deleted` with `reason`). Pods not named
   `mde-*` are never touched. Consecutive delete failures per pod are counted in memory; the third logs `reaper.stuck`
   (page on that). Job rows keep `pod_id` after deletion for the audit trail; `GET /v1/jobs/{id}` echoes it.

Job tokens end up in the pod's env on RunPod (that is how the runner authenticates), so anyone with the RunPod account
can read them while the pod exists; the endpoint invalidates the token at every terminal state, and a job token cannot
touch pods or keys. The RunPod API key itself lives only in the env file and the `Authorization` header.

## Deploy (Ubuntu 24.04, Caddy TLS, systemd)
```
deploy/deploy.sh root@HOST                  # rsync + bootstrap.sh + restart + https health check
ssh root@HOST  'vi /etc/mde/endpoint.env && systemctl restart mde-endpoint'   # first time: fill the env file
ssh root@HOST   mde-admin stats
```
`bootstrap.sh` is idempotent: apt update, unattended-upgrades, ufw 22/80/443, user `mde`, Caddy from its apt repo,
`/opt/mde` (code), `/var/lib/mde` (state, owned by `mde`), `/etc/mde` (env, root:mde 0640), both services enabled.
It copies no secrets; an example env file is placed only if none exists. DNS for the hostname in `deploy/Caddyfile`
must point at the box before Caddy can obtain its certificate. The unit runs with `ProtectSystem=strict`; the only
writable path is `/var/lib/mde`.

Back up `/var/lib/mde/mde.sqlite` (it is the ledger): `sqlite3 /var/lib/mde/mde.sqlite ".backup /root/mde-$(date +%F).sqlite"`
or continuous replication with litestream.

## Operations
- **Open the runners**: set `MDE_RUNNERS_OPEN=1` in the env file, `systemctl restart mde-endpoint`, confirm
  `curl https://HOST/v1/health` says `"runners":"open"`. Setting it back to `0` closes submission without touching
  balances (403/503 happen after auth and balance checks, so `mdengine account` keeps working).
- **Rotate the webhook secret**: in Stripe, add a second webhook endpoint (or roll the secret) for
  `checkout.session.completed` -> `https://HOST/v1/stripe/webhook`; put the new `whsec_` in the env file; restart;
  send a test event from the Stripe dashboard and check `journalctl` for `credit.*`/`webhook.bad_signature`; delete the old
  endpoint. A bad signature returns 400 and Stripe retries, so a short overlap loses nothing.
- **Rotate the Stripe secret key**: replace `STRIPE_SECRET_KEY`, restart. Only session reads are needed
  (a restricted key with `checkout_sessions: read` works).
- **Issue a key by hand**: `mde-admin key new --email E --credit 25 [--label L]` (prints the key once);
  top up: `mde-admin credit add --key KEYID --usd 50`; inspect: `mde-admin key list`, `mde-admin ledger [--key KEYID]`, `mde-admin stats`.
- **Replace a lost key**: create a new key with `key new --credit 0`, then `credit add` the old balance and note the
  old key id in `--label`. Old keys cannot be recovered from their hash.
- **Pod stand-in without a launcher**: with `RUNPOD_API_KEY` unset, `start` writes `/var/lib/mde/launch.env`
  (`MDE_ENDPOINT`, `MDE_JOB_ID`, `MDE_JOB_TOKEN`) for a hand-run `docker/runner-gpu/runner.sh` (dev loop).
- **Rotate the RunPod key**: create the new key in RunPod (pods read/write), replace `RUNPOD_API_KEY`, restart, check
  `journalctl` for `reaper.boot` (a successful list) rather than `reaper.list_failed`; then revoke the old key.
- **Orphan check by hand**: `journalctl -u mde-endpoint | grep -E 'reaper\.(deleted|stuck|list_failed)|pod\.delete_failed'`.
  `reaper.stuck` means three passes failed to delete one pod: delete it in the RunPod console and look at the error text.

## Not in this skeleton (tracked in `../CONTRACT.md`)
Presigned object-storage (R2) URLs — blobs live on the box behind signed URLs; automatic relaunch on `pod_lost`
(attempt 2) — the watchdog marks the job `failed:pod_lost`, deletes the pod, and does not bill it. The GPU/cloud
fallback ladder is walked at create time (a rung that refuses moves to the next one immediately); a pod that is
accepted but never heartbeats is not moved to the next rung, it times out to `failed:no_capacity`.
