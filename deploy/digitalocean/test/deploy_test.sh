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

FP1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FP2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Z="ghcr.io/machinekind/openproject:0.9.0@sha256:$(printf 'f%.0s' $(seq 1 64))"
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
  printf '%s sha256:old\n' "$OLD" > "$STUB/local"
  printf '%s|exited|0|2020-01-01T00:00:00.000000000Z\n' "$OLD" > "$STUB/seeder"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/sleep"
  cat > "$t/bin/docker" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps -a -q seeder") if [ -f "$STUB/seeder" ]; then echo seeder1; fi ;;
  "inspect --format {{.Config.Image}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}} "*) cat "$STUB/seeder" ;;
  "compose ps -q web") if [ -f "$STUB/web_id" ]; then cat "$STUB/web_id"; fi ;;
  "inspect --format {{.Config.Image}} "*) cat "$STUB/running" ;;
  "inspect --format {{.Image}} "*) cat "$STUB/running_id" ;;
  "inspect --format {{.State.Health.Status}} "*)
    if [ -n "${STUB_UNHEALTHY_IMAGE:-}" ] && [ "$(cat "$STUB/running")" = "$STUB_UNHEALTHY_IMAGE" ]; then echo unhealthy; else echo "${STUB_HEALTH:-healthy}"; fi ;;
  "image inspect --format {{.Id}} "*)
    ref="${!#}"
    awk -v r="$ref" '$1 == r { print $2; found = 1 } END { exit !found }' "$STUB/local" 2>/dev/null || { echo "Error: No such image: $ref" >&2; exit 1; } ;;
  "compose pull")
    echo "pull OPENPROJECT_IMAGE=${OPENPROJECT_IMAGE:-}" >> "$STUB/calls"
    exit "${STUB_PULL_RC:-0}" ;;
  "compose up -d --remove-orphans")
    img="$(grep '^OPENPROJECT_IMAGE=' ./.env | cut -d= -f2-)"
    echo "up $img" >> "$STUB/calls"
    [ -n "${STUB_SEEDER_UNTOUCHED:-}" ] || printf '%s|%s|%s|%s\n' "$img" "${STUB_SEEDER_STATUS:-exited}" "${STUB_SEEDER_RC:-0}" "${STUB_SEEDER_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)}" > "$STUB/seeder"
    if [ "${STUB_UP_RC:-0}" -ne 0 ] && { [ -z "${STUB_UP_FAIL_IMAGE:-}" ] || [ "$img" = "$STUB_UP_FAIL_IMAGE" ]; }; then exit "$STUB_UP_RC"; fi
    printf '%s\n' "$img" > "$STUB/running"
    id="$(awk -v r="$img" '$1 == r { print $2 }' "$STUB/local")"
    echo "${id:-sha256:new}" > "$STUB/running_id"
    echo web1 > "$STUB/web_id" ;;
  "run "*psql*)
    cat > /dev/null
    echo psql >> "$STUB/calls"
    [ -s "$STUB/fingerprints" ] || exit 2
    head -n 1 "$STUB/fingerprints"
    tail -n +2 "$STUB/fingerprints" > "$STUB/fingerprints.tmp"
    mv "$STUB/fingerprints.tmp" "$STUB/fingerprints" ;;
  "run "*)
    echo run >> "$STUB/calls"
    echo DUMPDATA
    exit "${STUB_RUN_RC:-0}" ;;
  "container ls -a -q") if [ -f "$STUB/containers" ]; then cat "$STUB/containers"; fi ;;
  "container inspect --format {{.Image}} "*) if [ -f "$STUB/container_images" ]; then cat "$STUB/container_images"; fi ;;
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

cleanup() { rm -rf "$t"; unset STUB_PULL_RC STUB_UP_RC STUB_UP_FAIL_IMAGE STUB_HEALTH STUB_UNHEALTHY_IMAGE STUB_RUN_RC STUB_SEEDER_RC STUB_SEEDER_STATUS STUB_SEEDER_UNTOUCHED STUB_SEEDER_STARTED EXPECTED_KIT_SHA256; }

