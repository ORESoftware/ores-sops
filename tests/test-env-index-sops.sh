#!/usr/bin/env bash
# Test-only local age identities; no provider or production secret access.
set +x
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' HUP INT TERM
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SOPS_AGE_KEY_FILE="$tmp/test-identity.txt"
unset SOPS_AGE_KEY SOPS_AGE_KEY_CMD || true
mkdir -p "$HOME" "$tmp/repo/env/enc"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
recipient=$(age-keygen -y "$SOPS_AGE_KEY_FILE")
cd "$tmp/repo"
git init -q --template=
printf 'EXAMPLE=fixture-only\n' > "$tmp/source.txt"
for profile in dev prod; do
  sops encrypt --input-type dotenv --output-type dotenv --age "$recipient" \
    "$tmp/source.txt" > "env/enc/$profile.env.enc"
  git add "env/enc/$profile.env.enc"
  bash "$source_root/scripts/check-env-index.sh"
  sops decrypt --input-type dotenv --output-type dotenv "env/enc/$profile.env.enc" \
    | cmp - "$tmp/source.txt"
done
printf 'PASS: generated SOPS dev/prod serialization and test-only round trips\n'
