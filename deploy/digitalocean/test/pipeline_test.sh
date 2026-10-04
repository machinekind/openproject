#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
P="$here/ops/pipeline.sh"
fails=0
ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 (missing '$3' in '$2')" ;; esac; }
nonzero() { if [ "$2" -ne 0 ]; then ok "$1"; else not_ok "$1 (exit 0)"; fi; }

t="$(mktemp -d)"
mkdir -p "$t/bin" "$t/rt" "$t/src"
git_() { git -C "$t/src" -c user.name=t -c user.email=t@example.org "$@"; }
git -c init.defaultBranch=main init -q "$t/src"
mkdir -p "$t/src/lib/open_project"
printf '    MAJOR = 18\n    MINOR = 0\n    PATCH = 0\n' > "$t/src/lib/open_project/version.rb"
git_ add -A; git_ commit -q -m A; A="$(git_ rev-parse HEAD)"
echo readme > "$t/src/README"
git_ add -A; git_ commit -q -m B; B="$(git_ rev-parse HEAD)"
mkdir -p "$t/src/db/migrate"; echo x > "$t/src/db/migrate/20261001000000_add_x.rb"
git_ add -A; git_ commit -q -m C; C="$(git_ rev-parse HEAD)"
mkdir -p "$t/src/modules/foo/db/migrate"; echo y > "$t/src/modules/foo/db/migrate/20261002000000_add_y.rb"
git_ add -A; git_ commit -q -m D; D="$(git_ rev-parse HEAD)"

cat > "$t/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"release list"*"--json tagName "*) printf '%b\n' "${STUB_RELEASES-1.2.3\n17.8.0-mcp.1}" ;;
  "api repos/machinekind/openproject/tags --paginate"*) printf '%b\n' "${STUB_TAGS-v17.0.0}" ;;
  "api repos/machinekind/openproject/commits/"*"/pulls"*) printf '%b\n' "${STUB_LABELS-}" ;;
  "api repos/machinekind/openproject/commits/1.2.3 --jq .sha") printf '%s\n' "$STUB_BASE_SHA" ;;
  *) echo "unexpected gh $*" >&2; exit 99 ;;
esac
STUB
cat > "$t/bin/ssh-agent" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo 'SSH_AUTH_SOCK=/tmp/none; export SSH_AUTH_SOCK; SSH_AGENT_PID=1; export SSH_AGENT_PID;' ;;
  -k) exit 0 ;;
esac
STUB
cat > "$t/bin/ssh-add" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-L" ]; then echo 'ssh-ed25519 AAAAtest github-actions-deploy'; exit 0; fi
for last; do :; done
if [ "\$last" = "-" ]; then cat > "$t/added"; fi
exit \${STUB_ADD_RC:-0}
STUB
cat > "$t/bin/ssh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$t/ssh_args"
for a; do case "\$a" in UserKnownHostsFile=*) cp "\${a#UserKnownHostsFile=}" "$t/kh_seen" ;; esac; done
for last; do :; done
if [ "\$last" = version ]; then
  if [ -n "\${STUB_VERSION_OUT:-}" ]; then echo "\$STUB_VERSION_OUT"; else (cd "$here" && sha256sum deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh); fi
  exit 0
fi
case "\$last" in
  "deploy "*)
    echo pulling
    echo 'DATABASE_URL=postgres://u:topsecret@h/db'
    echo "running: \${STUB_RUNNING:-\${last#deploy }}"
    exit \${STUB_SSH_RC:-0} ;;
esac
STUB
chmod +x "$t/bin/"*

run() {
  : > "$t/out"; : > "$t/sum"; : > "$t/ssh_args"
  out="$(env PATH="$t/bin:$PATH" OP_CONF_DIR="$t/conf" OP_SOURCE_DIR="$t/src" REPO=machinekind/openproject \
    RUNNER_TEMP="$t/rt" GITHUB_OUTPUT="$t/out" GITHUB_STEP_SUMMARY="$t/sum" "$@" 2>"$t/err")"
  rc=$?
  err="$(cat "$t/err")"; gho="$(cat "$t/out")"; sum="$(cat "$t/sum")"
}
nv() { run STUB_BASE_SHA="$A" "$@" bash "$P" next-version; }

