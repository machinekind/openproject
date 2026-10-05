#!/usr/bin/env bash
# Forced command for the GitHub Actions deploy key (make ci-setup installs it). It ignores its arguments and accepts
# only the verbs below from SSH_ORIGINAL_COMMAND, so the key can deploy fork images by digest and nothing else.
# "deploy <image> <kit sha256>": deploy.sh refuses when the kit changed after the runner's version check.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
image_re='^ghcr\.io/machinekind/openproject:[A-Za-z0-9._-]{1,128}@sha256:[0-9a-f]{64}$'
command_re='^[a-z]+( [A-Za-z0-9._:/@-]+)?( [0-9a-f]{64})?$'
kit_re='^[0-9a-f]{64}$'
refuse() { echo "refused: $1" >&2; exit 2; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
[[ $cmd =~ $command_re ]] || refuse "malformed command"
verb="${cmd%% *}"
arg=""
kit=""
[ "$verb" = "$cmd" ] || arg="${cmd#* }"
case "$arg" in *" "*) kit="${arg#* }"; arg="${arg%% *}" ;; esac
logger -t openproject-ci-deploy -- "$cmd" 2>/dev/null || true

case "$verb" in
  deploy)
    [[ $arg =~ $image_re && $kit =~ $kit_re ]] || refuse "deploy needs ghcr.io/machinekind/openproject:<tag>@sha256:<digest> <kit sha256>"
    [ ! -e DEPLOY_PAUSED ] || refuse "deploys are paused on this server; make -C deploy/digitalocean deploy-unhold lifts that"
    mkdir -p .deploy
    EXPECTED_KIT_SHA256="$kit" ./deploy.sh "$arg" 2>&1 | tee -p -a .deploy/ci-deploy.log
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
