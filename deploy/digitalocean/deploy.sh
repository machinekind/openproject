#!/usr/bin/env bash
# Start or update the stack. "./deploy.sh <image>" switches to that image; without an argument it applies .env as it is.
# The seeder migrates before web and worker start. When it fails, compose has already replaced web and worker, so they
# stay stopped. The old image is not restarted automatically because the schema may already be migrated.
set -euo pipefail
cd "$(dirname "$0")"
umask 077

new="${1:-}"
image_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
if [ -n "$new" ] && [[ ! $new =~ $image_re ]]; then
  echo "refusing an image reference with unexpected characters" >&2
  exit 2
fi

exec 9>.deploy.lock
flock -n 9 || { echo "another deploy is running" >&2; exit 1; }

env_value() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2-; }
web_container() { docker compose ps -q web 2>/dev/null || true; }

set_image() {
  { grep -v '^OPENPROJECT_IMAGE=' .env || true; } > .env.tmp
  printf 'OPENPROJECT_IMAGE=%s\n' "$1" >> .env.tmp
  chmod 600 .env.tmp
  mv .env.tmp .env
}

predeploy_dump() {
  url="$(env_value DATABASE_URL)"
  [ -n "$url" ] || { echo "DATABASE_URL missing in .env" >&2; return 1; }
  dest="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
  dest="${dest:-/var/backups/openproject}"
  label="${1##*/}"
  label="${label%%@*}"
  case "$label" in *:*) label="${label##*:}" ;; *) label=untagged ;; esac
  label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
  file="$dest/db-predeploy-$label-$(date +%Y%m%d%H%M).dump"
  mkdir -p "$dest" || return 1
  PGURL="${url%%&pool=*}" docker run --rm -e PGURL postgres:17 sh -c 'exec pg_dump "$PGURL" -x -O -Fc' > "$file.part" || { rm -f "$file.part"; return 1; }
  mv "$file.part" "$file" || return 1
  chmod 600 "$file"
  echo "pre-deploy dump: ${file##*/} ($(du -h "$file" | cut -f1))"
  ls -1t "$dest"/db-predeploy-*.dump 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done
}

record_previous() {
  [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ] || return 0
  printf '%s\n' "$old" > .deploy/previous-image
  if [ -n "$old_id" ]; then
    printf '%s\n' "$old_id" > .deploy/previous-image-id
  else
    rm -f .deploy/previous-image-id
  fi
}

prune_images() {
  current_id="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null || true)"
  ref="$(docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || true)"
  previous_id="$(cat .deploy/previous-image-id 2>/dev/null || true)"
  repo="${ref%%@*}"
  case "${repo##*:}" in */*) ;; *) repo="${repo%:*}" ;; esac
  { [ -n "$repo" ] && [ -n "$current_id" ]; } || return 0
  docker image ls --no-trunc --format '{{.Repository}} {{.ID}}' 2>/dev/null | awk -v r="$repo" '$1 == r { print $2 }' | sort -u |
    while IFS= read -r id; do
      [ "$id" = "$current_id" ] || [ "$id" = "$previous_id" ] || docker image rm -f "$id" >/dev/null 2>&1 || true
    done
  docker image prune -f >/dev/null 2>&1 || true
}

fail() {
  echo "deploy failed: $1" >&2
  if [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ]; then
    set_image "$old"
    echo ".env names $old again; the containers may still run the new image or be stopped." >&2
  fi
  echo "Inspect with 'make logs SERVICE=seeder' and 'make logs SERVICE=web'. Roll back with 'make rollback' only if the new migrations are backwards compatible; otherwise restore the database (README, Restoring)." >&2
  echo "Do not run deploy.sh without an argument (or make deploy) until you have decided between rollback and restore, because that would start old code on a possibly migrated schema." >&2
  exit 1
}

old="$(env_value OPENPROJECT_IMAGE)"
old_id=""
mkdir -p .deploy
web="$(web_container)"
if [ -n "$new" ] && [ -n "$web" ] && [ -n "$old" ]; then
  running="$(docker inspect --format '{{.Config.Image}}' "$web")"
  if [ "$running" = "$old" ]; then
    old_id="$(docker inspect --format '{{.Image}}' "$web" 2>/dev/null || true)"
  fi
fi

if [ -n "$new" ]; then
  OPENPROJECT_IMAGE="$new" docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
else
  docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
fi
predeploy_dump "${new:-$old}" || { echo "pre-deploy database dump failed; nothing was changed" >&2; exit 1; }
[ -z "$new" ] || set_image "$new"
docker compose up -d --remove-orphans || fail "docker compose up failed (a failed migration in the seeder stops web and worker)"
echo "Waiting for web to become healthy (first boot loads the schema and can take several minutes)..."
for _ in $(seq 1 60); do
  web="$(web_container)"
  status=starting
  [ -z "$web" ] || status="$(docker inspect --format '{{.State.Health.Status}}' "$web" 2>/dev/null || echo starting)"
  if [ "$status" = healthy ]; then
    echo healthy
    record_previous
    prune_images "$web"
    echo "running: $(docker inspect --format '{{.Config.Image}}' "$web")"
    exit 0
  fi
  sleep 10
done
fail "web did not become healthy within 10 minutes"
