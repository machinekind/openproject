#!/usr/bin/env bash
# Runs on the server through "bash -s" from ops/stack.sh. Moves the staged kit files into place under the deploy lock,
# so a running deploy never sees a mix of two kit versions.
set -euo pipefail
dir="${OP_REMOTE_DIR:-/srv/openproject}"
stage="${1:-}"
case "$stage" in "$dir"/.push-staging.*) ;; *) echo "error: unexpected staging directory '$stage'" >&2; exit 1 ;; esac
shift
trap 'rm -rf "$stage"' EXIT
cd "$dir"
exec 9>.deploy.lock
flock -n 9 || { echo "error: a deploy is running; nothing was changed. Run make push again when it has finished" >&2; exit 1; }
cd "$stage"
chmod +x ./*.sh ops/remote/*.sh
mkdir -p "$dir/ops/rails" "$dir/ops/remote"
for f in "$@" ops/rails/*.rb ops/remote/*.sh; do mv -f "$f" "$dir/$f"; done
echo "ok: kit promoted"
