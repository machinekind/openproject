#!/usr/bin/env bash
set -u

src="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; failures=$((failures+1)); }
check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

OLD="ghcr.io/machinekind/openproject:1.0.0@sha256:$(printf 'a%.0s' $(seq 1 64))"
NEW="ghcr.io/machinekind/openproject:1.1.0@sha256:$(printf 'b%.0s' $(seq 1 64))"

setup() {
  t="$(mktemp -d)"
  mkdir -p "$t/stack" "$t/bin" "$t/stub"
  cp "$src/deploy.sh" "$t/stack/deploy.sh"
  printf 'OPENPROJECT_IMAGE=%s\nDATABASE_URL=%s\n' "$OLD" 'postgres://u:pw@db.example:25060/openproject?sslmode=require&pool=12' > "$t/stack/.env"
  export BACKUP_DIR="$t/backups"
  export STUB="$t/stub"
  echo web1 > "$STUB/web_id"
  echo "$OLD" > "$STUB/running"
  echo sha256:old > "$STUB/running_id"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/sleep"
  cat > "$t/bin/docker" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps -q web") if [ -f "$STUB/web_id" ]; then cat "$STUB/web_id"; fi ;;
  "inspect --format {{.Config.Image}} "*) cat "$STUB/running" ;;
  "inspect --format {{.Image}} "*) cat "$STUB/running_id" ;;
  "inspect --format {{.State.Health.Status}} "*) echo "${STUB_HEALTH:-healthy}" ;;
  "compose pull")
    echo "pull OPENPROJECT_IMAGE=${OPENPROJECT_IMAGE:-}" >> "$STUB/calls"
    exit "${STUB_PULL_RC:-0}" ;;
  "compose up -d --remove-orphans")
    echo up >> "$STUB/calls"
    if [ "${STUB_UP_RC:-0}" -ne 0 ]; then exit "$STUB_UP_RC"; fi
    grep '^OPENPROJECT_IMAGE=' ./.env | cut -d= -f2- > "$STUB/running"
    echo sha256:new > "$STUB/running_id"
    echo web1 > "$STUB/web_id" ;;
  "run "*)
    echo run >> "$STUB/calls"
    echo DUMPDATA
    exit "${STUB_RUN_RC:-0}" ;;
  "image ls "*) if [ -f "$STUB/images" ]; then cat "$STUB/images"; fi ;;
  "image rm -f "*) echo "rm $4" >> "$STUB/calls" ;;
  "image prune -f") echo prune >> "$STUB/calls" ;;
  *) echo "unexpected docker $*" >&2; exit 99 ;;
esac
STUBEOF
  chmod +x "$t/bin/sleep" "$t/bin/docker"
  PATH="$t/bin:$ORIG_PATH"
  export PATH
}

cleanup() { rm -rf "$t"; unset STUB_PULL_RC STUB_UP_RC STUB_HEALTH STUB_RUN_RC; }

