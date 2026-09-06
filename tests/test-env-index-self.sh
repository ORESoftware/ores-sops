#!/usr/bin/env bash
set +x
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$tmp/repo/scripts"
cd "$tmp/repo"
git init -q --template=
cp "$source_root/scripts/check-env-index.sh" scripts/
git add scripts/check-env-index.sh
bash scripts/check-env-index.sh >/dev/null
for kind in '' 'RSA ' 'OPENSSH '; do
  printf -- '-----BE%s%sPRIVATE KEY-----\n' 'GIN ' "$kind" > candidate.txt
  git add candidate.txt
  if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
    echo 'expected synthetic private-key header rejection' >&2; exit 1
  fi
  ! grep -q 'PRIVATE KEY' "$tmp/output"
done
printf 'PASS: scanner self-scan and three private-key header regressions\n'
