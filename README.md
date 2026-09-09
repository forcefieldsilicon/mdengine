# MDEngine

*by ForceField Silicon*

A native macOS molecular-dynamics workbench: a Metal trajectory viewer, a
command-line tool, and an MCP server that lets AI agents inspect trajectories
and run LAMMPS simulations as detached background jobs.

> **Status: pre-release.** Not yet distributed; the app is ad-hoc signed
> (builds run on the building machine only until notarization lands).

## Parts

| Product | What it is |
|---|---|
| **MDEngine.app** | Metal viewer — orbit / pan / zoom camera, trajectory timeline with 20%/5% tick marks, CPK element colours, XYZ / extended-XYZ, live settings |
| **mdengine-cli** | `info` / `export` / `decimate` / `run` on trajectories and decks |
| **mdengine-mcp** | MCP stdio server — trajectory tools plus a detached LAMMPS job runner (`submit_lammps` / `job_status` / `job_log` / `list_jobs` / `cancel_job`) |

## Build

Requires macOS 14+ and Xcode command-line tools. LAMMPS (`brew install lammps`)
is needed only for `run` / `submit_lammps`.

```sh
swift build -c release            # all three products
./scripts/make_app.sh             # assemble + install /Applications/MDEngine.app
```

## Bundled examples

| Example | What it shows |
|---|---|
| `lj_melt.xyz` / `lj_melt.in` | Lennard-Jones argon melt — the minimal smoke test |
| `fe_oxidation.xyz` / `fe_oxidation.in` | ReaxFF iron oxidation: a bcc Fe slab meeting O₂ gas, using `ffield.reax.Fe_O_C_H` from the LAMMPS distribution |

Trajectory readers are safe on **in-flight dumps** — a file a running
simulation is still writing parses to its complete frames, so you can inspect
a run mid-flight. Rows with non-finite (NaN/inf) coordinates are dropped.

Both decks are ready inputs for `mdengine run` and `submit_lammps`. Bare
force-field names resolve automatically: if `$LAMMPS_POTENTIALS` is unset,
MDEngine derives it from the LAMMPS install.

## MCP server

