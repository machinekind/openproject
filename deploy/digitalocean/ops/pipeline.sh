#!/usr/bin/env bash
# Steps of .github/workflows/deploy-production.yml that run on the GitHub runner. Nothing here prints a secret.
. "$(dirname "$0")/common.sh"

IMAGE_RE='^ghcr\.io/machinekind/openproject:[A-Za-z0-9._-]{1,128}@sha256:[0-9a-f]{64}$'
SHA_RE='^[0-9a-f]{40}$'
DISPATCHERS_RE='^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$'
SRC_DIR="${OP_SOURCE_DIR:-$(cd "$KIT_DIR/../.." && pwd)}"
KIT_FILES="deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh"

output() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; }
valid_image() {
  case "$1" in ghcr.io/machinekind/openproject:*@sha256:*) ;; *) return 1 ;; esac
  [[ $1 =~ $IMAGE_RE ]]
}

require_dispatcher() {
  actor="${ACTOR:-}"; list="${DEPLOY_DISPATCHERS:-}"
  how="a repository admin sets it with: gh variable set DEPLOY_DISPATCHERS --repo ${REPO:-machinekind/openproject} --body '<login>,<login>'"
  [[ $list =~ $DISPATCHERS_RE ]] || die "the repository variable DEPLOY_DISPATCHERS is missing, empty or not GitHub logins separated by commas without spaces, so no one may run this workflow by hand; $how"
  if [ -z "$actor" ] || ! printf '%s\n' "$list" | tr ',' '\n' | grep -q -i -x -F -- "$actor"; then
    die "${actor:-an unknown actor} may not run this workflow by hand. Only the logins in the repository variable DEPLOY_DISPATCHERS may; $how"
  fi
}

cmd_gate() {
  [ "${EVENT_NAME:-}" != workflow_dispatch ] || require_dispatcher
  if [ "${GITHUB_RUN_ATTEMPT:-1}" != 1 ] && [ -z "${INPUT_IMAGE:-}" ]; then
    repo="${REPO:?set REPO}"; sha="${SHA:?set SHA}"
    tip="$(gh api "repos/$repo/git/ref/heads/dev" --jq .object.sha)" && [[ $tip =~ $SHA_RE ]] || die "could not read the tip of dev"
    [ "$tip" = "$sha" ] || die "dev has moved on to $tip, so this re-run of $sha stops here. Re-runs deploy only the newest commit on dev: let the run for $tip deploy, or dispatch again."
  fi
  info "this run may continue"
}

