#!/usr/bin/env bash
# Runs on the server through "bash -s" from ops/stack.sh. Replaces .env with an uploaded file under the deploy lock.
#   keep-image: the uploaded keys win, except OPENPROJECT_IMAGE, which stays as the server's .env has it.
#   initial:    the uploaded file becomes the first .env; refused when the server has one.
set -euo pipefail
umask 077
mode="${1:-}"
upload="${2:-}"
cd "${OP_REMOTE_DIR:-/srv/openproject}"
refuse() { rm -f "$upload" .env.new; echo "error: $1; the server's .env is unchanged" >&2; exit 1; }
case "$upload" in "$PWD"/.env.push.*) ;; *) echo "error: unexpected upload path '$upload'" >&2; exit 1 ;; esac
[ -f "$upload" ] || refuse "the uploaded file $upload is missing"
exec 9>.deploy.lock
flock -n 9 || refuse "a deploy is running; try again when it has finished"
trap 'rm -f .env.new' EXIT
image_line_re='^OPENPROJECT_IMAGE=[A-Za-z0-9._/:@-]+$'
case "$mode" in
  initial)
    [ ! -e .env ] || refuse "the server has a .env already; compare with make env-diff, then make env-push"
    grep -q -E "$image_line_re" "$upload" || refuse "the local .env names no OPENPROJECT_IMAGE; run make configure HOST=<host> IMAGE=<image> first"
    chmod 600 "$upload"
    mv -f "$upload" .env
    ;;
  keep-image)
    [ -f .env ] && [ -r .env ] || refuse "the server has no readable .env, so its OPENPROJECT_IMAGE is unknown"
    line="$(grep -E "$image_line_re" .env | tail -n 1 || true)"
    [ -n "$line" ] || refuse "the server's .env has no valid OPENPROJECT_IMAGE line, and the local one is never used instead; deploy an image first with make deploy IMAGE=<image>"
    { grep -v -E '^OPENPROJECT_IMAGE=' "$upload" || true; printf '%s\n' "$line"; } > .env.new
    chmod 600 .env.new
    mv -f .env.new .env
    rm -f "$upload"
    ;;
  *) refuse "unknown mode '$mode'" ;;
esac
echo "ok: $mode"
