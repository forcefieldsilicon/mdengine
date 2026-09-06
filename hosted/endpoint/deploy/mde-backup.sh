#!/bin/bash
# Hourly consistent snapshot of the ledger db (sqlite online backup), 72 h rotation + daily keep 30.
# Installed by bootstrap.sh as /opt/mde/mde-backup.sh with a systemd timer. Off-box copy is pulled
# by the operator workstation (see README "Backups"); Hetzner server snapshots are the second layer.
set -euo pipefail
DB=${MDE_DB:-/var/lib/mde/mde.sqlite}; OUT=/var/lib/mde/backups; mkdir -p "$OUT/hourly" "$OUT/daily"
ts=$(date -u +%Y%m%dT%H%MZ); day=$(date -u +%Y%m%d)
sqlite3 "$DB" ".backup '$OUT/hourly/mde-$ts.sqlite'"
gzip -f "$OUT/hourly/mde-$ts.sqlite"
[ -e "$OUT/daily/mde-$day.sqlite.gz" ] || cp "$OUT/hourly/mde-$ts.sqlite.gz" "$OUT/daily/mde-$day.sqlite.gz"
ls -1t "$OUT/hourly"/*.gz 2>/dev/null | tail -n +73 | xargs -r rm -f
ls -1t "$OUT/daily"/*.gz  2>/dev/null | tail -n +31 | xargs -r rm -f
sha256sum "$OUT/hourly/mde-$ts.sqlite.gz" | cut -c1-16