ORIG_PATH="$PATH"
run_deploy() { (cd "$t/stack" && ./deploy.sh "$@") > "$t/out" 2> "$t/err"; rc=$?; }
env_has() { grep -qxF "$1" "$t/stack/.env"; }
calls_has() { grep -qxF "$1" "$t/stub/calls" 2>/dev/null; }
calls_lacks() { ! calls_has "$1"; }
no_up() { ! grep -q '^up' "$t/stub/calls" 2>/dev/null; }
up_count() { grep -c '^up' "$t/stub/calls" 2>/dev/null; }
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
check "2 no up" no_up
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
check "3 no pending previous image" [ ! -e "$t/stack/.deploy/previous-image.pending" ]
cleanup

setup
export STUB_UP_RC=1
run_deploy "$NEW"
check "4 up failure exits 1" [ "$rc" -eq 1 ]
check "4 .env restored" env_has "OPENPROJECT_IMAGE=$OLD"
check "4 stderr says deploy failed" err_has "deploy failed:"
check "4 stderr warns against argument-less deploy" err_has "Do not run deploy.sh without an argument"
check "4 previous-image is the image before the attempt" file_has "$t/stack/.deploy/previous-image" "$OLD"
check "4 failed image is not recorded as previous" file_lacks "$t/stack/.deploy/previous-image" "$NEW"
check "4 previous id is the old image id" file_has "$t/stack/.deploy/previous-image-id" sha256:old
check "4 unknown schema restarts nothing" [ "$(up_count)" -eq 1 ]
check "4 stderr says nothing was restarted" err_has "nothing was restarted"
check "4 last-dump names this attempt's dump" file_has "$t/stack/.deploy/last-dump" "$BACKUP_DIR/db-predeploy-1.1.0-"
check "4 stderr names the dump" err_has "$(cat "$t/stack/.deploy/last-dump" 2>/dev/null || echo missing-last-dump)"
check "4 no pending previous image" [ ! -e "$t/stack/.deploy/previous-image.pending" ]
cleanup

setup
export STUB_HEALTH=unhealthy
run_deploy "$NEW"
check "5 unhealthy exits 1" [ "$rc" -eq 1 ]
check "5 .env restored" env_has "OPENPROJECT_IMAGE=$OLD"
check "5 stderr says not healthy" err_has "did not become healthy"
check "5 stderr warns against argument-less deploy" err_has "Do not run deploy.sh without an argument"
check "5 previous-image is the image before the attempt" file_has "$t/stack/.deploy/previous-image" "$OLD"
check "5 failed image is not recorded as previous" file_lacks "$t/stack/.deploy/previous-image" "$NEW"
check "5 unknown schema restarts nothing" [ "$(up_count)" -eq 1 ]
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
check "9 no up" no_up
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

healthy_schema() { mkdir -p "$t/stack/.deploy"; printf '%s\n' "$1" > "$t/stack/.deploy/healthy-schema"; }

setup
mkdir -p "$BACKUP_DIR"
for n in 1 2 3 4; do
  f="$BACKUP_DIR/db-predeploy-old$n-202001010000.dump"
  echo x > "$f"
  touch -d "2020-01-0$n" "$f"
