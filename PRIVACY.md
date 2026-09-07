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
  Payment card details are handled by Stripe and never reach us.
- **Job data:** the simulation deck and input files you submit, the outputs the run
  produces, and job metadata (timestamps, runtime, exit status, GPU class). Job files
  are retained so you can fetch them, then deleted on a schedule described in the
  product documentation; you can delete a job's files earlier from the CLI or MCP tools.
- **Operational logs:** request timestamps, API-key id and IP address, kept for
  security and billing for up to 90 days.

We use this data only to run your jobs, bill you, and keep the service secure. We do
not sell it, use it to train models, or share it with third parties other than the
processors that operate the service (Stripe for payments, Hetzner and RunPod for
compute and storage).

## Your rights and contact

Email **privacy@forcefieldsilicon.com** to access, export or delete your hosted-tier
data, or to ask anything about this policy. Changes are recorded in this file's git
history.