nv SHA="$B"
check "a exit" "$rc" 0
contains "a tag" "$gho" "tag=1.2.4"
contains "a upstream" "$gho" "upstream=18.0.0"
nv SHA="$B" STUB_LABELS='release:minor'
contains "b label minor" "$gho" "tag=1.3.0"
nv SHA="$B" BUMP=minor
contains "c BUMP minor" "$gho" "tag=1.3.0"
nv SHA="$B" BUMP=major
nonzero "d major refused" "$rc"
contains "d message" "$err" "patch or minor"
nv SHA="$B" STUB_RELEASES='17.8.0-mcp.1\ndev-20260923-e33ce7f' STUB_TAGS='v17.0.0'
nonzero "e no final release" "$rc"
contains "e message" "$err" "no final release"
nv SHA="$C"
nonzero "f migration gate" "$rc"
contains "f message" "$err" "release:minor"
contains "f summary" "$sum" "db/migrate/20261001000000_add_x.rb"
nv SHA="$D" STUB_LABELS='release:minor'
contains "g tag" "$gho" "tag=1.3.0"
contains "g summary add_x" "$sum" "db/migrate/20261001000000_add_x.rb"
contains "g summary add_y" "$sum" "modules/foo/db/migrate/20261002000000_add_y.rb"
contains "g count" "$sum" "2 new migration(s)"
nv SHA=abc
nonzero "h short sha" "$rc"
contains "h message" "$err" "full commit SHA"

C64="$(printf 'c%.0s' $(seq 1 64))"
V="ghcr.io/machinekind/openproject:1.2.4@sha256:$C64"
ri() { run "$@" bash "$P" resolve-image; }
ri INPUT_IMAGE="$V" BUILT_IMAGE=
check "i exit" "$rc" 0
contains "i image" "$gho" "image=$V"
ri INPUT_IMAGE= BUILT_IMAGE="$V"
contains "j image" "$gho" "image=$V"
ri INPUT_IMAGE="$V" DEPLOY_HOST_NAME=op.example.org
contains "j2 host output" "$gho" "host=op.example.org"
ri INPUT_IMAGE="$V" DEPLOY_HOST_NAME=
nonzero "j3 empty host fails" "$rc"
contains "j3 message" "$err" "DEPLOY_HOST_NAME is empty"
for bad in "ghcr.io/other/openproject:1.2.4@sha256:$C64" "ghcr.io/machinekind/openproject:1.2.4" "$V " "$V"$'\nx'; do
  ri INPUT_IMAGE="$bad"
  nonzero "k rejects $(printf '%s' "$bad" | head -n 1 | cut -c1-50)" "$rc"
done

KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----'
HK='203.0.113.10 ssh-ed25519 AAAAhost'
rd() { rm -f "$t/added" "$t/kh_seen"; run IMAGE="$V" DEPLOY_SSH_KEY="$KEY" DEPLOY_HOST_IP=203.0.113.10 DEPLOY_SSH_HOST_KEY="$HK" "$@" bash "$P" remote-deploy; }
rd
check "l exit" "$rc" 0
args="$(cat "$t/ssh_args")"
for o in StrictHostKeyChecking=yes BatchMode=yes IdentitiesOnly=yes GlobalKnownHostsFile=/dev/null root@203.0.113.10; do contains "l ssh $o" "$args" "$o"; done
check "l known_hosts" "$(cat "$t/kh_seen")" "$HK"
check "l key via agent" "$(cat "$t/added")" "$KEY"
case "$out$err" in *topsecret*) not_ok "l output leaks secret" ;; *) ok "l output redacted" ;; esac
contains "l output shows deploy" "$out" "running: $V"
if [ -e "$t/rt/deploy-ssh" ]; then not_ok "l work dir removed"; else ok "l work dir removed"; fi
rd STUB_VERSION_OUT='0000  deploy.sh'
nonzero "m drift" "$rc"
contains "m message" "$err" "make -C deploy/digitalocean push"
case "$(cat "$t/ssh_args")" in *"deploy $V") not_ok "m deploy not attempted" ;; *) ok "m deploy not attempted" ;; esac
rd STUB_RUNNING=other
nonzero "n wrong running line" "$rc"
contains "n message" "$err" "instead of 'running:"
rd STUB_SSH_RC=1
nonzero "o ssh failure" "$rc"
contains "o message" "$err" "deploy failed on the server"
rd DEPLOY_HOST_IP='203.0.113.10;id'
nonzero "p bad ip" "$rc"
contains "p message" "$err" "IPv4"
check "p no ssh" "$(cat "$t/ssh_args")" ""
rd STUB_ADD_RC=1
nonzero "q bad key" "$rc"
contains "q message" "$err" "not a usable private key"

run bash "$P" bogus
nonzero "unknown command" "$rc"
contains "unknown command message" "$err" "unknown command"

rm -rf "$t"
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