done
healthy_schema "$FP1 $OLD"
echo "$Z" > "$t/stack/.deploy/previous-image"
echo sha256:z > "$t/stack/.deploy/previous-image-id"
printf '%s\n' 'ghcr.io/machinekind/openproject sha256:new' 'ghcr.io/machinekind/openproject sha256:old' 'ghcr.io/machinekind/openproject sha256:z' 'ghcr.io/machinekind/openproject sha256:older' > "$STUB/images"
printf '%s\n%s\n' "$FP1" "$FP1" > "$STUB/fingerprints"
export STUB_UNHEALTHY_IMAGE="$NEW"
run_deploy "$NEW"
check "11 unhealthy on the healthy schema exits 1" [ "$rc" -eq 1 ]
check "11 up ran twice" [ "$(up_count)" -eq 2 ]
check "11 old image started again" calls_has "up $OLD"
check "11 old image runs" [ "$(cat "$STUB/running")" = "$OLD" ]
check "11 .env names old image" env_has "OPENPROJECT_IMAGE=$OLD"
check "11 stderr says rolled back automatically" err_has "rolled back automatically to $OLD: no migration had run"
check "11 no last-dump" [ ! -e "$t/stack/.deploy/last-dump" ]
check "11 failed attempt keeps the 3 newest dumps" count_files "$BACKUP_DIR/db-predeploy-*.dump" 3
check "11 this attempt's dump kept" count_files "$BACKUP_DIR/db-predeploy-1.1.0-*.dump" 1
check "11 previous-image unchanged" [ "$(cat "$t/stack/.deploy/previous-image")" = "$Z" ]
check "11 previous-image-id unchanged" [ "$(cat "$t/stack/.deploy/previous-image-id")" = sha256:z ]
check "11 no pending previous image" [ ! -e "$t/stack/.deploy/previous-image.pending" ]
check "11 failed image removed" calls_has "rm sha256:new"
check "11 older image removed" calls_has "rm sha256:older"
check "11 running old image kept" calls_lacks "rm sha256:old"
check "11 previous image kept" calls_lacks "rm sha256:z"
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UP_RC=1 STUB_UP_FAIL_IMAGE="$NEW"
run_deploy "$NEW"
check "12 up failure on the healthy schema exits 1" [ "$rc" -eq 1 ]
check "12 old image started again" calls_has "up $OLD"
check "12 stderr says rolled back automatically" err_has "rolled back automatically to $OLD"
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP2" > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "13 changed schema exits 1" [ "$rc" -eq 1 ]
check "13 old image not restarted" [ "$(up_count)" -eq 1 ]
check "13 stderr says nothing was restarted" err_has "nothing was restarted"
check "13 last-dump names this attempt's dump" file_has "$t/stack/.deploy/last-dump" "$BACKUP_DIR/db-predeploy-1.1.0-"
check "13 stderr names make rollback target" err_has "make rollback, which deploys $OLD"
cleanup

setup
healthy_schema "$FP1 someother:image"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "14 schema last healthy for another image exits 1" [ "$rc" -eq 1 ]
check "14 old image not restarted" [ "$(up_count)" -eq 1 ]
cleanup

setup
printf '%s\n' "$FP1" > "$STUB/fingerprints"
run_deploy "$NEW"
check "15 healthy deploy exits 0" [ "$rc" -eq 0 ]
check "15 healthy-schema names fingerprint and new image" [ "$(cat "$t/stack/.deploy/healthy-schema")" = "$FP1 $NEW" ]
check "15 no last-dump" [ ! -e "$t/stack/.deploy/last-dump" ]
cleanup

setup
run_deploy "$NEW"
check "16 dump name has UTC seconds and short digest" count_files "$BACKUP_DIR/db-predeploy-1.1.0-*T*Z-bbbbbbbbbbbb.dump" 1
check "16 stdout names the dump path" grep -qF "pre-deploy dump: $BACKUP_DIR/db-predeploy-1.1.0-" "$t/out"
cleanup

setup
printf '%s sha256:new\n' "$NEW" >> "$STUB/local"
run_deploy "$NEW"
check "17 local image exits 0" [ "$rc" -eq 0 ]
check "17 local image is not pulled" calls_lacks "pull OPENPROJECT_IMAGE=$NEW"
check "17 stdout says not pulling" grep -qF "not pulling" "$t/out"
cleanup

setup
: > "$STUB/local"
run_deploy "$NEW"
check "18 success exits 0" [ "$rc" -eq 0 ]
check "18 previous-image is old" file_has "$t/stack/.deploy/previous-image" "$OLD"
check "18 no previous id when old image is not local" [ ! -e "$t/stack/.deploy/previous-image-id" ]
cleanup

setup
run_deploy "ghcr.io/machinekind/openproject:1.1.0@sha256:../../x"
check "19 digest cannot leave the backup directory" count_files "$BACKUP_DIR/db-predeploy-untagged-*-_______.dump" 1
cleanup

setup
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "20 no healthy-schema file exits 1" [ "$rc" -eq 1 ]
check "20 old image not restarted" [ "$(up_count)" -eq 1 ]
cleanup

setup
healthy_schema "$FP1 $OLD"
: > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "21 psql failure exits 1" [ "$rc" -eq 1 ]
check "21 old image not restarted" [ "$(up_count)" -eq 1 ]
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' ERROR > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "22 malformed fingerprint exits 1" [ "$rc" -eq 1 ]
check "22 old image not restarted" [ "$(up_count)" -eq 1 ]
cleanup

