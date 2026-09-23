#!/usr/bin/env bash
# Infrastructure steps that run on the operator's machine: checks, discovery, image build, config, DNS.
. "$(dirname "$0")/common.sh"

cmd_preflight() {
  fail=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1${3:+ ($3)}"; fail=1; fi; }
  info "Tools"
  for t in doctl gh ssh scp dig curl openssl; do check "$t installed" "command -v $t"; done
  info "Accounts"
  check "doctl is logged in" "doctl account get" "run: doctl auth init"
  check "gh is logged in" "gh auth status" "run: gh auth login"
  check "an SSH key is uploaded to DigitalOcean" "[ -n \"\$(doctl compute ssh-key list --format ID --no-header)\" ]" "upload one in the control panel"
  info "Names used by provision.sh"
  region="${REGION:-fra1}"; size="${DROPLET_SIZE:-s-2vcpu-4gb}"; dbsize="${DB_SIZE:-db-s-1vcpu-1gb}"
  check "region $region" "doctl compute region list --format Slug,Available --no-header | grep -E \"^$region +true\""
  check "droplet size $size" "doctl compute size list --format Slug --no-header | grep -x $size"
  check "image ubuntu-24-04-x64" "doctl compute image list-distribution --format Slug --no-header | grep -x ubuntu-24-04-x64"
  check "database size $dbsize" "doctl databases options slugs --engine pg | grep -w $dbsize"
  check "PostgreSQL ${DB_VERSION:-17} offered" "doctl databases options versions --engine pg | grep -w ${DB_VERSION:-17}"
  [ "$fail" -eq 0 ] && info "preflight passed" || die "preflight failed"
}

# Rebuild the state file for a deployment that already exists.
cmd_adopt() {
  name="${NAME:-openproject}"
  ip="$(doctl compute droplet list --tag-name "$name" --format PublicIPv4 --no-header | head -n 1)"
  id="$(doctl compute droplet list --tag-name "$name" --format ID --no-header | head -n 1)"
  db="$(doctl databases list --format ID,Name --no-header | awk -v n="${name}-db" '$2==n{print $1}')"
  [ -n "$ip" ] || die "no Droplet tagged '$name' found"
  [ -n "$db" ] || die "no database cluster named '${name}-db' found"
  state_set NAME "$name"; state_set DROPLET_ID "$id"; state_set DROPLET_IP "$ip"; state_set DB_ID "$db"
  if [ -f "$ENV_FILE" ]; then
    host="$(env_get_public OPENPROJECT_HOST__NAME)"
    case "$host" in ""|op.example.org) ;; *) state_set HOST "$host";; esac
  fi
  info "adopted: droplet $id at $ip, database $db, host $(state_get HOST)"
}

upstream_version() {
  gh api "repos/$1/contents/lib/open_project/version.rb?ref=$2" --jq .content | base64 -d \
    | awk '$2 == "=" && $1 == "MAJOR" { ma = $3 } $2 == "=" && $1 == "MINOR" { mi = $3 } $2 == "=" && $1 == "PATCH" { pa = $3 }
           END { if (ma != "" && mi != "" && pa != "") printf "%d.%d.%d\n", ma, mi, pa }'
}

