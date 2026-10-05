#!/usr/bin/env bash
# Continuous deployment from GitHub Actions: the deploy key, the production environment and the pause switches.
OP_STRICT_HOST_KEY="${OP_STRICT_HOST_KEY:-yes}"
. "$(dirname "$0")/common.sh"
REPO="${REPO:-machinekind/openproject}"

ENV_BODY_FILTER='{wait_timer: ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer] | first // 0), prevent_self_review: ([.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review] | first // false), reviewers: ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | {type, id: .reviewer.id}] | if length == 0 then null else . end), can_admins_bypass: (if .can_admins_bypass == false then false else true end), deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}'
NEW_ENV_BODY='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'

gh_get() { # gh_get API_PATH OUT_FILE [gh api args]: 0 when found, 1 on HTTP 404, dies on any other error
  p="$1"; f="$2"; shift 2
  gh api "$p" "$@" > "$f" 2> "$tmp/gh-err" && return 0
  grep -q 'HTTP 404' "$tmp/gh-err" && return 1
  die "gh api $p failed: $(cat "$tmp/gh-err")"
}

branch_policies() {
  gh api "repos/$REPO/environments/production/deployment-branch-policies" --paginate \
    --jq '.branch_policies[] | "\(.id) \(.type // "branch") \(.name)"' > "$tmp/policies" || die "could not list the deployment policies of production"
}

cmd_ci_setup() {
  require_tty ci-setup
  require_state DROPLET_IP HOST
  for t in gh ssh ssh-keygen; do command -v "$t" >/dev/null || die "$t is not installed"; done
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
  ip="$(state_get DROPLET_IP)"; host="$(state_get HOST)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  known="$(ssh-keygen -F "$ip" | grep -v '^#' || true)"
  [ -n "$known" ] || die "no host key for $ip in ~/.ssh/known_hosts. Run 'ssh root@$ip true', and accept only if the fingerprint it shows matches 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' run in the Droplet's Recovery Console in the DigitalOcean control panel."
  printf '%s\n' "$known" > "$tmp/known_hosts"
  info "host keys GitHub Actions will trust for $ip:"
  ssh-keygen -l -f "$tmp/known_hosts"
  printf '%s' "Do they match what 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \$f; done' prints in the Droplet's Recovery Console? Type yes: "
  read -r answer
  [ "$answer" = yes ] || die "stopped; nothing was changed"
  remote "test -x $REMOTE_DIR/ops/remote/ci-deploy.sh && test -x $REMOTE_DIR/ops/remote/ci-key.sh" < /dev/null \
    || die "the server lacks the CI scripts. Run: make -C deploy/digitalocean push"
  ( umask 077; ssh-keygen -q -t ed25519 -N '' -C github-actions-deploy -f "$tmp/key" )
  info "environment 'production' on $REPO, deployable from branch dev only"
  if gh_get "repos/$REPO/environments/production" "$tmp/env-mode" --jq '.deployment_branch_policy | "\(.protected_branches) \(.custom_branch_policies)"'; then
    if [ "$(cat "$tmp/env-mode")" != "false true" ]; then
      info "switching production to custom deployment branch policies; reviewers, wait timer and self-review setting are kept"
      gh_get "repos/$REPO/environments/production" "$tmp/env-body" --jq "$ENV_BODY_FILTER" || die "environment production disappeared; rerun ci-setup"
      gh api -X PUT "repos/$REPO/environments/production" --input "$tmp/env-body" >/dev/null
    fi
  else
    printf '%s' "$NEW_ENV_BODY" > "$tmp/env-body"
    gh api -X PUT "repos/$REPO/environments/production" --input "$tmp/env-body" >/dev/null
  fi
  branch_policies
  while read -r id type name; do
    [ "$type $name" != "branch dev" ] || continue
    info "removing the deployment policy $type '$name' from production"
    gh api -X DELETE "repos/$REPO/environments/production/deployment-branch-policies/$id" >/dev/null
  done < "$tmp/policies"
  grep -q -x '[0-9]* branch dev' "$tmp/policies" || gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" -f name=dev -f type=branch >/dev/null
  branch_policies
  allowed="$(awk '{ print $2, $3 }' "$tmp/policies" | tr '\n' ';')"
  [ "$allowed" = "branch dev;" ] || die "production must allow only branch dev but allows: $allowed. The secret was not set."
  flags="$(gh api "repos/$REPO/environments/production" --jq '.deployment_branch_policy | "\(.protected_branches) \(.custom_branch_policies)"')"
  [ "$flags" = "false true" ] || die "production does not use custom deployment branch policies ($flags). The secret was not set."
  info "environment variables DEPLOY_HOST_IP, DEPLOY_HOST_NAME, DEPLOY_SSH_HOST_KEY"
  gh variable set DEPLOY_HOST_IP --env production --repo "$REPO" --body "$ip" >/dev/null
  gh variable set DEPLOY_HOST_NAME --env production --repo "$REPO" --body "$host" >/dev/null
  gh variable set DEPLOY_SSH_HOST_KEY --env production --repo "$REPO" --body "$known" >/dev/null
  if ! gh_get "repos/$REPO/actions/variables/DEPLOY_PAUSED" "$tmp/variable"; then
    info "repository variable DEPLOY_PAUSED=false"
    gh variable set DEPLOY_PAUSED --repo "$REPO" --body false >/dev/null
  fi
  if gh_get "repos/$REPO/actions/variables/DEPLOY_DISPATCHERS" "$tmp/variable" --jq .value; then
    dispatchers_re='^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$'
    [[ $(cat "$tmp/variable") =~ $dispatchers_re ]] || info "warning: DEPLOY_DISPATCHERS must be GitHub logins separated by commas without spaces, or every manual dispatch is refused. A repository admin fixes it with: gh variable set DEPLOY_DISPATCHERS --repo $REPO --body '<login>,<login>'"
  else
    login="$(gh api user --jq .login)" && [ -n "$login" ] || die "could not read your GitHub login"
    info "repository variable DEPLOY_DISPATCHERS=$login (the logins that may run deploy-production.yml by hand)"
    gh variable set DEPLOY_DISPATCHERS --repo "$REPO" --body "$login" >/dev/null
  fi
  info "environment secret DEPLOY_SSH_KEY"
  gh secret set DEPLOY_SSH_KEY --env production --repo "$REPO" < "$tmp/key" >/dev/null
  info "deploy key on the server, limited to ops/remote/ci-deploy.sh"
  remote "$REMOTE_DIR/ops/remote/ci-key.sh install" < "$tmp/key.pub" \
    || die "installing the deploy key on the server failed. GitHub already holds the new key, so CI deploys fail until you rerun: make -C deploy/digitalocean ci-setup"
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
