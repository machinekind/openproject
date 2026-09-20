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

# Build the production image with the fork-image workflow and pin it, by digest, in the local secrets file.
cmd_image() {
  ref="${REF:-stable-17.8-mcp}"; tag="${TAG:?set TAG, for example TAG=17.8.0-mcp.2}"
  repo="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
  before="$(gh run list --repo "$repo" --workflow fork-image.yml --limit 1 --json databaseId -q '.[0].databaseId // 0')"
  info "dispatching fork-image.yml on $repo for ref=$ref tag=$tag"
  gh workflow run fork-image.yml --repo "$repo" --ref "${WORKFLOW_REF:-dev}" -f ref="$ref" -f tag="$tag" >/dev/null
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
  info "image: $image"
}

cmd_configure() {
  host="${HOST:?set HOST, for example HOST=op.example.org}"
  env_set OPENPROJECT_HOST__NAME "$host"; state_set HOST "$host"
  [ -z "${ADMIN_MAIL:-}" ] || env_set OPENPROJECT_SEED__ADMIN__USER__MAIL "$ADMIN_MAIL"
  [ -z "${IMAGE:-}" ] || { env_set OPENPROJECT_IMAGE "$IMAGE"; state_set IMAGE "$IMAGE"; }
  case "$(env_get_public OPENPROJECT_IMAGE)" in *CHANGE_ME*|"") echo "note: no image pinned yet. Run 'make image TAG=...' or pass IMAGE=...";; esac
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

cmd="${1:?usage: infra.sh <preflight|adopt|image|configure|dns-wait>}"; shift || true
case "$cmd" in preflight) cmd_preflight;; adopt) cmd_adopt;; image) cmd_image;; configure) cmd_configure;; dns-wait) cmd_dns_wait;; *) die "unknown command $cmd";; esac