`mdengine-mcp` is a dependency-free MCP stdio server, listed in the
[MCP Registry](https://registry.modelcontextprotocol.io) as
`com.forcefieldsilicon/mdengine` (`server.json` in this repo). Each release ships a
signed macOS [MCP Bundle](https://github.com/modelcontextprotocol/mcpb)
(`mdengine-mcp-<version>-macos-arm64.mcpb`): double-click it to install in Claude
Desktop, or unpack it (`mcpb unpack`) for any other client. Built from source, register
with Claude Code:

```sh
claude mcp add mdengine /path/to/.build/release/mdengine-mcp
```

or in Claude Desktop's `claude_desktop_config.json`:

```json
{ "mcpServers": { "mdengine": { "command": "/path/to/.build/release/mdengine-mcp" } } }
```

| Tool | Does |
|---|---|
| `trajectory_info` | Frames, atom counts, per-atom fields, elements, bbox, charge range |
| `z_profile` | Deposition/oxidation depth analysis: substrate surface plane, probe penetration depths (min/mean/max), at-surface & in-flight counts, bound-probe charge, z histogram |
| `render_video` | Trajectory → MP4 (H.264) or animated GIF via the Metal renderer: camera angles, stride, cinematic orbit, baked scale-bar/frame annotations, per-element `colors`/`sizes`, `style: "contrast"` auto-visibility |
| `render_image` | One frame → PNG with the same camera/style options — lets an agent *see* a simulation state |
| `export_frame` | One frame → XYZ; `charges: true` → extended-XYZ with the q column |
| `decimate` | Keep every Nth frame (final frame always kept) |
| `submit_lammps` | Detached LAMMPS job: survives the server exiting and machine display-sleep (`caffeinate`), exit code recorded unattended |
| `job_status` / `job_log` | State + live thermo tail / raw log tail |
| `job_files` | Locate a finished job's outputs (run dir + bookkeeping dir) |
| `list_jobs` / `cancel_job` | Registry under `~/.mdengine/jobs/` / SIGTERM a run (state becomes `cancelled`) |
| `list_hosts` | Execution hosts from `~/.mdengine/hosts.json` and which is the default |
| `fetch_job` | Pull a remote job's run directory (dumps, data) + logs into the local job dir under `results/` |
| `run_lammps` | Synchronous run for short tests only |

### Hosted GPU tier over MCP (no install)

The same jobs are reachable from **any MCP client that speaks HTTP** — Claude Code, Claude.ai
custom connectors, Cursor, Goose — via the hosted endpoint's Streamable HTTP server:

```sh
claude mcp add --transport http mdengine-cloud https://api.forcefieldsilicon.com/mcp
```

Sign in when the client asks (OAuth 2.1: a consent page where you paste your API key once; the
client keeps a token, the key stays with you). Scripted clients may instead send the key directly
as `--header "Authorization: Bearer mde_YOUR_KEY"`. The key comes with a prepaid credit pack
([forcefieldsilicon.com/mdengine](https://forcefieldsilicon.com/mdengine)). `initialize` and
`tools/list` work without signing in; tool calls without a credential return 401 with the OAuth
**Windows and Linux.** The hosted tier is the supported path on both, and it is the full paid
product: every tool below works from Claude Code on Windows exactly as on a Mac. In PowerShell,
register at user scope so the server follows you into every folder, then sign in once:

```powershell
claude mcp add --scope user --transport http mdengine-cloud https://api.forcefieldsilicon.com/mcp
```

Start `claude`, type `/mcp`, pick `mdengine-cloud`, choose Authenticate, and paste the key on the
browser consent page (never into the chat). Decks written on Windows (CRLF line endings) are
accepted as-is. The local viewer, renderer and CPU job runner are macOS-only today; a Windows/Linux
local build is planned and demand decides its order, so say so if you need it.

discovery pointer, which is what makes clients offer the sign-in. Tools: `account`, `capabilities`, `preflight_deck`, `submit_job` (deck inline, ≤ 8 MB),
`create_job` + `start_job` (big decks via presigned PUT), `job_status`, `job_log`,
`job_results`, `list_jobs`, `delete_results`, `cancel_job`. Discovery card:
`https://api.forcefieldsilicon.com/.well-known/mcp/server-card.json`. The hosted service (endpoint, billing, GPU launcher) is operated by ForceField Silicon and its
source is not part of this repository; the client side of it (`HostedClient`, CLI `run --gpu`,
MCP `host=cloud`) is here under the MIT license like everything else.

**Preflight before spend (GJOB-118).** `GET /v1/capabilities` publishes the hosted image's LAMMPS
version, packages and every style with a `gpu` flag: true = KOKKOS-accelerated, false = the style
exists but runs on the pod's CPU cores at the GPU rate. Every client checks a deck against it first —
`mdengine capabilities deck.in`, the app's Run Accelerated, `submit_lammps host=cloud`, the hosted
`submit_job` — refusing a deck whose styles the image lacks (LAMMPS would exit at startup) and warning
when the pair style has no `/kk` variant (the run would not use the GPU). `--force` / `force=true`
overrides; the server only advises (`preflight` in the start response), it never blocks.

Troubleshooting the hosted connector:

| Symptom | Cause / fix |
|---|---|
| Client says authentication required / 401 | Use the client's sign-in (OAuth) and paste your `mde_…` key on the consent page, or add the header `Authorization: Bearer mde_…`. Keys are issued at purchase and shown once. |
| Consent page says the key was not recognised | Keys are `mde_` + 32 hex characters; a revoked key no longer works. `mdengine account` prints the balance for a saved key. |
| "insufficient balance" | Top up at forcefieldsilicon.com/mdengine; submissions need credit for at least 15 min at the GPU rate. |
| "gpu_runners_open_soon" (503) | Runners are temporarily closed; credits are safe. |
| HTTP 429 | Too many keyless requests from one IP; add the key or slow down. |
| `job_results` says results unavailable | Files were deleted by `delete_results`, the run produced none, or the 30-day purge ran. |
| Job `failed` with `runner_error` / `lammps_error` | The deck itself failed; `job_results` (if present) or `job_log` holds the LAMMPS error text. |
| Job `failed` with `pod_lost` / `no_capacity` / `launch_timeout` / `gpu_unavailable` | Infrastructure (pod died, no GPU stock, a pod that never came up, or the host handed the pod no CUDA device); never billed, relaunched once automatically. Resubmit if it still fails. |

Jobs run in the deck's own directory (relative `read_data` paths work) and
launch with `-sf omp -pk omp N` so the OPENMP package is actually engaged;
`$LAMMPS_POTENTIALS` is derived from the LAMMPS install when unset.

## Remote hosts (run on your own Linux / GPU box)

The job runner can execute on another machine with the **same tool contract**:
declare hosts in `~/.mdengine/hosts.json` and pass `host` to `submit_lammps`
(or set a `default`). The deck's directory is rsynced up (trajectories,
checkpoints and logs excluded), LAMMPS starts under `nohup` with its exit code
recorded remotely, and `job_status` / `job_log` / `job_files` / `cancel_job`
work unchanged; `fetch_job` brings results back for `trajectory_info`,
`z_profile` and the renderers.

```json
{
  "default": "gpu1",
  "hosts": {
    "gpu1": {
      "ssh": "me@gpu1.example.net",
      "workdir": "~/mdengine-jobs",
      "lmp": "/usr/local/bin/lmp",
      "threads": 8,
      "launch": "{lmp} -in {input} -k on g 1 -sf kk -pk kokkos newton on neigh half -log {log}"
    }
  }
}
```

`ssh` is anything `ssh` accepts (key-based, non-interactive); `lmp` must be an
absolute path (login PATH is not available over ssh); `launch` is optional —
the default is the OpenMP form, and a GPU host is simply one whose template
carries the KOKKOS flags. A remote deck must be self-contained within its own
directory. The same trust model as local runs applies, on the remote machine.

## Platform & limits

macOS 14+ (Apple Silicon or Intel). Trajectories are loaded whole into memory
— files over 2 GB are refused with guidance to decimate or split first.

## Security note

**Running a LAMMPS input executes whatever the deck says.** LAMMPS decks are
programs, not data — they can invoke arbitrary shell commands (LAMMPS has a
literal `shell` command). Treat a deck from someone else exactly like a shell
script: read it before running it.

This applies doubly to the MCP server: **an AI agent connected to
`mdengine-mcp` can submit decks, and a submitted deck runs with your user's
full privileges on this machine.** That is the same trust model as any local
dev tool (an agent that can run `make` can run anything), but be deliberate
about which decks — and which agents — you hand to the job runner. Sandboxed
execution (containers, no network, resource caps) is how a future hosted tier
makes running untrusted decks safe; the local server does not sandbox.

## Privacy

The local tools collect nothing; see [PRIVACY.md](PRIVACY.md), which also covers the
hosted GPU tier.

## License

MIT © Gitinama Inc. (d/b/a ForceField Silicon)
