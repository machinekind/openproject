#!/usr/bin/env bash
# Runs on the server. Restores the newest dump into the named scratch database and reports what arrived.
# The live database is only read, to compare row counts.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="${1:?scratch database name}"
case "$scratch" in openproject|defaultdb|postgres|"") echo "refusing to restore into '$scratch'" >&2; exit 1;; esac
env_value() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2-; }
live="$(env_value DATABASE_URL)"; live="${live%%&pool=*}"
[ -n "$live" ] || { echo "DATABASE_URL missing in .env" >&2; exit 1; }
case "$live" in */openproject\?*) ;; *) echo "unexpected DATABASE_URL shape" >&2; exit 1;; esac
export PGLIVE="$live"
PGSCRATCH="$(printf '%s' "$live" | sed -E "s#/openproject\?#/${scratch}?#")"
export PGSCRATCH
dump="$(ls -1t "${BACKUP_DIR:-/var/backups/openproject}"/db-*.dump 2>/dev/null | head -n 1)"
[ -n "$dump" ] || { echo "no dump found; run ./backup.sh first" >&2; exit 1; }
echo "restoring $(basename "$dump") ($(du -h "$dump" | cut -f1)) into $scratch"
run_pg() { docker run --rm -i ${OP_DOCKER_RUN_ARGS:-} -e PGLIVE -e PGSCRATCH postgres:17 sh -c "$1"; }
run_pg 'psql "$PGSCRATCH" -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm" -c "CREATE EXTENSION IF NOT EXISTS btree_gist" -c "CREATE EXTENSION IF NOT EXISTS unaccent"' < /dev/null
run_pg 'pg_restore --no-owner --single-transaction --exit-on-error -d "$PGSCRATCH"' < "$dump"
q="SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM projects) AS projects, (SELECT count(*) FROM work_packages) AS work_packages, (SELECT count(*) FROM schema_migrations) AS migrations"
export Q="$q"
echo "restored: $(docker run --rm ${OP_DOCKER_RUN_ARGS:-} -e PGSCRATCH -e Q postgres:17 sh -c 'psql "$PGSCRATCH" -At -F " " -c "$Q"' < /dev/null)"
echo "live now: $(docker run --rm ${OP_DOCKER_RUN_ARGS:-} -e PGLIVE -e Q postgres:17 sh -c 'psql "$PGLIVE" -At -F " " -c "$Q"' < /dev/null)"
echo "columns: users projects work_packages migrations. Restored counts may trail live ones by whatever changed since the dump."
echo "RESTORE DRILL PASSED"
