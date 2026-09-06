#!/bin/sh
# Pod entrypoint (OpenMM flavour): install the operator's public key, report the GPU, serve ssh.
set -eu
if [ -n "${MDE_JOB_ID:-}" ]; then
  # production: pull one job, exit. Pod-side TTL (CONTRACT "Pod lifecycle" #3): even with the endpoint
  # unreachable, this container ends at wall+600 s, so GPU billing is bounded without any outside help.
  exec timeout --signal=TERM --kill-after=60 "$(( ${MDE_WALL_LIMIT_S:-86400} + 600 ))" /usr/local/bin/runner.sh
fi
if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
ssh-keygen -A >/dev/null 2>&1 || true
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "no GPU visible"
python3 -c "import openmm; print('openmm', openmm.__version__)" 2>/dev/null || echo "WARNING: openmm not importable"
exec /usr/sbin/sshd -D -e -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password