setup
healthy_schema "$FP1 $OLD"
echo /backups/earlier.dump > "$t/stack/.deploy/last-dump"
printf '%s\n%s\n' "$FP1" "$FP1" > "$STUB/fingerprints"
export STUB_UNHEALTHY_IMAGE="$NEW"
run_deploy "$NEW"
check "23 restart still happens with an earlier last-dump" calls_has "up $OLD"
check "23 last-dump is unchanged" [ "$(cat "$t/stack/.deploy/last-dump")" = /backups/earlier.dump ]
cleanup

setup
healthy_schema "$FP1 $OLD"
run_deploy "$NEW"
check "24 healthy deploy with unreadable schema exits 0" [ "$rc" -eq 0 ]
check "24 healthy-schema removed" [ ! -e "$t/stack/.deploy/healthy-schema" ]
cleanup

setup
healthy_schema "$FP1 $OLD"
cp "$t/stack/.deploy/healthy-schema" "$t/hs.before"
printf '%s\n' "$FP2" > "$STUB/fingerprints"
export STUB_UP_RC=1
run_deploy "$NEW"
check "24 failed deploy leaves healthy-schema unchanged" cmp -s "$t/hs.before" "$t/stack/.deploy/healthy-schema"
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UP_RC=1 STUB_UP_FAIL_IMAGE="$NEW" STUB_SEEDER_RC=1
run_deploy "$NEW"
check "25 failed seeder exits 1" [ "$rc" -eq 1 ]
check "25 failed seeder restarts nothing" [ "$(up_count)" -eq 1 ]
check "25 schema not read" calls_lacks psql
check "25 stderr names the seeder" err_has "did not run $NEW to exit code 0"
check "25 last-dump recorded" file_has "$t/stack/.deploy/last-dump" "$BACKUP_DIR/db-predeploy-1.1.0-"
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UP_RC=1 STUB_SEEDER_UNTOUCHED=1
run_deploy "$NEW"
check "26 seeder still on the old image restarts nothing" [ "$(up_count)" -eq 1 ]
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_UNHEALTHY_IMAGE="$NEW" STUB_SEEDER_STARTED=2000-01-01T00:00:00.000000000Z
run_deploy "$NEW"
check "27 seeder from before this attempt restarts nothing" [ "$(up_count)" -eq 1 ]
cleanup

setup
healthy_schema "$FP1 $OLD"
echo "$Z" > "$t/stack/.deploy/previous-image"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_HEALTH=unhealthy
run_deploy "$NEW"
check "28 unhealthy restart exits 1" [ "$rc" -eq 1 ]
check "28 restart attempted" [ "$(up_count)" -eq 2 ]
check "28 stderr says restart failed" err_has "did not become healthy either"
check "28 previous-image is old" [ "$(cat "$t/stack/.deploy/previous-image")" = "$OLD" ]
check "28 no restore advice" bash -c '! grep -qF "make rollback, which deploys" "$1"' _ "$t/err"
check "28 no pending previous image" [ ! -e "$t/stack/.deploy/previous-image.pending" ]
cleanup

setup
export STUB_HEALTH=unhealthy
run_deploy
check "29 failed deploy without argument exits 1" [ "$rc" -eq 1 ]
check "29 says no switch happened" err_has "No image switch happened"
check "29 no rollback advice" bash -c '! grep -qF "make rollback" "$1"' _ "$t/err"
check "29 no last-dump" [ ! -e "$t/stack/.deploy/last-dump" ]
check "29 .env unchanged" env_has "OPENPROJECT_IMAGE=$OLD"
check "29 no previous-image" [ ! -e "$t/stack/.deploy/previous-image" ]
cleanup

setup
export STUB_HEALTH=unhealthy
run_deploy "$OLD"
check "30 failed redeploy of the same image exits 1" [ "$rc" -eq 1 ]
check "30 says no switch happened" err_has "No image switch happened"
check "30 no last-dump" [ ! -e "$t/stack/.deploy/last-dump" ]
check "30 no previous-image" [ ! -e "$t/stack/.deploy/previous-image" ]
cleanup