# Build the production image with the fork-image workflow and pin it, by digest, in the local secrets file.
cmd_image() {
  ref="${REF:-dev}"
  case "${TAG:+t}${BUMP:+b}" in
    t) tag="$TAG";;
    b) case "$BUMP" in major|minor|patch) ;; *) die "BUMP must be major, minor or patch";; esac;;
    *) die "set exactly one of BUMP=major|minor|patch (next after the latest release) or TAG=1.2.0";;
  esac
  repo="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
  sha="$(gh api "repos/$repo/commits/$ref" --jq .sha)" && [ -n "$sha" ] || die "could not resolve $ref on $repo"
  names="$(release_and_tag_names "$repo")" || die "could not list the releases and tags of $repo"
  names="$(printf '%s\n%s\n' "$names" "$(state_get BUILT_TAG)")"
  if [ -z "${TAG:-}" ]; then
    base="$(printf '%s\n' "$names" | max_final_semver)"
    tag="$(bump_semver "$base" "$BUMP")"
  fi
  semver_valid "$tag" || die "TAG must be semantic: MAJOR.MINOR.PATCH[-prerelease], for example 1.2.0"
  if printf '%s\n' "$names" | grep -q -x -F -- "$tag" && [ "${FORCE:-0}" != "1" ]; then
    die "$tag is already a release, a tag or the last build on $repo. Pick another version, or FORCE=1 to overwrite its image"
  fi
  upstream="$(upstream_version "$repo" "$sha")" || upstream=""
  info "next version: $tag"
  before="$(gh run list --repo "$repo" --workflow fork-image.yml --limit 1 --json databaseId -q '.[0].databaseId // 0')"
  info "dispatching fork-image.yml on $repo for $ref at $sha, tag $tag"
  gh workflow run fork-image.yml --repo "$repo" --ref "${WORKFLOW_REF:-dev}" -f ref="$sha" -f tag="$tag" >/dev/null
  run=""; for _ in $(seq 1 30); do
    run="$(gh run list --repo "$repo" --workflow fork-image.yml --limit 1 --json databaseId -q '.[0].databaseId // 0')"
    [ "$run" != "$before" ] && [ "$run" != "0" ] && break; run=""; sleep 3
  done
  [ -n "$run" ] || die "the workflow run did not appear; check the Actions tab"
  info "run $run started; waiting (about 7 minutes)"
  gh run watch "$run" --repo "$repo" --exit-status --interval 30 >/dev/null || die "build failed: gh run view $run --repo $repo --log-failed"
  digest="$(gh run view "$run" --repo "$repo" --log | grep -o '"containerimage.digest": "sha256:[0-9a-f]\{64\}"' | head -n 1 | grep -o 'sha256:[0-9a-f]\{64\}')"
  [ -n "$digest" ] || die "could not read the image digest from run $run"
  owner="$(printf '%s' "${repo%%/*}" | tr '[:upper:]' '[:lower:]')"
  image="ghcr.io/${owner}/openproject:${tag}@${digest}"
  state_set IMAGE "$image"
  if [ -f "$ENV_FILE" ]; then env_set OPENPROJECT_IMAGE "$image"; info "pinned in $ENV_FILE"; fi
  state_set BUILT_TAG "$tag"; state_set BUILT_SHA "$sha"; state_set BUILT_REF "$ref"; state_set BUILT_UPSTREAM "$upstream"
  info "image: $image (built from $ref at $sha, upstream OpenProject ${upstream:-unknown})"
}

# Publish a GitHub release for the deployed image. The notes list the PRs merged since the previous release.
cmd_release() {
  repo="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
  image="${IMAGE:-$(state_get IMAGE)}"
  default_tag="${image%@*}"; default_tag="${default_tag##*:}"
  tag="${TAG:-$default_tag}"
  [ -n "$tag" ] || die "no image tag known. Pass TAG=... or IMAGE=..."
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then info "release $tag already exists"; return 0; fi
  sha="${SHA:-}"; ref="${REF:-}"; upstream="${UPSTREAM:-}"
  if [ "$tag" = "$(state_get BUILT_TAG)" ]; then
    [ -n "$ref" ] || ref="$(state_get BUILT_REF)"
    [ -n "$sha" ] || sha="$(state_get BUILT_SHA)"
    [ -n "$upstream" ] || upstream="$(state_get BUILT_UPSTREAM)"
  fi
  if [ -z "$sha" ]; then
    info "no release for $tag: its source commit is unknown. Run: make release ${image:+IMAGE=$image }TAG=$tag SHA=<commit>"
    return 0
  fi
  finals="$(final_releases "$repo")" || die "could not list the releases of $repo"
  if [ -n "${PREV+set}" ]; then prev="$PREV"
  elif semver_valid "$tag"; then prev="$(printf '%s\n%s\n' "$finals" "${tag%%-*}" | only_final_semver | sort -V -u | awk -v t="${tag%%-*}" '$0 == t { print p; exit } { p = $0 }')"
  else prev="$(printf '%s\n' "$finals" | max_final_semver)"; fi
  file="$(mktemp)"
  {
    printf 'Deployed to %s on %s.\n\n' "$(state_get HOST)" "${DEPLOYED:-$(date -u +%Y-%m-%d)}"
    printf 'Image: `%s`\n' "$image"
    printf 'Source: %s at %s%s\n' "${ref:-$sha}" "$sha" "${upstream:+ (upstream OpenProject $upstream)}"
    [ -z "${NOTES:-}" ] || printf '\n%s\n' "$NOTES"
  } > "$file"
  set -- --repo "$repo" --target "$sha" --title "$tag" --notes-file "$file" --generate-notes
  [ -z "$prev" ] || set -- "$@" --notes-start-tag "$prev"
  if [ -z "$(printf '%s\n' "$tag" | only_final_semver)" ]; then set -- "$@" --prerelease
  elif [ "$(printf '%s\n%s\n' "$finals" "$tag" | max_final_semver)" = "$tag" ]; then set -- "$@" --latest
  else set -- "$@" --latest=false; fi
  url="$(gh release create "$tag" "$@")" || { rm -f "$file"; die "gh release create failed for $tag"; }
  rm -f "$file"
  info "release: $url"
}

cmd_configure() {
  host="${HOST:?set HOST, for example HOST=op.example.org}"
  env_set OPENPROJECT_HOST__NAME "$host"; state_set HOST "$host"
  [ -z "${ADMIN_MAIL:-}" ] || env_set OPENPROJECT_SEED__ADMIN__USER__MAIL "$ADMIN_MAIL"
  [ -z "${IMAGE:-}" ] || { env_set OPENPROJECT_IMAGE "$IMAGE"; state_set IMAGE "$IMAGE"; }
  case "$(env_get_public OPENPROJECT_IMAGE)" in *CHANGE_ME*|"") echo "note: no image pinned yet. Run 'make image BUMP=minor' or pass IMAGE=...";; esac
  info "configured host $host. Create a DNS A record: $host -> $(state_get DROPLET_IP)"
}

cmd_dns_wait() {
  require_state HOST DROPLET_IP
  host="$(state_get HOST)"; ip="$(state_get DROPLET_IP)"
  for _ in $(seq 1 "${TRIES:-60}"); do
    got="$(dig +short "$host" A @1.1.1.1 | head -n 1)"
    if [ "$got" = "$ip" ]; then info "DNS ok: $host -> $ip"; return 0; fi
    [ -z "$got" ] || echo "  $host currently resolves to $got, expected $ip"
    sleep 20
  done
  die "$host does not resolve to $ip yet. Add the A record, then run this again."
}

cmd="${1:?usage: infra.sh <preflight|adopt|image|release|configure|dns-wait>}"; shift || true
case "$cmd" in preflight) cmd_preflight;; adopt) cmd_adopt;; image) cmd_image;; release) cmd_release;; configure) cmd_configure;; dns-wait) cmd_dns_wait;; *) die "unknown command $cmd";; esac
