# MDEngine

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

A Lennard-Jones argon melt is bundled as the example (`lj_melt.xyz`), together
with the deck that generated it (`lj_melt.in`) — a ready test input for the
job runner.

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

Running a LAMMPS input executes whatever the deck says — LAMMPS decks can
invoke shell commands (the `shell` command). Treat decks from others like
scripts: read them before running them.

## License

MIT © Gitinama Inc.
