#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 (missing '$3' in '$2')" ;; esac; }

PERSONAL='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPersonalKey me@laptop'
K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1testkey github-actions-deploy'
K2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2testkey github-actions-deploy'

t="$(mktemp -d)"
mkdir -p "$t/ops/remote"
cp "$here/ops/remote/ci-key.sh" "$t/ops/remote/"
export OP_AUTHORIZED_KEYS="$t/authorized_keys"
script="$t/ops/remote/ci-key.sh"
echo "$PERSONAL" > "$OP_AUTHORIZED_KEYS"

run() {
  local input="$1"
  shift
  printf '%s' "$input" | bash "$script" "$@" >/dev/null 2>"$t/err"
  rc=$?
  err="$(cat "$t/err")"
}

run "$K1"$'\n' install
check "install exits 0" "$rc" 0
check "install line count" "$(wc -l < "$OP_AUTHORIZED_KEYS" | tr -d ' ')" 2
check "personal key kept" "$(sed -n 1p "$OP_AUTHORIZED_KEYS")" "$PERSONAL"
check "forced line" "$(sed -n 2p "$OP_AUTHORIZED_KEYS")" "restrict,command=\"$t/ops/remote/ci-deploy.sh\" $K1"
check "mode 600" "$(stat -c %a "$OP_AUTHORIZED_KEYS")" 600

run "$K2"$'\n' install
check "rotate exits 0" "$rc" 0
check "rotate line count" "$(wc -l < "$OP_AUTHORIZED_KEYS" | tr -d ' ')" 2
case "$(sed -n 2p "$OP_AUTHORIZED_KEYS")" in *"$K2") ok "line 2 ends with K2" ;; *) not_ok "line 2 ends with K2" ;; esac
if grep -q K1testkey "$OP_AUTHORIZED_KEYS"; then not_ok "K1 absent"; else ok "K1 absent"; fi

cp "$OP_AUTHORIZED_KEYS" "$t/before"
for bad in \
  'ssh-rsa AAAAB3 github-actions-deploy' \
  'ssh-ed25519 AAAA other-comment' \
  'ssh-ed25519 AAAA github-actions-deploy extra' \
  'x" ssh-ed25519 AAAA github-actions-deploy' \
  ''; do
  run "$bad"$'\n' install
  check "malformed '$bad' exits 1" "$rc" 1
  if cmp -s "$t/before" "$OP_AUTHORIZED_KEYS"; then ok "malformed '$bad' leaves file"; else not_ok "malformed '$bad' leaves file"; fi
done
run "" install
check "empty input exits 1" "$rc" 1
if cmp -s "$t/before" "$OP_AUTHORIZED_KEYS"; then ok "empty input leaves file"; else not_ok "empty input leaves file"; fi

run "" remove
check "remove exits 0" "$rc" 0
check "only personal remains" "$(cat "$OP_AUTHORIZED_KEYS")" "$PERSONAL"

printf 'restrict,command="/x" %s\n\n' "$K1" > "$OP_AUTHORIZED_KEYS"
cp "$OP_AUTHORIZED_KEYS" "$t/before"
run "" remove
check "last-key remove exits 1" "$rc" 1
contains "last-key message" "$err" "no other key would remain"
if cmp -s "$t/before" "$OP_AUTHORIZED_KEYS"; then ok "last-key file unchanged"; else not_ok "last-key file unchanged"; fi
if [ -e "$OP_AUTHORIZED_KEYS.tmp" ]; then not_ok "no tmp left"; else ok "no tmp left"; fi

OP_AUTHORIZED_KEYS="$t/missing" run "" remove
check "missing file exits 1" "$rc" 1
contains "missing file message" "$err" "does not exist"

run ""
check "no argument exits 1" "$rc" 1
contains "usage message" "$err" "usage"

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
