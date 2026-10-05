#!/usr/bin/env bash
# Start or update the stack. "./deploy.sh <image>" switches to that image; without an argument it applies .env as it is.
# When a switch fails, the old image is started again only if this attempt's seeder finished every migration and the
# schema is still the one the old image last ran healthy on. Otherwise old code on a migrated schema is a decision for a person.
set -euo pipefail
cd "$(dirname "$0")"
umask 077

new="${1:-}"
image_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
kit_files=(deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh)
if [ -n "$new" ] && [[ ! $new =~ $image_re ]]; then
  echo "refusing an image reference with unexpected characters" >&2
  exit 2
fi
if [ -n "${EXPECTED_KIT_SHA256:-}" ] && [[ ! $EXPECTED_KIT_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "refusing a malformed kit checksum" >&2
  exit 2
fi

exec 9>.deploy.lock
flock -n 9 || { echo "another deploy is running" >&2; exit 1; }

if [ -n "${EXPECTED_KIT_SHA256:-}" ]; then
  kit_sum="$( { sha256sum "${kit_files[@]}" 2>/dev/null || true; } | sha256sum | cut -c1-64)"
  if [ "$kit_sum" != "$EXPECTED_KIT_SHA256" ]; then
    echo "refused: the deploy kit changed since the check (make push ran in between); nothing was changed. Rerun the failed jobs if this run's commit is still the newest on dev" >&2
    exit 1
  fi
fi

schema_sql() {
  cat <<'SQL'
SELECT md5(concat_ws('|',
  'migrations=' || coalesce((SELECT string_agg(version, ',' ORDER BY version) FROM schema_migrations), ''),
  'relations=' || coalesce((SELECT string_agg(format('%s:%s', c.relname, c.relkind), ',' ORDER BY c.relname)
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')), ''),
  'columns=' || coalesce((SELECT string_agg(format('%s.%s:%s:%s:%s', c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, coalesce(pg_get_expr(d.adbin, d.adrelid), '')), ',' ORDER BY c.relname, a.attname)
     FROM pg_attribute a
     JOIN pg_class c ON c.oid = a.attrelid
     JOIN pg_namespace n ON n.oid = c.relnamespace
     LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped), ''),
  'constraints=' || coalesce((SELECT string_agg(format('%s:%s:%s', coalesce(cl.relname, ''), co.conname, pg_get_constraintdef(co.oid)), ',' ORDER BY coalesce(cl.relname, ''), co.conname)
     FROM pg_constraint co
     JOIN pg_namespace n ON n.oid = co.connamespace
     LEFT JOIN pg_class cl ON cl.oid = co.conrelid
     WHERE n.nspname = 'public'), ''),
  'indexes=' || coalesce((SELECT string_agg(format('%s:%s', pg_get_indexdef(i.indexrelid), i.indisvalid), ',' ORDER BY ic.relname)
     FROM pg_index i
     JOIN pg_class ic ON ic.oid = i.indexrelid
     JOIN pg_namespace n ON n.oid = ic.relnamespace
     WHERE n.nspname = 'public'), ''),
  'triggers=' || coalesce((SELECT string_agg(pg_get_triggerdef(t.oid), ',' ORDER BY c.relname, t.tgname)
     FROM pg_trigger t
     JOIN pg_class c ON c.oid = t.tgrelid
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND NOT t.tgisinternal), ''),
  'views=' || coalesce((SELECT string_agg(format('%s:%s', c.relname, pg_get_viewdef(c.oid)), ',' ORDER BY c.relname)
     FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')), ''),
  'enums=' || coalesce((SELECT string_agg(format('%s:%s', t.typname, e.enumlabel), ',' ORDER BY t.typname, e.enumsortorder)
     FROM pg_enum e
     JOIN pg_type t ON t.oid = e.enumtypid
     JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'public'), ''),
  'functions=' || coalesce((SELECT string_agg(pg_get_functiondef(p.oid), ',' ORDER BY p.proname, pg_get_function_identity_arguments(p.oid))
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
       AND NOT EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.classid = 'pg_proc'::regclass AND dep.objid = p.oid AND dep.deptype = 'e')), '')
))
SQL
}

env_value() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2-; }
web_container() { docker compose ps -q web 2>/dev/null || true; }
backup_dir() { dir="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"; printf '%s\n' "${dir:-/var/backups/openproject}"; }
pg_url() { url="$(env_value DATABASE_URL)"; [ -n "$url" ] || return 1; printf '%s\n' "${url%%&pool=*}"; }
image_id() { [ -z "$1" ] || docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }
running_image_id() { web="$(web_container)"; [ -z "$web" ] || docker inspect --format '{{.Image}}' "$web" 2>/dev/null || true; }

set_image() {
  tmp="$(mktemp .env.XXXXXX)"
  { grep -v '^OPENPROJECT_IMAGE=' .env || true; } > "$tmp"
  printf 'OPENPROJECT_IMAGE=%s\n' "$1" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" .env
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
  keep="$(cat .deploy/last-dump 2>/dev/null || true)"
  { ls -1t "$(backup_dir)"/db-predeploy-*.dump 2>/dev/null || true; } | tail -n +4 | while IFS= read -r f; do
    [ "$f" = "$keep" ] || rm -f "$f"
  done
}

schema_fingerprint() {
  url="$(pg_url)" || return 0
  fp="$(schema_sql | PGURL="$url" docker run --rm -i -e PGURL postgres:17 sh -c 'exec psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1' 2>/dev/null)" || return 0
  [[ $fp =~ ^[0-9a-f]{32}$ ]] || return 0
  printf '%s\n' "$fp"
}

stage_previous() {
  [ -n "$new" ] && [ -n "$old" ] && [ "$new" != "$old" ] || return 0
  pending_id="$(image_id "$old")"
  printf '%s\n%s\n' "$old" "$pending_id" > .deploy/previous-image.pending
}

promote_previous() {
  [ -f .deploy/previous-image.pending ] || return 0
  sed -n 1p .deploy/previous-image.pending > .deploy/previous-image
  id="$(sed -n 2p .deploy/previous-image.pending)"
  if [ -n "$id" ]; then printf '%s\n' "$id" > .deploy/previous-image-id; else rm -f .deploy/previous-image-id; fi
  rm -f .deploy/previous-image.pending
}

prune_images() { # prune_images REF KEEP_ID...: removes the images of REF's repository except KEEP_IDs and images any container uses
  ref="$1"; shift
  repo="${ref%%@*}"
  case "${repo##*:}" in */*) ;; *) repo="${repo%:*}" ;; esac
  [ -n "$repo" ] || return 0
  keep=" $* $( { docker container ls -a -q 2>/dev/null | xargs -r docker container inspect --format '{{.Image}}' 2>/dev/null || true; } | tr '\n' ' ') "
  docker image ls --no-trunc --format '{{.Repository}} {{.ID}}' 2>/dev/null | awk -v r="$repo" '$1 == r { print $2 }' | sort -u |
    while IFS= read -r id; do
      case "$keep" in *" $id "*) ;; *) docker image rm -f "$id" >/dev/null 2>&1 || true ;; esac
    done || true
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

seeder_completed() {
  seeder="$(docker compose ps -a -q seeder 2>/dev/null || true)"
  [ -n "$seeder" ] || return 1
  state="$(docker inspect --format '{{.Config.Image}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}}' "$seeder" 2>/dev/null)" || return 1
  IFS='|' read -r s_image s_status s_code s_started <<< "$state"
  [ "$s_image" = "$new" ] && [[ ! ${s_started:0:19} < $attempt_start ]] || return 1
  [ "$s_status" != running ] || { seeder_running=1; return 1; }
  [ "$s_status" = exited ] && [ "$s_code" = 0 ]
}

restart_allowed() {
  if ! seeder_completed; then
    if [ -n "$seeder_running" ]; then
      echo "the seeder of this attempt is still running $new, so a migration is in progress. Do not stop it, restore a dump or deploy again until 'docker compose ps -a seeder' shows it exited." >&2
    else
      echo "the seeder of this attempt did not run $new to exit code 0, so a migration may be half done." >&2
    fi
    return 1
  fi
  after="$(schema_fingerprint)"
  [ -n "$after" ] && [ "$(cat .deploy/healthy-schema 2>/dev/null || true)" = "$after $old" ]
}

finish_failure() {
  rm -f .deploy/previous-image.pending
  prune_dumps || true
  prune_images "${new:-$old}" "$(image_id "$old")" "$(cat .deploy/previous-image-id 2>/dev/null || true)" "$pending_id" "$(running_image_id)" || true
  exit 1
}

fail() {
  echo "deploy failed: $1" >&2
  if [ -z "$new" ] || [ "$new" = "$old" ]; then
    echo "No image switch happened: .env is unchanged and still names ${old:-no image}, and nothing was rolled back." >&2
    echo "Inspect with 'make logs SERVICE=seeder' and 'make logs SERVICE=web', fix the cause (often a value in .env: make env-diff, make env-push), then run the same deploy again." >&2
    finish_failure
  fi
  if [ -n "$old" ]; then
    set_image "$old"
    echo ".env names $old again." >&2
    if restart_allowed; then
      echo "this attempt's seeder finished and the database schema is still the one $old last ran healthy on. Starting $old again." >&2
      if docker compose up -d --remove-orphans && wait_healthy; then
        echo "rolled back automatically to $old: no migration had run" >&2
        finish_failure
      fi
      promote_previous
      echo "the automatic rollback to $old did not become healthy either. Inspect with 'make logs SERVICE=web'; make rollback deploys $old again." >&2
      finish_failure
    fi
  fi
  promote_previous
  [ -e .deploy/last-dump ] || [ -z "$dump_file" ] || printf '%s\n' "$dump_file" > .deploy/last-dump
  echo "The database schema is not the one ${old:-the previous image} last ran healthy on, or it could not be read, or this attempt's seeder did not finish, so nothing was restarted." >&2
  echo "Inspect with 'make logs SERVICE=seeder' and 'make logs SERVICE=web'. Then a person chooses:" >&2
  echo "  - roll forward: merge a fix to dev, or make deploy IMAGE=<fixed image>" >&2
  echo "  - go back: restore $(cat .deploy/last-dump 2>/dev/null || echo 'the pre-deploy dump') into a fresh database (README, Restoring), then make rollback, which deploys $(cat .deploy/previous-image 2>/dev/null || echo 'the previous image')" >&2
  echo "Do not run deploy.sh without an argument (or make deploy) before that decision: it would start old code on a possibly migrated schema." >&2
  finish_failure
}

old="$(env_value OPENPROJECT_IMAGE)"
dump_file=""
pending_id=""
seeder_running=""
mkdir -p .deploy
rm -f .deploy/previous-image.pending

if [ -n "$new" ] && [[ $new == *@sha256:* ]] && docker image inspect --format '{{.Id}}' "$new" >/dev/null 2>&1; then
  echo "$new is already on this server; not pulling"
elif [ -n "$new" ]; then
  OPENPROJECT_IMAGE="$new" docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
else
  docker compose pull || { echo "pull failed; nothing was changed" >&2; exit 1; }
fi
predeploy_dump "${new:-$old}" || { echo "pre-deploy database dump failed; nothing was changed" >&2; exit 1; }
stage_previous
[ -z "$new" ] || set_image "$new"
attempt_start="$(date -u +%Y-%m-%dT%H:%M:%S)"
docker compose up -d --remove-orphans || fail "docker compose up failed (a failed migration in the seeder stops web and worker)"
echo "Waiting for web to become healthy (first boot loads the schema and can take several minutes)..."
wait_healthy || fail "web did not become healthy within 10 minutes"
echo healthy
promote_previous
rm -f .deploy/last-dump
fp="$(schema_fingerprint)"
if [ -n "$fp" ]; then printf '%s %s\n' "$fp" "$(env_value OPENPROJECT_IMAGE)" > .deploy/healthy-schema; else rm -f .deploy/healthy-schema; fi
web="$(web_container)"
prune_images "$(docker inspect --format '{{.Config.Image}}' "$web" 2>/dev/null || true)" "$(running_image_id)" "$(cat .deploy/previous-image-id 2>/dev/null || true)" || true
prune_dumps || true
echo "running: $(docker inspect --format '{{.Config.Image}}' "$web")"
