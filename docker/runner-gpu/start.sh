#!/bin/sh
# Pod entrypoint: install the operator's public key, report the GPU, serve ssh.
set -eu
if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
ssh-keygen -A >/dev/null 2>&1 || true
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "no GPU visible"
lmp -h 2>/dev/null | grep -m1 -o "KOKKOS" || echo "WARNING: lmp lacks KOKKOS"
exec /usr/sbin/sshd -D -e -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password
