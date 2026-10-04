#!/usr/bin/env bash
# Installs or removes the GitHub Actions deploy key in root's authorized_keys. make ci-setup and make ci-revoke run it
# over the operator's own SSH session; the deploy key itself can never reach it.
set -euo pipefail
umask 077
keys="${OP_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
forced="$(cd "$(dirname "$0")" && pwd)/ci-deploy.sh"
comment=github-actions-deploy
pub_re="^ssh-ed25519 [A-Za-z0-9+/]+={0,2} $comment\$"
die() { echo "error: $*" >&2; exit 1; }
others() { grep -v -E " $comment\$" "$keys" || [ $? -eq 1 ]; }

[ -f "$keys" ] || die "$keys does not exist"
case "${1:-}" in
  install)
    pub="$(head -n 1)"
    [[ $pub =~ $pub_re ]] || die "stdin must be one ssh-ed25519 public key with the comment $comment"
    others > "$keys.tmp"
    printf 'restrict,command="%s" %s\n' "$forced" "$pub" >> "$keys.tmp"
    ;;
  remove)
    others > "$keys.tmp"
    ;;
  *)
    die "usage: ci-key.sh install|remove"
    ;;
esac
remaining="$(grep -v -E " $comment\$" "$keys.tmp" | grep -c -v -E '^[[:space:]]*(#|$)' || true)"
[ "$remaining" -ge 1 ] || { rm -f "$keys.tmp"; die "refusing: no other key would remain in $keys"; }
chmod 600 "$keys.tmp"
mv "$keys.tmp" "$keys"
echo "ok: $1"
