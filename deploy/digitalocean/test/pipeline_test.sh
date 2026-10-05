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
  "api repos/machinekind/openproject/git/ref/heads/dev --jq .object.sha") printf '%s\n' "${STUB_DEV_TIP:-}" ;;
  "api repos/machinekind/openproject/compare/"*) echo "$*" >> "${STUB_CALLS:-/dev/null}"; [ "${STUB_COMPARE:-}" != fail ] || exit 1; printf '%s\n' "${STUB_COMPARE:-ahead}" ;;
  "pr list --repo machinekind/openproject --base dev --state merged --label release:minor "*) printf '%b\n' "${STUB_MINOR_MERGES-}" ;;
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
    img="\${last#deploy }"
    echo pulling
    echo 'DATABASE_URL=postgres://u:topsecret@h/db'
    echo "running: \${STUB_RUNNING:-\${img%% *}}"
    exit \${STUB_SSH_RC:-0} ;;
esac
STUB
chmod +x "$t/bin/"*

run() {
  : > "$t/out"; : > "$t/sum"; : > "$t/ssh_args"; : > "$t/calls"
  out="$(env -u GITHUB_RUN_ATTEMPT PATH="$t/bin:$PATH" STUB_CALLS="$t/calls" OP_CONF_DIR="$t/conf" OP_SOURCE_DIR="$t/src" REPO=machinekind/openproject \
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
nonzero "d major refused on push" "$rc"
contains "d message" "$err" "only from workflow_dispatch"
nv SHA="$B" BUMP=bogus
nonzero "d2 unknown bump refused" "$rc"
contains "d2 message" "$err" "patch, minor or major"
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
dnv() { nv EVENT_NAME=workflow_dispatch ACTOR=alice DEPLOY_DISPATCHERS='bob,alice' "$@"; }
dnv SHA="$B" BUMP=major
check "s1 dispatch major exit" "$rc" 0
contains "s1 dispatch major tag" "$gho" "tag=2.0.0"
dnv SHA="$B" BUMP=major STUB_LABELS='release:minor'
contains "s2 label does not lower major" "$gho" "tag=2.0.0"
dnv SHA="$C" BUMP=major
contains "s3 major passes the migration gate" "$gho" "tag=2.0.0"
dnv SHA="$B" BUMP=minor ACTOR=mallory
nonzero "s4 dispatch by an unlisted login" "$rc"
contains "s4 message" "$err" "DEPLOY_DISPATCHERS"
dnv SHA="$B" ACTOR=ali
nonzero "s5 prefix of a login refused" "$rc"
dnv SHA="$B" DEPLOY_DISPATCHERS=
nonzero "s6 empty allowlist refuses" "$rc"
nv SHA="$A" STUB_BASE_SHA="$B"
nonzero "t1 release not an ancestor" "$rc"
contains "t1 message" "$err" "is not an ancestor"
check "t1 no tag" "$gho" ""
nv SHA="$D" STUB_MINOR_MERGES="$C"
contains "u1 labelled merge in range makes minor" "$gho" "tag=1.3.0"
nv SHA="$B" STUB_MINOR_MERGES="$C"
contains "u2 labelled merge after sha ignored" "$gho" "tag=1.2.4"
nv SHA="$D" STUB_BASE_SHA="$C" STUB_MINOR_MERGES="$B"
nonzero "u3 labelled merge before the release ignored" "$rc"
contains "u3 message" "$err" "release:minor"
nv SHA="$B" STUB_MINOR_MERGES="$(printf '0%.0s' $(seq 1 40))\nnot-a-sha"
contains "u4 unknown merge commits ignored" "$gho" "tag=1.2.4"
nv SHA="$B" STUB_BASE_SHA="$B" STUB_LABELS='release:minor'
nonzero "v1 released commit refused" "$rc"
contains "v1 message" "$err" "already released as 1.2.3"
check "v1 no tag" "$gho" ""

C64="$(printf 'c%.0s' $(seq 1 64))"
V="ghcr.io/machinekind/openproject:1.2.4@sha256:$C64"
ri() { run EVENT_NAME=workflow_dispatch ACTOR=alice DEPLOY_DISPATCHERS='bob,alice' SHA="$B" STUB_DEV_TIP="$B" "$@" bash "$P" resolve-image; }
ri INPUT_IMAGE="$V" BUILT_IMAGE=
check "i exit" "$rc" 0
contains "i image" "$gho" "image=$V"
ri INPUT_IMAGE= BUILT_IMAGE="$V"
contains "j image" "$gho" "image=$V"
ri EVENT_NAME=push ACTOR=mallory INPUT_IMAGE= BUILT_IMAGE="$V"
check "j4 push at the dev tip exit" "$rc" 0
contains "j4 push image" "$gho" "image=$V"
ri EVENT_NAME=push INPUT_IMAGE= BUILT_IMAGE="$V" STUB_DEV_TIP="$C" STUB_COMPARE=ahead
check "j13 push behind the tip, ahead exit" "$rc" 0
contains "j13 image" "$gho" "image=$V"
contains "j13 compare call" "$(cat "$t/calls")" "$B...$C"
ri EVENT_NAME=push INPUT_IMAGE= BUILT_IMAGE="$V" STUB_DEV_TIP="$C" STUB_COMPARE=diverged
nonzero "j14 push off dev refused" "$rc"
contains "j14 message" "$err" "not on dev any more"
check "j14 no image output" "$gho" ""
ri EVENT_NAME=push GITHUB_RUN_ATTEMPT=2 INPUT_IMAGE= BUILT_IMAGE="$V" STUB_DEV_TIP="$C"
nonzero "j15 re-run behind the tip refused" "$rc"
contains "j15 message" "$err" "dev has moved on"
check "j15 no compare call" "$(cat "$t/calls")" ""
check "j15 no image output" "$gho" ""
ri INPUT_IMAGE= BUILT_IMAGE="$V" STUB_DEV_TIP="$C"
nonzero "j16 build dispatch behind the tip refused" "$rc"
contains "j16 message" "$err" "dev has moved on"
ri EVENT_NAME=push INPUT_IMAGE= BUILT_IMAGE="$V" STUB_DEV_TIP="$C" STUB_COMPARE=fail
nonzero "j17 compare failure refused" "$rc"
contains "j17 message" "$err" "could not compare"
ri ACTOR=mallory INPUT_IMAGE="$V"
nonzero "j6 image dispatch by an unlisted login" "$rc"
contains "j6 message" "$err" "DEPLOY_DISPATCHERS"
check "j6 no image output" "$gho" ""
ri ACTOR=mallory INPUT_IMAGE= BUILT_IMAGE="$V"
nonzero "j7 build dispatch by an unlisted login" "$rc"
ri DEPLOY_DISPATCHERS='alice2 bob' INPUT_IMAGE="$V"
nonzero "j8 longer login does not match" "$rc"
ri DEPLOY_DISPATCHERS=' bob ,  alice ' INPUT_IMAGE="$V"
nonzero "j9 spaces around logins refused" "$rc"
contains "j9 message" "$err" "not GitHub logins separated by commas"
ri ACTOR=Alice INPUT_IMAGE="$V"
check "j11 login case is ignored" "$rc" 0
ri DEPLOY_DISPATCHERS= INPUT_IMAGE="$V"
nonzero "j12 unset allowlist refused" "$rc"
contains "j12 message" "$err" "missing, empty"
ri EVENT_NAME=push INPUT_IMAGE="$V"
nonzero "j10 image input on push refused" "$rc"
contains "j10 message" "$err" "only from workflow_dispatch"
ri INPUT_IMAGE="$V" DEPLOY_HOST_NAME=op.example.org
contains "j2 host output" "$gho" "host=op.example.org"
ri INPUT_IMAGE="$V" DEPLOY_HOST_NAME=
nonzero "j3 empty host fails" "$rc"
contains "j3 message" "$err" "DEPLOY_HOST_NAME is empty"
for bad in "ghcr.io/other/openproject:1.2.4@sha256:$C64" "ghcr.io/machinekind/openproject:1.2.4" "$V " "$V"$'\nx'; do
  ri INPUT_IMAGE="$bad"
  nonzero "k rejects $(printf '%s' "$bad" | head -n 1 | cut -c1-50)" "$rc"
done

gt() { run EVENT_NAME=workflow_dispatch ACTOR=alice DEPLOY_DISPATCHERS='bob,alice' SHA="$B" STUB_DEV_TIP="$B" "$@" bash "$P" gate; }
gt
check "k1 listed login allowed" "$rc" 0
gt ACTOR=mallory
nonzero "k2 unlisted login refused" "$rc"
gt DEPLOY_DISPATCHERS='bob alice'
nonzero "k3 malformed list refused" "$rc"
gt EVENT_NAME=push ACTOR=mallory STUB_DEV_TIP="$C"
check "k4 first push attempt passes without a tip check" "$rc" 0
gt EVENT_NAME=push ACTOR=mallory GITHUB_RUN_ATTEMPT=2
check "k5 re-run at the tip passes" "$rc" 0
gt EVENT_NAME=push ACTOR=mallory GITHUB_RUN_ATTEMPT=2 STUB_DEV_TIP="$C"
nonzero "k6 re-run behind the tip refused" "$rc"
contains "k6 message" "$err" "dev has moved on"
gt GITHUB_RUN_ATTEMPT=2 STUB_DEV_TIP="$C"
nonzero "k7 re-run of a build dispatch behind the tip refused" "$rc"
gt GITHUB_RUN_ATTEMPT=2 STUB_DEV_TIP="$C" INPUT_IMAGE="$V"
check "k8 re-run of an image dispatch skips the tip check" "$rc" 0
gt GITHUB_RUN_ATTEMPT=2 ACTOR=mallory INPUT_IMAGE="$V"
nonzero "k9 re-run by an unlisted login refused" "$rc"

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
KIT="$(cd "$here" && sha256sum deploy.sh docker-compose.yml Caddyfile ops/remote/ci-deploy.sh | sha256sum | cut -c1-64)"
check "l deploy sends the kit checksum" "$(tail -n 1 "$t/ssh_args" | awk '{ print $(NF-2), $(NF-1), $NF }')" "deploy $V $KIT"
rd STUB_VERSION_OUT='0000  deploy.sh'
nonzero "m drift" "$rc"
contains "m message" "$err" "make -C deploy/digitalocean push"
case "$(cat "$t/ssh_args")" in *"deploy $V"*) not_ok "m deploy not attempted" ;; *) ok "m deploy not attempted" ;; esac
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
rd DEPLOY_SSH_KEY=
nonzero "r1 empty key" "$rc"
contains "r1 message" "$err" "triggered by a bot"
contains "r1 names ci-setup" "$err" "make ci-setup"
rd STUB_ADD_RC=1
nonzero "q bad key" "$rc"
contains "q message" "$err" "not a usable private key"

run bash "$P" bogus
nonzero "unknown command" "$rc"
contains "unknown command message" "$err" "unknown command"

rm -rf "$t"
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
