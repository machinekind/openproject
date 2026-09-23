#!/usr/bin/env bash
# Shared helpers for the ops scripts. Sourced, never executed.
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

CONF_DIR="${OP_CONF_DIR:-$HOME/.config/openproject-do}"
ENV_FILE="$CONF_DIR/.env"          # secrets; never print its values
STATE_FILE="$CONF_DIR/state"       # non-secret facts about the deployment
# shellcheck disable=SC2034  # used by the scripts that source this file
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR=/srv/openproject

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Targets that spend money, prompt for a secret, or print one must be run by a person.
# An agent's shell has no terminal, so this check is what keeps those targets out of its reach.
require_tty() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "'$1' handles a secret or spends money. A person must run it in a terminal: make -C deploy/digitalocean $1"
  fi
}

state_get() { [ -f "$STATE_FILE" ] && { grep -E "^$1=" "$STATE_FILE" || true; } | tail -n 1 | cut -d= -f2-; }
state_set() {
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"; touch "$STATE_FILE"
  { grep -v -E "^$1=" "$STATE_FILE" || true; } > "$STATE_FILE.tmp"
  printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
require_state() {
  for key in "$@"; do
    [ -n "$(state_get "$key")" ] || die "$key is unknown. Run 'make provision' for a new deployment or 'make adopt' for an existing one."
  done
}

# Set KEY=VALUE in the local secrets file without ever displaying the file.
env_set() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run 'make provision' first."
  ( umask 177
    { grep -v -E "^$1=" "$ENV_FILE" || true; } > "$ENV_FILE.tmp"
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE" )
  chmod 600 "$ENV_FILE"
}
# True when KEY has a non-empty value. Reveals nothing else.
env_is_set() { [ -f "$ENV_FILE" ] && grep -q -E "^$1=.+" "$ENV_FILE"; }
# Only for keys that are not secret (host name, image).
env_get_public() {
  case "$1" in OPENPROJECT_HOST__NAME|OPENPROJECT_IMAGE|OPENPROJECT_SEED__ADMIN__USER__MAIL|RCLONE_REMOTE) ;; *) die "refusing to read $1 from the secrets file";; esac
  { grep -E "^$1=" "$ENV_FILE" || true; } | tail -n 1 | cut -d= -f2-
}

semver_valid() { printf '%s\n' "$1" | grep -q -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; }
latest_semver_release() {
  gh release list --repo "$1" --limit 100 --json tagName -q '.[].tagName' \
    | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1
}
bump_semver() {
  [ -n "$1" ] || { echo 1.0.0; return 0; }
  printf '%s\n' "$1" | awk -F. -v bump="$2" '{
    if (bump == "major") printf "%d.0.0\n", $1 + 1
    else if (bump == "minor") printf "%d.%d.0\n", $1, $2 + 1
    else if (bump == "patch") printf "%d.%d.%d\n", $1, $2, $3 + 1
    else exit 1 }' || die "BUMP must be major, minor or patch"
}

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
remote()     { ssh $SSH_OPTS "root@$(state_get DROPLET_IP)" "$@"; }
remote_tty() { ssh -t -o StrictHostKeyChecking=accept-new "root@$(state_get DROPLET_IP)" "$@"; }

# Run a Ruby file from ops/rails inside the web container. Arguments are passed through.
# When SECRET_STDIN=1, the first line of stdin becomes $OP_SECRET inside the container,
# so a password never appears in a command line, locally or on the server.
rails_run() {
  script="$1"; shift
  args=""; for a in "$@"; do args="$args $(printf '%q' "$a")"; done
  if [ "${SECRET_STDIN:-0}" = "1" ]; then
    remote "cd $REMOTE_DIR && IFS= read -r OP_SECRET && export OP_SECRET && docker compose exec -T -e OP_SECRET web bundle exec rails runner \"\$(cat ops/rails/$script)\"$args"
  else
    remote "cd $REMOTE_DIR && docker compose exec -T web bundle exec rails runner \"\$(cat ops/rails/$script)\"$args" < /dev/null
  fi
}

# Mask anything that looks like a credential before output reaches a terminal or an agent.
redact() {
  sed -E \
    -e 's#(postgres(ql)?://[^:/ ]+:)[^@ ]+@#\1***@#g' \
    -e 's#(([A-Z_]*(PASSWORD|SECRET|TOKEN|KEY_BASE|API_KEY)[A-Z_]*)=)[^ ]+#\1***#g' \
    -e 's#(ghp_|gho_|dop_v1_|opapi-)[A-Za-z0-9_-]+#\1***#g' \
    -e 's#(Authorization: (Basic|Bearer) )[A-Za-z0-9+/=._-]+#\1***#g'
}

read_secret() { # read_secret "Prompt" -> echoes the secret on stdout (caller captures it)
  printf '%s: ' "$1" >&2; stty -echo; IFS= read -r value; stty echo; printf '\n' >&2; printf '%s' "$value"
}
