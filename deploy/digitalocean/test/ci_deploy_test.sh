#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 (missing '$3' in '$2')" ;; esac; }

D="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
VALID="ghcr.io/machinekind/openproject:1.2.3@sha256:$D"
K="$(printf 'abcdef0123456789%.0s' 1 2 3 4)"

setup() {
  t="$(mktemp -d)"
  mkdir -p "$t/srv/ops/remote" "$t/bin"
  cp "$here/ops/remote/ci-deploy.sh" "$t/srv/ops/remote/"
  echo compose > "$t/srv/docker-compose.yml"
  echo caddy > "$t/srv/Caddyfile"
  cat > "$t/srv/deploy.sh" <<'STUB'
#!/usr/bin/env bash
echo "deploy.sh $*"
echo "kit=${EXPECTED_KIT_SHA256:-}"
echo "running: $1"
exit ${STUB_DEPLOY_RC:-0}
STUB
  chmod +x "$t/srv/deploy.sh"
  cat > "$t/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "compose ps -q web" ]; then echo "${STUB_WEB_ID-web1}"; exit 0; fi
case "$*" in inspect*) echo running-image ;; *) exit 99 ;; esac
STUB
  chmod +x "$t/bin/docker"
}

run() {
  out="$(PATH="$t/bin:$PATH" bash "$t/srv/ops/remote/ci-deploy.sh" ignored-arg 2>"$t/err")"
  rc=$?
  err="$(cat "$t/err")"
}

setup
unset SSH_ORIGINAL_COMMAND
run
check "unset command exits 2" "$rc" 2
contains "unset command message" "$err" "refused: malformed command"

refused_cases=(
  "deploy"
  "deploy ghcr.io/machinekind/openproject:1.2.3"
  "deploy ghcr.io/evil/openproject:1.2.3@sha256:$D"
  "deploy docker.io/machinekind/openproject:1.2.3@sha256:$D"
  "deploy ghcr.io/machinekind/openproject:1.2.3@sha256:${D:1}"
  "deploy ghcr.io/machinekind/openproject:1.2.3@sha256:${D^^}"
  "deploy $VALID;id"
  "deploy $VALID"
  "deploy $VALID extra"
  $'deploy '"$VALID"$'\nid'
  "shell"
  "rm -rf /"
  "status now"
  "version x"
  "deploy $VALID ${K^^}"
  "deploy $VALID ${K:1}"
  "deploy $VALID $K extra"
  "deploy $K"
  "version $K"
  "status $K"
)
for c in "${refused_cases[@]}"; do
  export SSH_ORIGINAL_COMMAND="$c"
  run
  check "refuses '${c//$'\n'/\\n}' with 2" "$rc" 2
  case "$out" in *deploy.sh*) not_ok "stub not run for '${c//$'\n'/\\n}'" ;; *) ok "stub not run for '${c//$'\n'/\\n}'" ;; esac
done

export SSH_ORIGINAL_COMMAND="deploy $VALID $K"
run
check "deploy exits 0" "$rc" 0
contains "deploy passes the image alone" "$out" "deploy.sh $VALID"$'\n'
contains "deploy passes the kit checksum" "$out" "kit=$K"
check "deploy last line" "$(echo "$out" | tail -n 1)" "running: $VALID"
contains "deploy log" "$(cat "$t/srv/.deploy/ci-deploy.log")" "running: $VALID"

STUB_DEPLOY_RC=1 run
check "failing deploy exits 1" "$rc" 1

touch "$t/srv/DEPLOY_PAUSED"
run
check "paused exits 2" "$rc" 2
contains "paused message" "$err" "paused"
case "$out" in *deploy.sh*) not_ok "paused stub not run" ;; *) ok "paused stub not run" ;; esac
rm "$t/srv/DEPLOY_PAUSED"

export SSH_ORIGINAL_COMMAND="version"
run
check "version exits 0" "$rc" 0
check "version output" "$out" "$(cd "$t/srv" && sha256sum deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh)"
check "version has 4 lines" "$(echo "$out" | wc -l | tr -d ' ')" 4

export SSH_ORIGINAL_COMMAND="status"
run
check "status exits 0" "$rc" 0
check "status output" "$out" "running-image"

STUB_WEB_ID="" run
check "status with stopped web exits 1" "$rc" 1
check "status with stopped web output" "$out" "web not running"

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
