#!/usr/bin/env bash
# Start or update the stack. "./deploy.sh <image>" switches to that image; without an argument it applies .env as it is.
# When a switch fails and the schema is still the one the old image last ran healthy on, the old image is started
# again. Otherwise nothing is restarted, because old code on a migrated schema is a decision for a person.
set -euo pipefail
cd "$(dirname "$0")"
umask 077

new="${1:-}"
image_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
SCHEMA_SQL="SELECT md5(concat_ws('|', (SELECT string_agg(version, ',' ORDER BY version) FROM schema_migrations), (SELECT string_agg(concat_ws(':', table_name, column_name, data_type, is_nullable, column_default), ',' ORDER BY table_name, column_name) FROM information_schema.columns WHERE table_schema = 'public'), (SELECT string_agg(indexdef, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname = 'public')))"
if [ -n "$new" ] && [[ ! $new =~ $image_re ]]; then
  echo "refusing an image reference with unexpected characters" >&2
  exit 2
fi

exec 9>.deploy.lock
flock -n 9 || { echo "another deploy is running" >&2; exit 1; }

env_value() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2-; }
web_container() { docker compose ps -q web 2>/dev/null || true; }
backup_dir() { dir="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"; printf '%s\n' "${dir:-/var/backups/openproject}"; }
pg_url() { url="$(env_value DATABASE_URL)"; [ -n "$url" ] || return 1; printf '%s\n' "${url%%&pool=*}"; }

set_image() {
  { grep -v '^OPENPROJECT_IMAGE=' .env || true; } > .env.tmp
  printf 'OPENPROJECT_IMAGE=%s\n' "$1" >> .env.tmp
  chmod 600 .env.tmp
  mv .env.tmp .env
}

predeploy_dump() {
  url="$(pg_url)" || { echo "DATABASE_URL missing in .env" >&2; return 1; }
  dest="$(backup_dir)"
  label="${1##*/}"
  label="${label%%@*}"
  case "$label" in *:*) label="${label##*:}" ;; *) label=untagged ;; esac
  label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
  digest=nodigest
  case "$1" in *@sha256:*) digest="$(printf '%.12s' "${1##*@sha256:}" | tr -c '0-9a-f' '_')" ;; esac
  dump_file="$dest/db-predeploy-$label-$(date -u +%Y%m%dT%H%M%SZ)-$digest.dump"
  [ ! -e "$dump_file" ] || dump_file="${dump_file%.dump}-$$.dump"
  mkdir -p "$dest" || return 1
  PGURL="$url" docker run --rm -e PGURL postgres:17 sh -c 'exec pg_dump "$PGURL" -x -O -Fc' > "$dump_file.part" || { rm -f "$dump_file.part"; return 1; }
  mv "$dump_file.part" "$dump_file" || return 1
  chmod 600 "$dump_file"
  echo "pre-deploy dump: $dump_file ($(du -h "$dump_file" | cut -f1))"
}

prune_dumps() {
  { ls -1t "$(backup_dir)"/db-predeploy-*.dump 2>/dev/null || true; } | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done
}

schema_fingerprint() {
  url="$(pg_url)" || return 0
  fp="$(printf '%s\n' "$SCHEMA_SQL" | PGURL="$url" docker run --rm -i -e PGURL postgres:17 sh -c 'exec psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1' 2>/dev/null)" || return 0
  [[ $fp =~ ^[0-9a-f]{32}$ ]] || return 0
  printf '%s\n' "$fp"
}

record_previous() {
  [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ] || return 0
  printf '%s\n' "$old" > .deploy/previous-image
  old_id="$(docker image inspect --format '{{.Id}}' "$old" 2>/dev/null || true)"
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

wait_healthy() {
  for _ in $(seq 1 60); do
    web="$(web_container)"
    status=starting
    [ -z "$web" ] || status="$(docker inspect --format '{{.State.Health.Status}}' "$web" 2>/dev/null || echo starting)"
    [ "$status" != healthy ] || return 0
    sleep 10
  done
  return 1
}

fail() {
  echo "deploy failed: $1" >&2
  if [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ]; then
    set_image "$old"
    echo ".env names $old again." >&2
    after="$(schema_fingerprint)"
    if [ -n "$after" ] && [ "$(cat .deploy/healthy-schema 2>/dev/null || true)" = "$after $old" ]; then
      echo "the database schema is still the one $old last ran healthy on. Starting $old again." >&2
      if docker compose up -d --remove-orphans && wait_healthy; then
        echo "rolled back automatically to $old: no migration had run" >&2
      else
        echo "the automatic rollback to $old did not become healthy either. Inspect with 'make logs SERVICE=web'." >&2
      fi
      exit 1
    fi
  fi
  [ -e .deploy/last-dump ] || [ -z "$dump_file" ] || printf '%s\n' "$dump_file" > .deploy/last-dump
  echo "The database schema is not the one ${old:-the previous image} last ran healthy on, or it could not be read, so nothing was restarted." >&2
  echo "Inspect with 'make logs SERVICE=seeder' and 'make logs SERVICE=web'. Then a person chooses:" >&2
  echo "  - roll forward: merge a fix to dev, or make deploy IMAGE=<fixed image>" >&2
  echo "  - go back: restore $(cat .deploy/last-dump 2>/dev/null || echo 'the pre-deploy dump') into a fresh database (README, Restoring), then make rollback, which deploys $(cat .deploy/previous-image 2>/dev/null || echo 'the previous image')" >&2
  echo "Do not run deploy.sh without an argument (or make deploy) before that decision: it would start old code on a possibly migrated schema." >&2
  exit 1
}

old="$(env_value OPENPROJECT_IMAGE)"
dump_file=""
mkdir -p .deploy

if [ -n "$new" ] && [[ $new == *@sha256:* ]] && docker image inspect --format '{{.Id}}' "$new" >/dev/null 2>&1; then
  echo "$new is already on this server; not pulling"
elif [ -n "$new" ]; then
  OPENPROJECT_IMAGE="$new" docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
else
  docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
fi
predeploy_dump "${new:-$old}" || { echo "pre-deploy database dump failed; nothing was changed" >&2; exit 1; }
record_previous
[ -z "$new" ] || set_image "$new"
docker compose up -d --remove-orphans || fail "docker compose up failed (a failed migration in the seeder stops web and worker)"
echo "Waiting for web to become healthy (first boot loads the schema and can take several minutes)..."
wait_healthy || fail "web did not become healthy within 10 minutes"
echo healthy
rm -f .deploy/last-dump
fp="$(schema_fingerprint)"
if [ -n "$fp" ]; then printf '%s %s\n' "$fp" "$(env_value OPENPROJECT_IMAGE)" > .deploy/healthy-schema; else rm -f .deploy/healthy-schema; fi
web="$(web_container)"
prune_images "$web"
prune_dumps
echo "running: $(docker inspect --format '{{.Config.Image}}' "$web")"