minor_requested() { # minor_requested REPO SHA BASE_SHA: a pull request merged into dev after BASE_SHA, up to SHA, has the label release:minor
  if ! git -C "$SRC_DIR" merge-base --is-ancestor "$2" "$3" 2>/dev/null; then
    labels="$(gh api "repos/$1/commits/$2/pulls" --jq '.[].labels[].name')" || die "could not read the pull requests of $2"
    if printf '%s\n' "$labels" | grep -x -F 'release:minor' >/dev/null; then return 0; fi
  fi
  merges="$(gh pr list --repo "$1" --base dev --state merged --label release:minor --limit 100 --json mergeCommit --jq '.[].mergeCommit.oid // empty')" \
    || die "could not list the merged pull requests labelled release:minor"
  for m in $merges; do
    [[ $m =~ $SHA_RE ]] || continue
    if git -C "$SRC_DIR" merge-base --is-ancestor "$m" "$2" 2>/dev/null && ! git -C "$SRC_DIR" merge-base --is-ancestor "$m" "$3" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

cmd_next_version() {
  repo="${REPO:?set REPO}"; sha="${SHA:?set SHA}"
  [[ $sha =~ $SHA_RE ]] || die "SHA must be a full commit SHA"
  [ "${EVENT_NAME:-}" != workflow_dispatch ] || require_dispatcher
  case "${BUMP:-}" in
    ""|patch) bump="patch" ;;
    minor) bump="minor" ;;
    major)
      [ "${EVENT_NAME:-}" = workflow_dispatch ] || die "BUMP=major is accepted only from workflow_dispatch: gh workflow run deploy-production.yml --repo $repo --ref dev -f bump=major"
      bump="major" ;;
    *) die "BUMP must be patch, minor or major" ;;
  esac
  names="$(release_and_tag_names "$repo")" || die "could not list the releases and tags of $repo"
  base="$(printf '%s\n' "$names" | max_final_semver)"
  [ -n "$base" ] || die "$repo has no final release yet. A person publishes the baseline first: make -C deploy/digitalocean release IMAGE=<running image> TAG=<version> SHA=<its commit>"
  base_sha="$(gh api "repos/$repo/commits/$base" --jq .sha)" || die "could not resolve release $base to a commit"
  [ "$base_sha" != "$sha" ] || die "$sha is already released as $base; nothing to build. To redeploy it, a login in DEPLOY_DISPATCHERS dispatches with -f image=<the image in the notes of release $base>"
  git -C "$SRC_DIR" merge-base --is-ancestor "$base_sha" "$sha" \
    || die "release $base ($base_sha) is not an ancestor of $sha. Either dev has moved past this run's commit (do not re-run it; the newest run deploys), or $base was built from a commit that is not on dev (merge that commit into dev with a merge commit, then push). A baseline or manual release must be built from a commit on dev."
  if [ "$bump" = patch ] && minor_requested "$repo" "$sha" "$base_sha"; then bump=minor; fi
  migrations="$(git -C "$SRC_DIR" diff --no-renames --diff-filter=A --name-only "$base_sha" "$sha" -- db/migrate ':(glob)modules/*/db/migrate/**')" \
    || die "could not compare $base with $sha; the checkout needs fetch-depth: 0"
  if [ -n "$migrations" ]; then
    count="$(printf '%s\n' "$migrations" | wc -l | tr -d ' ')"
    summary "### $count new migration(s) since $base"
    summary ""
    printf '%s\n' "$migrations" | while IFS= read -r m; do summary "- \`$m\`"; done
    [ "$bump" != patch ] || die "$count new migration(s) since $base, and production migrates on deploy. Add the label release:minor to a pull request merged since $base and re-run this workflow while $sha is still the newest commit on dev, or run it by hand with bump=minor."
  fi
  tag="$(bump_semver "$base" "$bump")"
  semver_valid "$tag" || die "computed an invalid version: $tag"
  upstream=""
  [ ! -f "$SRC_DIR/lib/open_project/version.rb" ] || upstream="$(version_rb_triplet < "$SRC_DIR/lib/open_project/version.rb")"
  output tag "$tag"
  output upstream "$upstream"
  summary "Version \`$tag\` ($bump after $base), upstream OpenProject ${upstream:-unknown}"
  info "next version: $tag ($bump after $base)"
}

cmd_resolve_image() {
  [ "${EVENT_NAME:-}" != workflow_dispatch ] || require_dispatcher
  if [ -n "${INPUT_IMAGE:-}" ]; then
    [ "${EVENT_NAME:-}" = workflow_dispatch ] || die "an image input is accepted only from workflow_dispatch"
    image="$INPUT_IMAGE"
  else
    image="${BUILT_IMAGE:-}"
    repo="${REPO:?set REPO}"; sha="${SHA:?set SHA}"
    tip="$(gh api "repos/$repo/git/ref/heads/dev" --jq .object.sha)" && [[ $tip =~ $SHA_RE ]] || die "could not read the tip of dev"
    if [ "$tip" != "$sha" ]; then
      if [ "${EVENT_NAME:-}" != push ] || [ "${GITHUB_RUN_ATTEMPT:-1}" != 1 ]; then
        die "dev has moved on to $tip, so this run's commit $sha is not deployed. Re-runs and dispatches deploy only the newest commit on dev: let the run for $tip deploy, or dispatch again."
      fi
      status="$(gh api "repos/$repo/compare/$sha...$tip" --jq .status)" || die "could not compare $sha with the tip of dev"
      [ "$status" = ahead ] || die "$sha is not on dev any more (dev is at $tip, compare status '$status'), so it is not deployed."
      info "dev is already at $tip; this run deploys $sha first and the run for $tip follows"
    fi
  fi
  valid_image "$image" || die "the image must be ghcr.io/machinekind/openproject:<tag>@sha256:<64 hex digits>"
  if [ -n "${DEPLOY_HOST_NAME+set}" ]; then
    [ -n "$DEPLOY_HOST_NAME" ] || die "DEPLOY_HOST_NAME is empty; run make ci-setup"
    output host "$DEPLOY_HOST_NAME"
  fi
  output image "$image"
  info "image: $image"
}

