#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

calls="$tmp/calls.txt"
fake_oresc="$tmp/oresc"
cat >"$fake_oresc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${ORESC_TEST_CALLS:?}"
SH
chmod +x "$fake_oresc"

(
  cd "$repo_root"
  ORESC_BIN="$fake_oresc" ORESC_TEST_CALLS="$calls" bash scripts/oresc-audit.sh
)

first_call="$(sed -n '1p' "$calls")"
second_call="$(sed -n '2p' "$calls")"
[[ "$first_call" == '--no-json audit repo --path . --profile standards' ]] || {
  printf 'unexpected repository audit invocation: %s\n' "$first_call" >&2
  exit 1
}
[[ -z "$second_call" ]] || {
  printf 'expected one ores-cli invocation, found an extra call: %s\n' "$second_call" >&2
  exit 1
}

set +e
missing_output="$(
  cd "$repo_root"
  ORESC_BIN="$tmp/does-not-exist" bash scripts/oresc-audit.sh 2>&1
)"
missing_status=$?
set -e
[[ $missing_status -eq 70 ]] || {
  printf 'missing ores-cli must exit 70, got %s\n' "$missing_status" >&2
  exit 1
}
[[ "$missing_output" == *'oresc is required'* ]] || {
  echo 'missing ores-cli error did not explain the dependency' >&2
  exit 1
}

printf 'ores-sops oresc policy wrapper contract: ok\n'
