#!/usr/bin/env bash
# Everything that talks to the server to run, inspect or verify the stack. Nothing here prints a secret.
. "$(dirname "$0")/common.sh"

# Names of the keys whose values differ between the local and the server's .env. Values are never shown.
# OPENPROJECT_IMAGE is left out: deploys, CI's included, change it only on the server.
env_diff_keys() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist; nothing to compare"
  remote "cd $REMOTE_DIR && [ -f .env ] && grep -E '^[A-Z_]+=' .env | while IFS= read -r l; do k=\${l%%=*}; printf '%s %s\n' \"\$k\" \"\$(printf '%s' \"\${l#*=}\" | sha256sum | cut -c1-16)\"; done || true" | sort > "$CONF_DIR/.remote-keys"
  grep -E '^[A-Z_]+=' "$ENV_FILE" | while IFS= read -r l; do k=${l%%=*}; printf '%s %s\n' "$k" "$(printf '%s' "${l#*=}" | shasum -a 256 | cut -c1-16)"; done | sort > "$CONF_DIR/.local-keys"
  { comm -3 "$CONF_DIR/.local-keys" "$CONF_DIR/.remote-keys" || true; } | awk '$1 != "OPENPROJECT_IMAGE" { print $1 }' | sort -u
  rm -f "$CONF_DIR/.remote-keys" "$CONF_DIR/.local-keys"
}

running_image() { remote "cd $REMOTE_DIR && docker inspect --format '{{.Config.Image}}' \$(docker compose ps -q web)" < /dev/null 2>/dev/null || true; }

cmd_env_diff() {
  require_state DROPLET_IP
  keys="$(env_diff_keys)"
  if [ -z "$keys" ]; then info "local and server .env are identical, apart from OPENPROJECT_IMAGE"; else info "keys that differ (values not shown):"; echo "$keys" | sed 's/^/  /'; fi
  info "OPENPROJECT_IMAGE is not compared; the server owns it. The server runs: $(running_image)"
}

env_upload() { # env_upload keep-image|initial: hands the local .env to ops/remote/env-merge.sh on the server
  ip="$(state_get DROPLET_IP)"
  upload="$(remote "mktemp $REMOTE_DIR/.env.push.XXXXXX" < /dev/null)" || die "could not create a temporary file on the server; the server's .env is unchanged"
  upload_re='^/srv/openproject/\.env\.push\.[A-Za-z0-9]+$'
  [[ $upload =~ $upload_re ]] || die "unexpected temporary file on the server: $upload"
  scp -q $SSH_OPTS "$ENV_FILE" "root@$ip:$upload" || { remote "rm -f $upload" < /dev/null || true; die "copying .env failed; the server's .env is unchanged"; }
  remote "bash -s -- $1 $upload" < "$KIT_DIR/ops/remote/env-merge.sh" >/dev/null || die "the server's .env was not replaced"
}

cmd_env_push() {
  require_state DROPLET_IP
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist; nothing to push"
  env_upload keep-image
  info ".env pushed; OPENPROJECT_IMAGE kept as the server had it"
}

cmd_env_pull() {
  require_state DROPLET_IP
  [ ! -f "$ENV_FILE" ] || cp -p "$ENV_FILE" "$ENV_FILE.bak"
  ( umask 177; scp -q $SSH_OPTS "root@$(state_get DROPLET_IP):$REMOTE_DIR/.env" "$ENV_FILE" ); chmod 600 "$ENV_FILE"
  info "server .env copied to $ENV_FILE (previous version kept as .env.bak)"
}

