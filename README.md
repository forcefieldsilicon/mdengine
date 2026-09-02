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

`mdengine-mcp` is a dependency-free MCP stdio server. Register with Claude Code:

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
| `list_jobs` / `cancel_job` | Registry under `~/.mdengine/jobs/` / SIGTERM a run |
| `run_lammps` | Synchronous run for short tests only |

Jobs run in the deck's own directory (relative `read_data` paths work) and
launch with `-sf omp -pk omp N` so the OPENMP package is actually engaged;
`$LAMMPS_POTENTIALS` is derived from the LAMMPS install when unset.

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

## License

MIT © Gitinama Inc. (d/b/a ForceField Silicon)