setup
mkdir -p "$BACKUP_DIR" "$t/stack/.deploy"
for n in 1 2 3 4; do
  f="$BACKUP_DIR/db-predeploy-old$n-202001010000.dump"
  echo x > "$f"
  touch -d "2020-01-0$n" "$f"
done
echo "$BACKUP_DIR/db-predeploy-old1-202001010000.dump" > "$t/stack/.deploy/last-dump"
export STUB_UP_RC=1
run_deploy "$NEW"
check "31 failure without restart exits 1" [ "$rc" -eq 1 ]
check "31 last-dump unchanged" [ "$(cat "$t/stack/.deploy/last-dump")" = "$BACKUP_DIR/db-predeploy-old1-202001010000.dump" ]
check "31 last-dump target kept" [ -e "$BACKUP_DIR/db-predeploy-old1-202001010000.dump" ]
check "31 fourth newest dump removed" [ ! -e "$BACKUP_DIR/db-predeploy-old2-202001010000.dump" ]
check "31 four dumps remain" count_files "$BACKUP_DIR/db-predeploy-*.dump" 4
cleanup

setup
mkdir -p "$t/stack/.deploy"
echo sha256:z > "$t/stack/.deploy/previous-image-id"
printf '%s\n' 'ghcr.io/machinekind/openproject sha256:new' 'ghcr.io/machinekind/openproject sha256:old' 'ghcr.io/machinekind/openproject sha256:z' 'ghcr.io/machinekind/openproject sha256:older' > "$STUB/images"
echo c1 > "$STUB/containers"
echo sha256:new > "$STUB/container_images"
export STUB_UP_RC=1
run_deploy "$NEW"
check "32 failure without restart exits 1" [ "$rc" -eq 1 ]
check "32 previous-image-id is the old id" [ "$(cat "$t/stack/.deploy/previous-image-id")" = sha256:old ]
check "32 older image removed" calls_has "rm sha256:older"
check "32 image before old removed" calls_has "rm sha256:z"
check "32 image a container uses kept" calls_lacks "rm sha256:new"
check "32 old image kept" calls_lacks "rm sha256:old"
cleanup

setup
healthy_schema "$FP1 $OLD"
printf '%s\n' "$FP1" > "$STUB/fingerprints"
export STUB_HEALTH=unhealthy STUB_SEEDER_STATUS=running
run_deploy "$NEW"
check "36 running seeder exits 1" [ "$rc" -eq 1 ]
check "36 running seeder restarts nothing" [ "$(up_count)" -eq 1 ]
check "36 schema not read" calls_lacks psql
check "36 stderr says the seeder is still running" err_has "seeder of this attempt is still running"
check "36 .env names old again" env_has "OPENPROJECT_IMAGE=$OLD"
cleanup

kit_files() { mkdir -p "$t/stack/ops/remote"; echo compose > "$t/stack/docker-compose.yml"; echo caddy > "$t/stack/Caddyfile"; echo ci > "$t/stack/ops/remote/ci-deploy.sh"; }
kit_sum() { (cd "$t/stack" && sha256sum deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh | sha256sum | cut -c1-64); }

setup
kit_files
EXPECTED_KIT_SHA256="$(kit_sum)"
export EXPECTED_KIT_SHA256
run_deploy "$NEW"
check "33 matching kit checksum deploys" [ "$rc" -eq 0 ]
cleanup

setup
kit_files
EXPECTED_KIT_SHA256="$(printf 'e%.0s' $(seq 1 64))"
export EXPECTED_KIT_SHA256
run_deploy "$NEW"
check "34 changed kit exits 1" [ "$rc" -eq 1 ]
check "34 stderr says the kit changed" err_has "kit changed since the check"
check "34 no docker calls" [ ! -e "$STUB/calls" ]
check "34 .env unchanged" env_has "OPENPROJECT_IMAGE=$OLD"
cleanup

setup
export EXPECTED_KIT_SHA256=xyz
run_deploy "$NEW"
check "35 malformed kit checksum exits 2" [ "$rc" -eq 2 ]
check "35 no docker calls" [ ! -e "$STUB/calls" ]
cleanup

if [ "$failures" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
fi
echo "$failures check(s) failed"
exit 1