ORIG_PATH="$PATH"
run_deploy() { (cd "$t/stack" && ./deploy.sh "$@") > "$t/out" 2> "$t/err"; rc=$?; }
env_has() { grep -qxF "$1" "$t/stack/.env"; }
calls_has() { grep -qxF "$1" "$t/stub/calls" 2>/dev/null; }
calls_lacks() { ! calls_has "$1"; }
no_dumps() { [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; }
err_has() { grep -qF "$1" "$t/err"; }
file_has() { grep -qF "$2" "$1" 2>/dev/null; }
file_lacks() { ! file_has "$1" "$2"; }
count_files() { [ "$(ls -1 $1 2>/dev/null | wc -l)" -eq "$2" ]; }

setup
run_deploy 'bad image;id'
check "1 bad image reference exits 2" [ "$rc" -eq 2 ]
check "1 no docker calls" [ ! -e "$STUB/calls" ]
cleanup

setup
export STUB_PULL_RC=1
run_deploy "$NEW"
check "2 pull failure exits non-zero" [ "$rc" -ne 0 ]
check "2 .env keeps old image" env_has "OPENPROJECT_IMAGE=$OLD"
check "2 pull used the new image" calls_has "pull OPENPROJECT_IMAGE=$NEW"
check "2 no up" calls_lacks up
check "2 no dump written" no_dumps
cleanup

setup
printf '%s\n' 'ghcr.io/machinekind/openproject sha256:new' 'ghcr.io/machinekind/openproject sha256:old' 'ghcr.io/machinekind/openproject sha256:older' 'postgres sha256:pg' > "$STUB/images"
run_deploy "$NEW"
check "3 success exits 0" [ "$rc" -eq 0 ]
check "3 .env names new image" env_has "OPENPROJECT_IMAGE=$NEW"
check "3 .env names new image once" [ "$(grep -c '^OPENPROJECT_IMAGE=' "$t/stack/.env")" -eq 1 ]
check "3 .env keeps DATABASE_URL" grep -q '^DATABASE_URL=postgres://u:pw@db.example:25060/openproject' "$t/stack/.env"
check "3 .env mode 600" [ "$(stat -c %a "$t/stack/.env")" = 600 ]
check "3 previous-image is old" file_has "$t/stack/.deploy/previous-image" "$OLD"
check "3 previous-image-id is old id" file_has "$t/stack/.deploy/previous-image-id" sha256:old
check "3 last line is running:" [ "$(tail -n 1 "$t/out")" = "running: $NEW" ]
check "3 one dump file" count_files "$BACKUP_DIR/db-predeploy-1.1.0-*.dump" 1
check "3 dump holds data" file_has "$(ls "$BACKUP_DIR"/db-predeploy-1.1.0-*.dump | head -n 1)" DUMPDATA
check "3 older image removed" calls_has "rm sha256:older"
check "3 previous image kept" calls_lacks "rm sha256:old"
check "3 current image kept" calls_lacks "rm sha256:new"
check "3 other repository kept" calls_lacks "rm sha256:pg"
cleanup

setup
export STUB_UP_RC=1
run_deploy "$NEW"
check "4 up failure exits 1" [ "$rc" -eq 1 ]
check "4 .env restored" env_has "OPENPROJECT_IMAGE=$OLD"
check "4 stderr says deploy failed" err_has "deploy failed:"
check "4 stderr warns against argument-less deploy" err_has "Do not run deploy.sh without an argument"
check "4 failed deploy is not recorded as previous" [ ! -e "$t/stack/.deploy/previous-image" ]
check "4 no previous id recorded" [ ! -e "$t/stack/.deploy/previous-image-id" ]
cleanup

setup
export STUB_HEALTH=unhealthy
run_deploy "$NEW"
check "5 unhealthy exits 1" [ "$rc" -eq 1 ]
check "5 .env restored" env_has "OPENPROJECT_IMAGE=$OLD"
check "5 stderr says not healthy" err_has "did not become healthy"
check "5 stderr warns against argument-less deploy" err_has "Do not run deploy.sh without an argument"
check "5 failed deploy is not recorded as previous" [ ! -e "$t/stack/.deploy/previous-image" ]
check "5 no previous id recorded" [ ! -e "$t/stack/.deploy/previous-image-id" ]
cleanup

setup
exec 8>"$t/stack/.deploy.lock"
flock -n 8
run_deploy "$NEW"
exec 8>&-
check "6 locked deploy exits 1" [ "$rc" -eq 1 ]
check "6 stderr says another deploy is running" err_has "another deploy is running"
cleanup

setup
mkdir -p "$BACKUP_DIR"
for n in 1 2 3 4; do
  f="$BACKUP_DIR/db-predeploy-old$n-202001010000.dump"
  echo x > "$f"
  touch -d "2020-01-0$n" "$f"
done
run_deploy "$NEW"
check "7 success exits 0" [ "$rc" -eq 0 ]
check "7 three dumps remain" count_files "$BACKUP_DIR/db-predeploy-*.dump" 3
check "7 new dump kept" count_files "$BACKUP_DIR/db-predeploy-1.1.0-*.dump" 1
cleanup

setup
run_deploy
check "8 no argument exits 0" [ "$rc" -eq 0 ]
check "8 .env still names old image" env_has "OPENPROJECT_IMAGE=$OLD"
check "8 pull with empty override" calls_has "pull OPENPROJECT_IMAGE="
check "8 no previous-image" [ ! -e "$t/stack/.deploy/previous-image" ]
cleanup

setup
grep -v '^DATABASE_URL=' "$t/stack/.env" > "$t/env.new"
mv "$t/env.new" "$t/stack/.env"
run_deploy "$NEW"
check "9 missing DATABASE_URL exits 1" [ "$rc" -eq 1 ]
check "9 stderr says dump failed" err_has "pre-deploy database dump failed"
check "9 .env still names old image" env_has "OPENPROJECT_IMAGE=$OLD"
check "9 no up" calls_lacks up
cleanup

setup
export STUB_HEALTH=unhealthy
run_deploy "$NEW"
rm -f "$t/stack/.deploy/previous-image"
unset STUB_HEALTH
printf '%s\n' 'ghcr.io/machinekind/openproject sha256:new' 'ghcr.io/machinekind/openproject sha256:old' > "$STUB/images"
run_deploy "$NEW"
check "10 retry after failure succeeds" [ "$rc" -eq 0 ]
check "10 previous-image is the pre-deploy .env image" file_has "$t/stack/.deploy/previous-image" "$OLD"
check "10 running image is not recorded as previous" file_lacks "$t/stack/.deploy/previous-image" "$NEW"
cleanup

if [ "$failures" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
fi
echo "$failures check(s) failed"
exit 1
