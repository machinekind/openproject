#!/usr/bin/env bash
# Nightly portable backup. The managed database already has daily backups with 7-day point-in-time
# recovery, and the Droplet has image backups. This adds copies you can restore anywhere: a logical
# database dump and an archive of the attachments volume. Attachments exist ONLY on this Droplet
# otherwise, so set RCLONE_REMOTE (in .env) to push both off the server, ideally outside DigitalOcean.
# Install: echo '15 3 * * * root /srv/openproject/backup.sh >> /var/log/openproject-backup.log 2>&1' > /etc/cron.d/openproject-backup
set -euo pipefail
umask 077
cd "$(dirname "$0")"
trap 'echo "$(date -Is) backup FAILED (line $LINENO)" >&2' ERR
# Read single values instead of sourcing .env: a database URL contains "&", which bash would interpret.
# A missing key must not abort the script, hence "|| true".
env_value() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2-; }
DATABASE_URL="$(env_value DATABASE_URL)"
[ -n "$DATABASE_URL" ] || { echo "DATABASE_URL missing in .env" >&2; exit 1; }
RCLONE_REMOTE="${RCLONE_REMOTE:-$(env_value RCLONE_REMOTE)}"
DEST="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
DEST="${DEST:-/var/backups/openproject}"
STAMP="$(date +%F)"
mkdir -p "$DEST"
# Passed through the environment so the password is not in the docker command line.
export PGURL="${DATABASE_URL%%&pool=*}"
# Write to .part and rename, so an interrupted run never leaves a truncated file that looks complete.
docker run --rm -e PGURL postgres:17 sh -c 'exec pg_dump "$PGURL" -x -O -Fc' > "$DEST/db-$STAMP.dump.part"
mv "$DEST/db-$STAMP.dump.part" "$DEST/db-$STAMP.dump"
docker run --rm -v openproject-prod_assets:/assets:ro -v "$DEST":/out alpine \
  tar -czf "/out/assets-$STAMP.tar.gz.part" -C /assets .
mv "$DEST/assets-$STAMP.tar.gz.part" "$DEST/assets-$STAMP.tar.gz"
# Database dumps are small: keep a week. Attachment archives are full copies: keep two locally,
# otherwise local backups grow to seven times the attachment size and fill the disk.
find "$DEST" -type f -name 'db-*.dump' -mtime +7 -delete
find "$DEST" -type f -name 'assets-*.tar.gz' -mtime +1 -delete
find "$DEST" -type f -name '*.part' -mtime +1 -delete
if [ -n "$RCLONE_REMOTE" ]; then
  rclone copy "$DEST" "$RCLONE_REMOTE" --include "*-$STAMP.*"
  echo "$(date -Is) backup ok, copied to $RCLONE_REMOTE: $(du -sh "$DEST" | cut -f1) in $DEST"
else
  echo "$(date -Is) backup ok, but RCLONE_REMOTE is not set: these files exist only on this Droplet ($(du -sh "$DEST" | cut -f1) in $DEST)"
fi
