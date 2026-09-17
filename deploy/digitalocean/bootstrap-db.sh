#!/usr/bin/env bash
# One-time: create the PostgreSQL extensions OpenProject needs, as the managed database's admin user.
# OpenProject's schema file asks for them "WITH SCHEMA pg_catalog", which a managed (non-superuser)
# admin may not be allowed to do. Creating them first makes those statements no-ops (IF NOT EXISTS).
set -euo pipefail
cd "$(dirname "$0")"
# Read single values instead of sourcing .env: a database URL contains "&", which bash would interpret.
env_value() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2-; }
DATABASE_URL="$(env_value DATABASE_URL)"
URL="${DATABASE_URL%%&pool=*}"
docker run --rm postgres:17 psql "$URL" -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' \
  -c 'CREATE EXTENSION IF NOT EXISTS btree_gist;' \
  -c 'CREATE EXTENSION IF NOT EXISTS unaccent;' \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_trgm','btree_gist','unaccent');"