cmd_remote_deploy() {
  : "${DEPLOY_SSH_KEY:?is empty. Run make ci-setup, unless this run was triggered by a bot (GitHub gives runs triggered by a bot no secrets, and a re-run keeps that): then dispatch deploy-production.yml as a login in DEPLOY_DISPATCHERS}" "${DEPLOY_HOST_IP:?is empty; run make ci-setup}" "${DEPLOY_SSH_HOST_KEY:?is empty; run make ci-setup}" "${IMAGE:?set IMAGE}"
  valid_image "$IMAGE" || die "refusing image $IMAGE"
  ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
  [[ $DEPLOY_HOST_IP =~ $ip_re ]] || die "DEPLOY_HOST_IP must be an IPv4 address"
  work="${RUNNER_TEMP:?set RUNNER_TEMP}/deploy-ssh"
  rm -rf "$work"
  ( umask 077; mkdir -p "$work"; printf '%s\n' "$DEPLOY_SSH_HOST_KEY" > "$work/known_hosts" )
  eval "$(ssh-agent -s)" >/dev/null
  trap 'ssh-agent -k >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
  printf '%s\n' "$DEPLOY_SSH_KEY" | ssh-add -q - >/dev/null 2>&1 || die "the DEPLOY_SSH_KEY secret is not a usable private key; run make ci-setup"
  unset DEPLOY_SSH_KEY
  ssh-add -L > "$work/id.pub"
  set -- -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$work/known_hosts" -o GlobalKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -i "$work/id.pub" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "root@$DEPLOY_HOST_IP"
  remote_kit="$(ssh "$@" version)" || die "the server did not answer the version check. Is ci-deploy.sh installed (make push) and the key current (make ci-setup)?"
  local_kit="$(cd "$KIT_DIR" && sha256sum $KIT_FILES)"
  if [ "$remote_kit" != "$local_kit" ]; then
    differ="$(printf '%s\n%s\n' "$remote_kit" "$local_kit" | sort | uniq -u | awk '{ print $2 }' | sort -u | tr '\n' ' ')"
    die "the server's deploy kit differs from this commit in: $differ. Run 'make -C deploy/digitalocean push' from an up-to-date dev checkout, then re-run the failed jobs if this run's commit is still the newest on dev; otherwise the newer run deploys."
  fi
  kit_sum="$(printf '%s\n' "$local_kit" | sha256sum | cut -c1-64)"
  log="$work/deploy.log"
  ssh "$@" "deploy $IMAGE $kit_sum" 2>&1 | redact | tee "$log" || die "the deploy failed on the server; see the output above"
  last="$(tail -n 1 "$log")"
  [ "$last" = "running: $IMAGE" ] || die "the server reports '$last' instead of 'running: $IMAGE'"
  summary "Deployed \`$IMAGE\`"
}

cmd_verify() {
  : "${DEPLOY_HOST_NAME:?is empty; run make ci-setup}" "${DEPLOY_HOST_IP:?is empty; run make ci-setup}"
  dir="${RUNNER_TEMP:?set RUNNER_TEMP}/opdo"
  ( umask 077; mkdir -p "$dir"; printf 'HOST=%s\nDROPLET_IP=%s\n' "$DEPLOY_HOST_NAME" "$DEPLOY_HOST_IP" > "$dir/state" )
  OP_CONF_DIR="$dir" "$KIT_DIR/ops/stack.sh" verify
}

cmd="${1:?usage: pipeline.sh <gate|next-version|resolve-image|remote-deploy|verify>}"; shift || true
case "$cmd" in gate) cmd_gate;; next-version) cmd_next_version;; resolve-image) cmd_resolve_image;; remote-deploy) cmd_remote_deploy;; verify) cmd_verify;; *) die "unknown command $cmd";; esac
