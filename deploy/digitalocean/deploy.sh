#!/usr/bin/env bash
# Start or update the stack. To ship a new version: change OPENPROJECT_IMAGE in .env, then run this.
# The seeder container migrates the database before web and worker start. Rollback = previous tag + rerun.
set -euo pipefail
cd "$(dirname "$0")"
docker compose pull
docker compose up -d --remove-orphans
echo "Waiting for web to become healthy (first boot loads the schema and can take several minutes)..."
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q web)" 2>/dev/null || echo starting)"
  if [ "$status" = "healthy" ]; then
    echo "healthy"
    # Pinned tags never become "dangling", so a plain prune would keep every old 2 GB image forever.
    # Remove unused images older than a week; the previous version stays available for rollback until then.
    docker image prune -af --filter "until=168h" >/dev/null
    exit 0
  fi
  sleep 10
done
echo "web did not become healthy; check: docker compose logs seeder web" >&2
exit 1
