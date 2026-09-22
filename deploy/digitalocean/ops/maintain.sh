#!/usr/bin/env bash
# Hardening, roles, backups, mail, registry login, MCP registration, restore drill.
. "$(dirname "$0")/common.sh"

# Set one key in the server's .env. The line travels over stdin, so a secret value never appears in a command line.
remote_env_set() {
  printf '%s=%s\n' "$1" "$2" | remote "cd $REMOTE_DIR && umask 177 && { grep -v '^$1=' .env || true; } > .env.tmp && cat >> .env.tmp && mv .env.tmp .env"
}
remote_env_unset() { remote "cd $REMOTE_DIR && umask 177 && { grep -v '^$1=' .env || true; } > .env.tmp && mv .env.tmp .env"; }

cmd_harden() {
  require_state DROPLET_IP
  rails_run harden.rb 2>&1 | redact
  remote_env_unset OPENPROJECT_SEED__ADMIN__USER__PASSWORD
  if [ -f "$ENV_FILE" ]; then ( umask 177; { grep -v '^OPENPROJECT_SEED__ADMIN__USER__PASSWORD=' "$ENV_FILE" || true; } > "$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE" ); fi
  info "seed password removed from the server and the local .env"
  env_is_set SECRET_KEY_BASE && echo "reminder: keep SECRET_KEY_BASE in a password manager (a person can read it with: grep '^SECRET_KEY_BASE=' $ENV_FILE)"
}

cmd_roles() { require_state DROPLET_IP; rails_run roles.rb "${ROLE:-Moderator}" 2>&1 | redact; }

cmd_backup_now() {
  require_state DROPLET_IP
  remote "cd $REMOTE_DIR && ./backup.sh && chmod 600 /var/backups/openproject/* && ls -lh /var/backups/openproject | tail -n +2" 2>&1 | redact
}
cmd_backup_install() {
  require_state DROPLET_IP
  remote "echo '15 3 * * * root $REMOTE_DIR/backup.sh >> /var/log/openproject-backup.log 2>&1' > /etc/cron.d/openproject-backup && chmod 644 /etc/cron.d/openproject-backup && echo 'nightly backup installed: 03:15 server time'"
}
cmd_backup_remote() {
  require_tty backup-remote; require_state DROPLET_IP
  echo "Create two remotes: the storage itself (for example 'offsite'), then a 'crypt' remote on top of it (for example 'offsite-crypt')."
  echo "Save the crypt password in your password manager. Afterwards run: make backup-remote-set REMOTE=offsite-crypt:"
  remote_tty "rclone config"
}
cmd_backup_remote_set() {
  require_state DROPLET_IP; r="${REMOTE:?set REMOTE=<rclone remote>, for example REMOTE=offsite-crypt:}"
  remote "rclone lsd '$r' >/dev/null 2>&1 || rclone mkdir '$r'" || die "the server cannot reach rclone remote $r. Run 'make backup-remote' first."
  remote_env_set RCLONE_REMOTE "$r"; [ ! -f "$ENV_FILE" ] || env_set RCLONE_REMOTE "$r"
  info "backups will be copied to $r. Test with: make backup-now"
}

cmd_smtp_test() {
  require_state DROPLET_IP; h="${SMTP_HOST:?set SMTP_HOST=}"; p="${SMTP_PORT:-2525}"
  remote "timeout 6 bash -c '</dev/tcp/$h/$p' 2>/dev/null && echo 'open: $h:$p is reachable from the server' || echo 'blocked: $h:$p is not reachable (DigitalOcean blocks 25, 465 and 587 for most accounts; try 2525)'"
}
cmd_smtp_configure() {
  require_tty smtp-configure; require_state DROPLET_IP
  h="${SMTP_HOST:?set SMTP_HOST=}"; p="${SMTP_PORT:-2525}"; u="${SMTP_USER:?set SMTP_USER=}"; from="${MAIL_FROM:?set MAIL_FROM=}"; dom="${SMTP_DOMAIN:-${from##*@}}"
  pw="$(read_secret "SMTP password for $u")"; [ -n "$pw" ] || die "empty password"
  for kv in "OPENPROJECT_EMAIL__DELIVERY__METHOD=smtp" "OPENPROJECT_SMTP__ADDRESS=$h" "OPENPROJECT_SMTP__PORT=$p" "OPENPROJECT_SMTP__DOMAIN=$dom" "OPENPROJECT_SMTP__USER__NAME=$u" "OPENPROJECT_SMTP__AUTHENTICATION=plain" "OPENPROJECT_SMTP__ENABLE__STARTTLS__AUTO=true" "OPENPROJECT_MAIL__FROM=$from"; do
    remote_env_set "${kv%%=*}" "${kv#*=}"; env_set "${kv%%=*}" "${kv#*=}"
  done
  remote_env_set OPENPROJECT_SMTP__PASSWORD "$pw"; env_set OPENPROJECT_SMTP__PASSWORD "$pw"
  info "mail settings stored. Apply them with: make deploy. Then send a test mail from Administration, Emails and notifications."
}

cmd_ghcr_login() {
  require_tty ghcr-login; require_state DROPLET_IP
  echo "Use a classic token with only the read:packages scope. Paste it at the hidden password prompt."
  remote_tty "docker login ghcr.io -u '${GH_USER:?set GH_USER=<your GitHub login>}'"
}
cmd_ghcr_logout() { require_state DROPLET_IP; remote "docker logout ghcr.io"; }

cmd_mcp_register() {
  require_tty mcp-register; require_state HOST
  name="${MCP_NAME:-openproject-prod}"; command -v claude >/dev/null || die "the claude CLI is not installed"
  echo "Create an API token under Account settings, Access tokens. Prefer a dedicated non-admin account for agent work."
  token="$(read_secret "API token")"; [ -n "$token" ] || die "empty token"
  claude mcp remove "$name" >/dev/null 2>&1 || true
  claude mcp add --transport http "$name" "https://$(state_get HOST)/mcp" --header "Authorization: Basic $(printf 'apikey:%s' "$token" | base64 | tr -d '\n')" >/dev/null
  info "registered $name. Run /mcp in Claude Code to connect."
}

# Restore the newest portable dump into a scratch database, count what arrived, then drop the scratch database.
cmd_restore_drill() {
  require_state DROPLET_IP DB_ID
  scratch="openproject_restore_drill"
  cleanup() { doctl databases db delete "$(state_get DB_ID)" "$scratch" --force >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  cleanup
  info "creating scratch database $scratch"
  doctl databases db create "$(state_get DB_ID)" "$scratch" >/dev/null
  remote "cd $REMOTE_DIR && ./ops/remote/restore-drill.sh $scratch" 2>&1 | redact
  info "scratch database dropped"
}

cmd="${1:?usage: maintain.sh <command>}"; shift || true
case "$cmd" in harden) cmd_harden;; roles) cmd_roles;; backup-now) cmd_backup_now;; backup-install) cmd_backup_install;; backup-remote) cmd_backup_remote;; backup-remote-set) cmd_backup_remote_set;; smtp-test) cmd_smtp_test;; smtp-configure) cmd_smtp_configure;; ghcr-login) cmd_ghcr_login;; ghcr-logout) cmd_ghcr_logout;; mcp-register) cmd_mcp_register;; restore-drill) cmd_restore_drill;; *) die "unknown command $cmd";; esac
