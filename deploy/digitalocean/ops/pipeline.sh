#!/usr/bin/env bash
# Steps of .github/workflows/deploy-production.yml that run on the GitHub runner. Nothing here prints a secret.
. "$(dirname "$0")/common.sh"

IMAGE_RE='^ghcr\.io/machinekind/openproject:[A-Za-z0-9._-]{1,128}@sha256:[0-9a-f]{64}$'
SRC_DIR="${OP_SOURCE_DIR:-$(cd "$KIT_DIR/../.." && pwd)}"
KIT_FILES="deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh"

output() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; }
valid_image() {
  case "$1" in ghcr.io/machinekind/openproject:*@sha256:*) ;; *) return 1 ;; esac
  [[ $1 =~ $IMAGE_RE ]]
}

cmd_next_version() {
  repo="${REPO:?set REPO}"; sha="${SHA:?set SHA}"
  sha_re='^[0-9a-f]{40}$'
  [[ $sha =~ $sha_re ]] || die "SHA must be a full commit SHA"
  case "${BUMP:-}" in
    ""|patch) bump="patch" ;;
    minor) bump="minor" ;;
    *) die "BUMP must be patch or minor; a major version is cut by hand with make image BUMP=major" ;;
  esac
  labels="$(gh api "repos/$repo/commits/$sha/pulls" --jq '.[].labels[].name')" || die "could not read the pull requests of $sha"
  if printf '%s\n' "$labels" | grep -x -F 'release:minor' >/dev/null; then bump=minor; fi
  names="$(release_and_tag_names "$repo")" || die "could not list the releases and tags of $repo"
  base="$(printf '%s\n' "$names" | max_final_semver)"
  [ -n "$base" ] || die "$repo has no final release yet. A person publishes the baseline first: make -C deploy/digitalocean release IMAGE=<running image> TAG=<version> SHA=<its commit>"
  base_sha="$(gh api "repos/$repo/commits/$base" --jq .sha)" || die "could not resolve release $base to a commit"
  migrations="$(git -C "$SRC_DIR" diff --no-renames --diff-filter=A --name-only "$base_sha" "$sha" -- db/migrate ':(glob)modules/*/db/migrate/**')" \
    || die "could not compare $base with $sha; the checkout needs fetch-depth: 0"
  if [ -n "$migrations" ]; then
    count="$(printf '%s\n' "$migrations" | wc -l | tr -d ' ')"
    summary "### $count new migration(s) since $base"
    summary ""
    printf '%s\n' "$migrations" | while IFS= read -r m; do summary "- \`$m\`"; done
    [ "$bump" = minor ] || die "$count new migration(s) since $base, and production migrates on deploy. Add the label release:minor to the merged pull request and re-run this workflow, or run it by hand with bump=minor."
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
  image="${INPUT_IMAGE:-${BUILT_IMAGE:-}}"
  valid_image "$image" || die "the image must be ghcr.io/machinekind/openproject:<tag>@sha256:<64 hex digits>"
  if [ -n "${DEPLOY_HOST_NAME+set}" ]; then
    [ -n "$DEPLOY_HOST_NAME" ] || die "DEPLOY_HOST_NAME is empty; run make ci-setup"
    output host "$DEPLOY_HOST_NAME"
  fi
  output image "$image"
  info "image: $image"
}

cmd_remote_deploy() {
  : "${DEPLOY_SSH_KEY:?is empty; run make ci-setup}" "${DEPLOY_HOST_IP:?is empty; run make ci-setup}" "${DEPLOY_SSH_HOST_KEY:?is empty; run make ci-setup}" "${IMAGE:?set IMAGE}"
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
    die "the server's deploy kit differs from this commit in: $differ. Run 'make -C deploy/digitalocean push' from an up-to-date dev checkout, then re-run this job."
  fi
  log="$work/deploy.log"
  ssh "$@" "deploy $IMAGE" 2>&1 | redact | tee "$log" || die "the deploy failed on the server; see the output above"
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

cmd="${1:?usage: pipeline.sh <next-version|resolve-image|remote-deploy|verify>}"; shift || true
case "$cmd" in next-version) cmd_next_version;; resolve-image) cmd_resolve_image;; remote-deploy) cmd_remote_deploy;; verify) cmd_verify;; *) die "unknown command $cmd";; esac
