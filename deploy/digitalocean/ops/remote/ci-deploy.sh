#!/usr/bin/env bash
# Forced command for the GitHub Actions deploy key (make ci-setup installs it). It ignores its arguments and accepts
# only the verbs below from SSH_ORIGINAL_COMMAND, so the key can deploy fork images by digest and nothing else.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
image_re='^ghcr\.io/machinekind/openproject:[A-Za-z0-9._-]{1,128}@sha256:[0-9a-f]{64}$'
command_re='^[a-z]+( [A-Za-z0-9._:/@-]+)?$'
refuse() { echo "refused: $1" >&2; exit 2; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
[[ $cmd =~ $command_re ]] || refuse "malformed command"
verb="${cmd%% *}"
arg=""
[ "$verb" = "$cmd" ] || arg="${cmd#* }"
logger -t openproject-ci-deploy -- "$cmd" 2>/dev/null || true

case "$verb" in
  deploy)
    [[ $arg =~ $image_re ]] || refuse "deploy needs ghcr.io/machinekind/openproject:<tag>@sha256:<digest>"
    [ ! -e DEPLOY_PAUSED ] || refuse "deploys are paused on this server; make -C deploy/digitalocean deploy-unhold lifts that"
    mkdir -p .deploy
    ./deploy.sh "$arg" 2>&1 | tee -p -a .deploy/ci-deploy.log
    ;;
  status)
    [ -z "$arg" ] || refuse "status takes no argument"
    web="$(docker compose ps -q web)"
    [ -n "$web" ] || { echo "web not running"; exit 1; }
    docker inspect --format '{{.Config.Image}}' "$web"
    ;;
  version)
    [ -z "$arg" ] || refuse "version takes no argument"
    sha256sum deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh
    ;;
  *)
    refuse "$verb"
    ;;
esac
