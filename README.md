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

Both decks are ready inputs for `mdengine run` and `submit_lammps`. Bare
force-field names resolve automatically: if `$LAMMPS_POTENTIALS` is unset,
MDEngine derives it from the LAMMPS install.

## MCP server

Register with Claude Code:

```sh
claude mcp add mdengine /path/to/.build/release/mdengine-mcp
```

Submitted jobs are wrapped in `caffeinate -i`, run in the deck's own directory
(relative `read_data` paths work), survive the server exiting, and record
their exit code unattended under `~/.mdengine/jobs/`. LAMMPS runs launch with
`-sf omp -pk omp N` so the OPENMP package is actually engaged.

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
