# Privacy Policy — MDEngine

_Effective 2026-09-06. Applies to MDEngine.app, `mdengine` (CLI) and `mdengine-mcp` (MCP server), published by Gitinama Inc., doing business as ForceField Silicon._

## Local tools collect nothing

MDEngine.app, the CLI and the MCP server run entirely on your machine. They do not
send telemetry, analytics, crash reports or usage data anywhere. Trajectories,
simulation decks, rendered images and job logs stay on your disk (jobs under
`~/.mdengine/jobs`). No account is needed.

## Optional remote execution you configure

If you add ssh hosts to `~/.mdengine/hosts.json`, job inputs and outputs move between
your machine and those hosts over your own ssh connection. We are not a party to
that traffic.

## Optional hosted GPU tier

If you buy a ForceField Silicon API key and run jobs on the hosted tier
(`api.forcefieldsilicon.com`), we receive and store:

- **Account data:** the email address used at checkout and a Stripe customer id.
  Payment card details are handled by Stripe and never reach us. API keys are stored
  only as hashes. If you connect an AI client through the sign-in page, we store hashed
  OAuth tokens for that client (access tokens live 24 hours, refresh tokens 90 days) and
  the client's registration record; revoking your key invalidates them all.
- **Job data:** the simulation deck and input files you submit, the outputs the run
  produces, and job metadata (timestamps, runtime, exit status, GPU class). Deck and
  result files are deleted automatically 30 days after the run finishes, or earlier on
  request (`delete_results` tool, `DELETE /v1/jobs/{id}/results`); job metadata and
  billing records are kept for accounting.
- **Operational logs:** request timestamps, API-key id and IP address, kept for
  security and billing and rotated automatically. Full API keys are never logged.

We use this data only to run your jobs, bill you, and keep the service secure. We do
not sell it, use it to train models, or share it with third parties other than the
processors that operate the service (Stripe for payments, Hetzner and RunPod for
compute and storage).

## Your rights and contact

Email **arvand@gitinama.tech** (Gitinama Inc.) to access, export or delete your hosted-tier
data, or to ask anything about this policy. Changes are recorded in this file's git
history.
