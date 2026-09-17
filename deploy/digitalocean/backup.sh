#!/usr/bin/env bash
# Nightly belt-and-braces backup. The managed database already has daily backups with 7-day
# point-in-time recovery, and the Droplet has weekly image backups. This adds a portable copy you can
# restore anywhere: a logical database dump and an archive of the attachments volume, kept 7 days
# locally and pushed off the server when RCLONE_REMOTE is set (e.g. "spaces:my-bucket/openproject").
# Install: echo '15 3 * * * root /srv/openproject/backup.sh >> /var/log/openproject-backup.log 2>&1' > /etc/cron.d/openproject-backup
set -euo pipefail
cd "$(dirname "$0")"
# Read single values instead of sourcing .env: a database URL contains "&", which bash would interpret.
env_value() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2-; }
DATABASE_URL="$(env_value DATABASE_URL)"
RCLONE_REMOTE="${RCLONE_REMOTE:-$(env_value RCLONE_REMOTE)}"
BACKUP_DIR="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
DEST="${BACKUP_DIR:-/var/backups/openproject}"
STAMP="$(date +%F)"
mkdir -p "$DEST"
URL="${DATABASE_URL%%&pool=*}"
docker run --rm postgres:17 pg_dump "$URL" -x -O -Fc > "$DEST/db-$STAMP.dump"
docker run --rm -v openproject_assets:/assets:ro -v "$DEST":/out alpine \
  tar -czf "/out/assets-$STAMP.tar.gz" -C /assets .
# Database dumps are small: keep a week. Attachment archives are full copies: keep two locally,
# otherwise local backups grow to seven times the attachment size and fill the disk.
find "$DEST" -type f -name 'db-*.dump' -mtime +7 -delete
find "$DEST" -type f -name 'assets-*.tar.gz' -mtime +1 -delete
if [ -n "${RCLONE_REMOTE:-}" ]; then
  rclone copy "$DEST" "$RCLONE_REMOTE" --include "*-$STAMP.*"
fi
echo "$(date -Is) backup ok: $(du -sh "$DEST" | cut -f1) in $DEST"
