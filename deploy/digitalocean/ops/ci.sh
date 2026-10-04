#!/usr/bin/env bash
# Continuous deployment from GitHub Actions: the deploy key, the production environment and the pause switches.
OP_STRICT_HOST_KEY="${OP_STRICT_HOST_KEY:-yes}"
. "$(dirname "$0")/common.sh"
REPO="${REPO:-machinekind/openproject}"

cmd_ci_setup() {
  require_tty ci-setup
  require_state DROPLET_IP HOST
  for t in gh ssh ssh-keygen; do command -v "$t" >/dev/null || die "$t is not installed"; done
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
  ip="$(state_get DROPLET_IP)"; host="$(state_get HOST)"
  known="$(ssh-keygen -F "$ip" | grep -v '^#' || true)"
  [ -n "$known" ] || die "no host key for $ip in ~/.ssh/known_hosts. Run 'make status' once and compare the fingerprint with the DigitalOcean console."
  remote "test -x $REMOTE_DIR/ops/remote/ci-deploy.sh && test -x $REMOTE_DIR/ops/remote/ci-key.sh" < /dev/null \
    || die "the server lacks the CI scripts. Run: make -C deploy/digitalocean push"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ( umask 077; ssh-keygen -q -t ed25519 -N '' -C github-actions-deploy -f "$tmp/key" )
  info "environment 'production' on $REPO, deployable from dev only"
  printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
    | gh api -X PUT "repos/$REPO/environments/production" --input - >/dev/null
  policy="$(gh api "repos/$REPO/environments/production/deployment-branch-policies" --jq '.branch_policies[] | select(.name == "dev" and .type == "branch") | .id')"
  [ -n "$policy" ] || gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" -f name=dev -f type=branch >/dev/null
  info "environment secret DEPLOY_SSH_KEY"
  gh secret set DEPLOY_SSH_KEY --env production --repo "$REPO" < "$tmp/key" >/dev/null
  info "environment variables DEPLOY_HOST_IP, DEPLOY_HOST_NAME, DEPLOY_SSH_HOST_KEY"
  gh variable set DEPLOY_HOST_IP --env production --repo "$REPO" --body "$ip" >/dev/null
  gh variable set DEPLOY_HOST_NAME --env production --repo "$REPO" --body "$host" >/dev/null
  gh variable set DEPLOY_SSH_HOST_KEY --env production --repo "$REPO" --body "$known" >/dev/null
  if ! gh variable get DEPLOY_PAUSED --repo "$REPO" >/dev/null 2>&1; then
    info "repository variable DEPLOY_PAUSED=false"
    gh variable set DEPLOY_PAUSED --repo "$REPO" --body false >/dev/null
  fi
  info "deploy key on the server, limited to ops/remote/ci-deploy.sh"
  remote "$REMOTE_DIR/ops/remote/ci-key.sh install" < "$tmp/key.pub"
  rm -rf "$tmp"
  trap - EXIT
  info "done. The private key existed only in a temporary directory, which is deleted. Rerun this target to rotate the key."
  info "if any step failed, rerunning 'make -C deploy/digitalocean ci-setup' is safe and rotates the key."
}

cmd_ci_revoke() {
  require_state DROPLET_IP
  remote "$REMOTE_DIR/ops/remote/ci-key.sh remove" < /dev/null
  info "the server no longer accepts the GitHub Actions deploy key"
  echo "To delete the secret as well, a person runs: gh secret delete DEPLOY_SSH_KEY --env production --repo $REPO"
}

cmd_ci_pause() {
  require_tty ci-pause
  gh variable set DEPLOY_PAUSED --repo "$REPO" --body true >/dev/null
  info "GitHub Actions will not deploy until: make ci-resume"
}

cmd_ci_resume() {
  require_tty ci-resume
  gh variable set DEPLOY_PAUSED --repo "$REPO" --body false >/dev/null
  info "GitHub Actions deploys again on the next push to dev"
}

cmd_deploy_hold() { require_state DROPLET_IP; remote "touch $REMOTE_DIR/DEPLOY_PAUSED" < /dev/null; info "the server refuses CI deploys until: make deploy-unhold"; }
cmd_deploy_unhold() { require_state DROPLET_IP; remote "rm -f $REMOTE_DIR/DEPLOY_PAUSED" < /dev/null; info "the server accepts CI deploys again"; }

cmd="${1:?usage: ci.sh <ci-setup|ci-revoke|ci-pause|ci-resume|deploy-hold|deploy-unhold>}"; shift || true
case "$cmd" in ci-setup) cmd_ci_setup;; ci-revoke) cmd_ci_revoke;; ci-pause) cmd_ci_pause;; ci-resume) cmd_ci_resume;; deploy-hold) cmd_deploy_hold;; deploy-unhold) cmd_deploy_unhold;; *) die "unknown command $cmd";; esac
