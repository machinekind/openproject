#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 (missing '$3' in '$2')" ;; esac; }
absent() { if [ -e "$2" ]; then not_ok "$1 ($2 exists)"; else ok "$1"; fi; }

setup() {
  t="$(mktemp -d)"
  d="$t/srv"
  mkdir -p "$d"
  export OP_REMOTE_DIR="$d"
  up="$d/.env.push.abc123"
}
cleanup() { rm -rf "$t"; }
merge() { bash "$here/ops/remote/env-merge.sh" "$@" >/dev/null 2>"$t/err"; rc=$?; err="$(cat "$t/err")"; }
promote() { bash "$here/ops/remote/kit-promote.sh" "$@" >/dev/null 2>"$t/err"; rc=$?; err="$(cat "$t/err")"; }

setup
printf 'A=1\nOPENPROJECT_IMAGE=img:server\nB=2\n' > "$d/.env"
printf 'A=9\nOPENPROJECT_IMAGE=img:laptop\nC=3\n' > "$up"
merge keep-image "$up"
check "e1 keep-image exits 0" "$rc" 0
check "e1 .env content" "$(cat "$d/.env")" "$(printf 'A=9\nC=3\nOPENPROJECT_IMAGE=img:server')"
check "e1 .env mode 600" "$(stat -c %a "$d/.env")" 600
absent "e1 upload removed" "$up"
cleanup

setup
printf 'A=9\nOPENPROJECT_IMAGE=img:laptop\n' > "$up"
merge keep-image "$up"
check "e2 missing server .env exits 1" "$rc" 1
contains "e2 message" "$err" "no readable .env"
absent "e2 no .env created" "$d/.env"
absent "e2 upload removed" "$up"
cleanup

setup
printf 'A=1\n' > "$d/.env"
printf 'A=9\nOPENPROJECT_IMAGE=img:laptop\n' > "$up"
merge keep-image "$up"
check "e3 server .env without image exits 1" "$rc" 1
contains "e3 message" "$err" "no valid OPENPROJECT_IMAGE"
check "e3 .env unchanged" "$(cat "$d/.env")" "A=1"
absent "e3 upload removed" "$up"
cleanup

setup
printf 'A=1\nOPENPROJECT_IMAGE=img:server\n' > "$d/.env"
printf 'A=9\n' > "$up"
exec 8>"$d/.deploy.lock"
flock -n 8
merge keep-image "$up"
exec 8>&-
check "e4 locked exits 1" "$rc" 1
contains "e4 message" "$err" "a deploy is running"
check "e4 .env unchanged" "$(cat "$d/.env")" "$(printf 'A=1\nOPENPROJECT_IMAGE=img:server')"
absent "e4 upload removed" "$up"
cleanup

setup
printf 'A=9\nOPENPROJECT_IMAGE=img:laptop\n' > "$up"
merge initial "$up"
check "e5 initial exits 0" "$rc" 0
check "e5 .env is the upload" "$(cat "$d/.env")" "$(printf 'A=9\nOPENPROJECT_IMAGE=img:laptop')"
check "e5 .env mode 600" "$(stat -c %a "$d/.env")" 600
cleanup

setup
printf 'A=1\nOPENPROJECT_IMAGE=img:server\n' > "$d/.env"
printf 'A=9\nOPENPROJECT_IMAGE=img:laptop\n' > "$up"
merge initial "$up"
check "e6 initial over an existing .env exits 1" "$rc" 1
contains "e6 message" "$err" "has a .env already"
check "e6 .env unchanged" "$(cat "$d/.env")" "$(printf 'A=1\nOPENPROJECT_IMAGE=img:server')"
cleanup

setup
printf 'A=9\n' > "$up"
merge initial "$up"
check "e7 initial without image exits 1" "$rc" 1
absent "e7 no .env created" "$d/.env"
cleanup

setup
printf 'A=9\n' > "$t/elsewhere"
merge keep-image "$t/elsewhere"
check "e8 upload outside the stack exits 1" "$rc" 1
contains "e8 message" "$err" "unexpected upload path"
cleanup

stage_kit() {
  s="$d/.push-staging.abc123"
  mkdir -p "$s/ops/rails" "$s/ops/remote"
  for f in docker-compose.yml Caddyfile bootstrap-db.sh deploy.sh backup.sh; do echo "new $f" > "$s/$f"; done
  echo "new rb" > "$s/ops/rails/a.rb"
  echo "new ci" > "$s/ops/remote/ci-deploy.sh"
  echo "old deploy" > "$d/deploy.sh"
}
TOP=(docker-compose.yml Caddyfile bootstrap-db.sh deploy.sh backup.sh)

setup
stage_kit
promote "$s" "${TOP[@]}"
check "k1 promote exits 0" "$rc" 0
check "k1 deploy.sh replaced" "$(cat "$d/deploy.sh")" "new deploy.sh"
check "k1 deploy.sh executable" "$([ -x "$d/deploy.sh" ] && echo yes)" yes
check "k1 ci-deploy.sh executable" "$([ -x "$d/ops/remote/ci-deploy.sh" ] && echo yes)" yes
check "k1 rails script copied" "$(cat "$d/ops/rails/a.rb")" "new rb"
absent "k1 staging removed" "$s"
cleanup

setup
stage_kit
exec 8>"$d/.deploy.lock"
flock -n 8
promote "$s" "${TOP[@]}"
exec 8>&-
check "k2 locked exits 1" "$rc" 1
contains "k2 message" "$err" "a deploy is running"
check "k2 deploy.sh unchanged" "$(cat "$d/deploy.sh")" "old deploy"
absent "k2 staging removed" "$s"
cleanup

setup
mkdir -p "$t/other"
promote "$t/other" deploy.sh
check "k3 staging outside the stack exits 1" "$rc" 1
contains "k3 message" "$err" "unexpected staging directory"
cleanup

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
