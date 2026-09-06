#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu 24.04 host for the MDEngine hosted endpoint. Idempotent; run as root.
# Takes NO secrets: /etc/mde/endpoint.env is written separately (see ../README.md).
# Expects mde_endpoint.py, mde_admin.py and deploy/ next to this script (deploy.sh rsyncs them).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$(dirname "$HERE")
export DEBIAN_FRONTEND=noninteractive

echo "== packages"
apt-get update -q
apt-get install -y -q python3 sqlite3 ufw unattended-upgrades debian-keyring debian-archive-keyring apt-transport-https curl gnupg rsync
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "== firewall"
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ufw status | head -5

echo "== caddy (official apt repo)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q && apt-get install -y -q caddy
fi

echo "== user + dirs"
id mde >/dev/null 2>&1 || useradd --system --home /var/lib/mde --shell /usr/sbin/nologin mde
install -d -o root -g root -m 755 /opt/mde
install -d -o mde -g mde -m 750 /var/lib/mde /var/lib/mde/blobs
install -d -o root -g mde -m 750 /etc/mde
install -d -o caddy -g caddy -m 755 /var/log/caddy 2>/dev/null || true

echo "== files"
install -o root -g root -m 755 "$SRC/mde_endpoint.py" /opt/mde/mde_endpoint.py
install -o root -g root -m 755 "$SRC/mde_admin.py" /opt/mde/mde_admin.py
install -o root -g root -m 644 "$SRC/mde_launcher.py" /opt/mde/mde_launcher.py
ln -sf /opt/mde/mde_admin.py /usr/local/bin/mde-admin
install -o root -g root -m 644 "$HERE/mde-endpoint.service" /etc/systemd/system/mde-endpoint.service
install -o root -g root -m 755 "$HERE/mde-backup.sh" /opt/mde/mde-backup.sh
install -o root -g root -m 644 "$HERE/mde-backup.service" /etc/systemd/system/mde-backup.service
install -o root -g root -m 644 "$HERE/mde-backup.timer" /etc/systemd/system/mde-backup.timer
install -o root -g root -m 644 "$HERE/mde-statements.service" /etc/systemd/system/mde-statements.service
install -o root -g root -m 644 "$HERE/mde-statements.timer" /etc/systemd/system/mde-statements.timer
install -o root -g root -m 644 "$HERE/Caddyfile" /etc/caddy/Caddyfile
install -d -m 755 /etc/systemd/system/caddy.service.d
install -o root -g root -m 644 "$HERE/caddy-override.conf" /etc/systemd/system/caddy.service.d/override.conf
if [ ! -f /etc/mde/endpoint.env ]; then
  install -o root -g mde -m 640 "$HERE/endpoint.env.example" /etc/mde/endpoint.env
  echo "!! /etc/mde/endpoint.env is the EXAMPLE — fill in the real values, then: systemctl restart mde-endpoint"
fi
python3 -m py_compile /opt/mde/mde_endpoint.py /opt/mde/mde_admin.py /opt/mde/mde_launcher.py

echo "== services"
systemctl daemon-reload
systemctl enable --now caddy >/dev/null
systemctl enable mde-endpoint >/dev/null
systemctl enable --now mde-backup.timer >/dev/null
systemctl enable --now mde-statements.timer >/dev/null
systemctl restart mde-endpoint
caddy validate --config /etc/caddy/Caddyfile >/dev/null
chown -R caddy:caddy /var/log/caddy   # validate (run as root) may have created the access log root-owned
systemctl restart caddy
sleep 1
systemctl is-active mde-endpoint caddy
curl -fsS http://127.0.0.1:8080/v1/health && echo
echo "== done"
