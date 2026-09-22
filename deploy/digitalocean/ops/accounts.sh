#!/usr/bin/env bash
# User accounts on the server. Anything that reads or prints a password is for a person at a terminal.
. "$(dirname "$0")/common.sh"

confirm_secret() {
  a="$(read_secret "$1")"; b="$(read_secret "Again")"
  [ "$a" = "$b" ] || die "the two entries differ"
  [ -n "$a" ] || die "empty password"
  printf '%s' "$a"
}

cmd_admin_password() {
  require_tty admin-password
  echo "Initial password of the seeded 'admin' account (only valid until it is changed at first login):"
  { grep -E '^OPENPROJECT_SEED__ADMIN__USER__PASSWORD=' "$ENV_FILE" || echo "=(already removed)"; } | cut -d= -f2-
}

cmd_create_admin() {
  require_tty create-admin; require_state DROPLET_IP
  login="${LOGIN:?set LOGIN=<a login that is not guessable>}"; first="${FIRST:?set FIRST=}"; last="${LAST:?set LAST=}"; mail="${MAIL:?set MAIL=}"
  echo "Password rules: 10+ characters with lowercase, uppercase, digit and special character. Save it in your password manager first."
  pw="$(confirm_secret "Password for $login")"
  info "creating $login (about a minute)"
  printf '%s\n' "$pw" | SECRET_STDIN=1 rails_run create_admin.rb "$login" "$first" "$last" "$mail" 2>&1 | redact
}

cmd_reset_password() {
  require_tty reset-password; require_state DROPLET_IP
  login="${LOGIN:?set LOGIN=}"
  pw="$(confirm_secret "New password for $login")"
  printf '%s\n' "$pw" | SECRET_STDIN=1 rails_run reset_password.rb "$login" 2>&1 | redact
}

cmd_unban() { require_state DROPLET_IP; rails_run unban.rb "${LOGIN:?set LOGIN=}" 2>&1 | redact; }

# FILE holds "login,first name,last name,email" lines. Prints one temporary password per user.
cmd_add_users() {
  require_tty add-users; require_state DROPLET_IP
  file="${FILE:?set FILE=<csv with login,first,last,email per line>}"; [ -f "$file" ] || die "$file not found"
  echo "Temporary passwords are printed below. Each user must change theirs at first login."
  remote "cd $REMOTE_DIR && docker compose exec -T web bundle exec rails runner \"\$(cat ops/rails/add_users.rb)\"" < "$file"
}

cmd="${1:?usage: accounts.sh <command>}"; shift || true
case "$cmd" in admin-password) cmd_admin_password;; create-admin) cmd_create_admin;; reset-password) cmd_reset_password;; unban) cmd_unban;; add-users) cmd_add_users;; *) die "unknown command $cmd";; esac