cmd_push() {
  require_state DROPLET_IP
  ip="$(state_get DROPLET_IP)"
  top="docker-compose.yml Caddyfile bootstrap-db.sh deploy.sh backup.sh"
  info "waiting for first-boot setup"; remote "cloud-init status --wait >/dev/null 2>&1 || true"
  stage="$(remote "mkdir -p $REMOTE_DIR && mktemp -d $REMOTE_DIR/.push-staging.XXXXXX" < /dev/null)" || die "could not create a staging directory on the server"
  stage_re='^/srv/openproject/\.push-staging\.[A-Za-z0-9]+$'
  [[ $stage =~ $stage_re ]] || die "unexpected staging directory on the server: $stage"
  remote "mkdir -p $stage/ops/rails $stage/ops/remote" < /dev/null
  ( cd "$KIT_DIR" && scp -q $SSH_OPTS $top "root@$ip:$stage/" \
    && scp -q $SSH_OPTS ops/rails/*.rb "root@$ip:$stage/ops/rails/" \
    && scp -q $SSH_OPTS ops/remote/*.sh "root@$ip:$stage/ops/remote/" ) \
    || { remote "rm -rf $stage" < /dev/null || true; die "copying the stack files failed; the server's files are unchanged"; }
  remote "bash -s -- $stage $top" < "$KIT_DIR/ops/remote/kit-promote.sh" >/dev/null || die "the server's stack files are unchanged"
  info "stack files pushed"
  if [ ! -f "$ENV_FILE" ]; then
    echo "note: no local $ENV_FILE, so the server's .env was neither compared nor changed."
    return 0
  fi
  server_env="$(remote "if [ -e $REMOTE_DIR/.env ]; then echo present; else echo absent; fi" < /dev/null)" || die "could not check the server's .env; it is unchanged"
  if [ "$server_env" = absent ]; then
    env_upload initial
    info "first .env on the server, with OPENPROJECT_IMAGE=$(env_get_public OPENPROJECT_IMAGE) from the local .env"
    return 0
  fi
  keys="$(env_diff_keys)"
  if [ -n "$keys" ] && [ "${FORCE_ENV:-0}" != "1" ]; then
    echo "note: the server's .env differs from the local one in: $(echo $keys). Not overwritten."
    echo "      'make env-push' makes the local file win, 'make env-pull' makes the server win."
  elif [ -n "$keys" ]; then cmd_env_push; fi
}

cmd_bootstrap() { require_state DROPLET_IP; remote "cd $REMOTE_DIR && ./bootstrap-db.sh" 2>&1 | redact; }

cmd_deploy() {
  require_state DROPLET_IP
  arg=""
  if [ -n "${IMAGE:-}" ]; then
    case "$IMAGE" in *[!A-Za-z0-9._:/@-]*) die "IMAGE may contain only letters, digits and . _ : / @ -";; esac
    arg=" $IMAGE"
  fi
  remote "set -o pipefail; umask 077; cd $REMOTE_DIR && mkdir -p .deploy && ./deploy.sh$arg 2>&1 | tee -p -a .deploy/deploy.log" < /dev/null 2>&1 | redact
  if [ -n "${IMAGE:-}" ]; then
    state_set IMAGE "$IMAGE"
    [ ! -f "$ENV_FILE" ] || env_set OPENPROJECT_IMAGE "$IMAGE"
    info "image set to $IMAGE"
  fi
  running="$(running_image)"
  if [ -z "$running" ]; then info "running image unknown; no release published. Run: make release IMAGE=..."; return 0; fi
  IMAGE="$running" "$KIT_DIR/ops/infra.sh" release || info "release not published; run: make release IMAGE=$running"
}

cmd_rollback() {
  require_state DROPLET_IP
  prev="$(remote "cat $REMOTE_DIR/.deploy/previous-image 2>/dev/null || true")"
  [ -n "$prev" ] || die "the server has no record of a previous image"
  info "rolling back to $prev"
  IMAGE="$prev"
  cmd_deploy
}

cmd_status() {
  require_state DROPLET_IP
  remote "cd $REMOTE_DIR && echo '-- containers' && docker compose ps --format 'table {{.Service}}\t{{.Status}}' && echo '-- host' && uptime && free -m | sed -n '1,3p' && df -h / | tail -n 1 && echo '-- last backup' && { tail -n 1 /var/log/openproject-backup.log 2>/dev/null || echo 'no backup log yet'; } && { ls /etc/cron.d/openproject-backup >/dev/null 2>&1 && echo 'nightly backup: installed' || echo 'nightly backup: NOT installed'; } && echo '-- previous image (make rollback)' && { cat .deploy/previous-image 2>/dev/null || echo none; } && echo '-- restore point of an unresolved failed deploy' && { cat .deploy/last-dump 2>/dev/null || echo none; } && echo '-- image' && docker inspect --format '{{.Config.Image}}' \$(docker compose ps -q web)" 2>&1 | redact
}

cmd_summary() { require_state DROPLET_IP; rails_run summary.rb 2>&1 | redact; }
cmd_logs() { require_state DROPLET_IP; remote "cd $REMOTE_DIR && docker compose logs --no-color --tail ${TAIL:-60} ${SERVICE:-web}" 2>&1 | redact; }

port_open() { # port_open IP PORT SECONDS
  if [ "$(uname -s)" = Darwin ]; then nc -z -G "$3" "$1" "$2" >/dev/null 2>&1
  else timeout "$3" bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; fi
}

# Checks from the outside, the way a visitor or an attacker sees the site.
cmd_verify() {
  require_state HOST DROPLET_IP
  host="$(state_get HOST)"; ip="$(state_get DROPLET_IP)"; fail=0
  R1="--resolve"; R2="$host:443:$ip"; R3="$host:80:$ip"
  expect() { if [ "$2" = "$3" ]; then echo "  ok    $1 ($2)"; else echo "  FAIL  $1: got $2, expected $3"; fail=1; fi; }
  code() { curl -s -o /dev/null -m 15 $R1 "$R2" $R1 "$R3" -w '%{http_code}' "$@" || true; }
  info "https://$host from the outside"
  expect "login page over HTTPS" "$(code -L "https://$host/")" 200
  expect "HTTP redirects to HTTPS" "$(code "http://$host/")" 308
  expect "health endpoints hidden" "$(code "https://$host/health_checks/default")" 404
  expect "API refuses anonymous access" "$(code "https://$host/api/v3/projects")" 401
  expect "MCP endpoint demands credentials" "$(code -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}' "https://$host/mcp")" 401
  expect "registration form closed" "$(curl -s -m 15 $R1 "$R2" "https://$host/login" | grep -c -i 'account/register' || true)" 0
  headers="$(curl -s -I -m 15 $R1 "$R2" "https://$host/login" || true)"
  expect "strict transport security" "$(printf '%s' "$headers" | grep -c -i '^strict-transport-security' || true)" 1
  expect "session cookie is Secure and HttpOnly" "$(printf '%s' "$headers" | grep -i '^set-cookie' | grep -i 'secure' | grep -c -i 'httponly' || true)" 1
  end="$(echo | openssl s_client -connect "$ip:443" -servername "$host" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$end" ]; then echo "  ok    certificate valid until $end"; else echo "  FAIL  no certificate presented"; fail=1; fi
  for p in 22 80 443; do port_open "$ip" "$p" 4 && echo "  ok    port $p open" || { echo "  FAIL  port $p closed"; fail=1; }; done
  for p in 5432 8080 25060; do port_open "$ip" "$p" 3 && { echo "  FAIL  port $p is reachable from the internet"; fail=1; } || echo "  ok    port $p closed"; done
  [ "$fail" -eq 0 ] && info "verify passed" || die "verify failed"
}

cmd_up() { cmd_push; cmd_bootstrap; cmd_deploy; cmd_verify; }

cmd="${1:?usage: stack.sh <command>}"; shift || true
case "$cmd" in env-diff) cmd_env_diff;; env-push) cmd_env_push;; env-pull) cmd_env_pull;; push) cmd_push;; bootstrap) cmd_bootstrap;; deploy) cmd_deploy;; rollback) cmd_rollback;; status) cmd_status;; summary) cmd_summary;; logs) cmd_logs;; verify) cmd_verify;; up) cmd_up;; *) die "unknown command $cmd";; esac
