#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/scripts"
cp "${ROOT}/ores-sops" "${TMP}/ores-sops"
cp "${ROOT}/scripts/ores-sops-telemetry" "${TMP}/scripts/ores-sops-telemetry"
cp "${ROOT}/.cli-flags.toml" "${TMP}/.cli-flags.toml"
chmod +x "${TMP}/ores-sops" "${TMP}/scripts/ores-sops-telemetry"

cat >"${TMP}/bin/flags2env" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "audit" ]]; then
  if [[ "${FLAGS2ENV_TEST_AUDIT_FAIL:-0}" == "1" ]]; then
    printf 'synthetic config audit detail that must stay hidden\n' >&2
    exit 2
  fi
  printf '{"ok":true}\n'
  exit 0
fi
if [[ "${FLAGS2ENV_TEST_FAIL:-0}" == "1" ]]; then
  printf 'unsafe parser echo: %s\n' "${SYNTHETIC_SECRET_ARG:-not-set}" >&2
  exit 2
fi
command_name=""
for token in "$@"; do
  case "${token}" in
    init|use|refresh|encrypt|edit|sync-keys|diff|status|lock|verify|precommit|install-hooks|help|version)
      command_name="${token}"
      break
      ;;
  esac
done
# Canonical flat CLI parsing tracks two fixed leading program/wrapper
# positionals and omits empty unknown/error channels.
printf '{"ORES_SOPS_POSITIONALS":"[\"flags2env\",\"ores-sops\"]","ORES_SOPS_COMMAND":"%s"}\n' "${command_name}"
EOF
chmod +x "${TMP}/bin/flags2env"

cat >"${TMP}/scripts/ores-sops-core" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${CORE_ARGS_CAPTURE:?}"
exit "${CORE_EXIT_CODE:-0}"
EOF
chmod +x "${TMP}/scripts/ores-sops-core"

export PATH="${TMP}/bin:${PATH}"
export CORE_ARGS_CAPTURE="${TMP}/core-args"

# A broken .cli-flags.toml audit is a startup failure and raw audit output is hidden.
rm -f "${CORE_ARGS_CAPTURE}"
if FLAGS2ENV_TEST_AUDIT_FAIL=1 "${TMP}/ores-sops" status >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected config audit failure" >&2
  exit 1
fi
grep -q '"event":"config_invalid"' "${TMP}/err"
if grep -q 'synthetic config audit detail' "${TMP}/err"; then
  echo "config audit output leaked to stderr" >&2
  exit 1
fi
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]

# Required environment admission logs the key name, never a missing/secret value.
if ORES_SOPS_ENVIRONMENT= "${TMP}/ores-sops" use >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected missing environment to fail" >&2
  exit 1
fi
grep -q '"event":"required_env_missing"' "${TMP}/err"
grep -q '"key":"ORES_SOPS_ENVIRONMENT"' "${TMP}/err"

# Parser-controlled stderr is suppressed because argv may contain credentials.
SYNTHETIC_SECRET_ARG='synthetic-do-not-log-value' FLAGS2ENV_TEST_FAIL=1 \
  "${TMP}/ores-sops" use dev >"${TMP}/out" 2>"${TMP}/err" || true
if grep -q 'synthetic-do-not-log-value' "${TMP}/err"; then
  echo "parser-controlled value leaked to stderr" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"

# Environment fallback is normalized into the legacy core argv shape.
ORES_SOPS_ENVIRONMENT=stage "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force stage$' "${CORE_ARGS_CAPTURE}"
grep -q '"profile":"stage"' "${TMP}/err"

# Conflicting public profile inputs fail closed before the core executes.
rm -f "${CORE_ARGS_CAPTURE}"
if "${TMP}/ores-sops" use dev --environment=prod >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected conflicting environments to fail" >&2
  exit 1
fi
grep -q '"event":"environment_conflict"' "${TMP}/err"
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]

# Invalid process-env values are not reflected into telemetry or human errors.
invalid_profile='../../synthetic-secret-profile'
if ORES_SOPS_ENVIRONMENT="${invalid_profile}" "${TMP}/ores-sops" use >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected invalid environment to fail" >&2
  exit 1
fi
grep -q '"event":"invalid_environment"' "${TMP}/err"
if grep -Fq "${invalid_profile}" "${TMP}/err"; then
  echo "invalid environment value leaked to stderr" >&2
  exit 1
fi

# The telemetry helper itself rejects unknown events without echoing them.
unknown_event='synthetic-secret-event-name'
if "${TMP}/scripts/ores-sops-telemetry" "${unknown_event}" use dev '' 2 >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected unknown telemetry event to fail" >&2
  exit 1
fi
[[ ! -s "${TMP}/err" ]]

# Known events sanitize every metadata lane and bound the exit code.
"${TMP}/scripts/ores-sops-telemetry" command_failed \
  'synthetic-secret-command' 'synthetic-secret-profile' 'synthetic-secret-key' 999 \
  >"${TMP}/out" 2>"${TMP}/err"
for secret in synthetic-secret-command synthetic-secret-profile synthetic-secret-key; do
  if grep -Fq "${secret}" "${TMP}/err"; then
    echo "telemetry metadata leaked: ${secret}" >&2
    exit 1
  fi
done
grep -q '"command":"unknown"' "${TMP}/err"
grep -q '"profile":""' "${TMP}/err"
grep -q '"key":"redacted-key-name"' "${TMP}/err"
grep -q '"exitCode":1' "${TMP}/err"

# Explicit telemetry disablement must be silent and must not affect command success.
ORES_SOPS_TELEMETRY=0 "${TMP}/ores-sops" status >"${TMP}/out" 2>"${TMP}/err"
[[ ! -s "${TMP}/err" ]]
grep -q '^status$' "${CORE_ARGS_CAPTURE}"

if ! grep -Eq '^files[[:space:]]*=[[:space:]]*\[\]' "${ROOT}/.cli-flags.toml"; then
  echo ".cli-flags.toml must disable dotenv loading" >&2
  exit 1
fi

if grep -R -nE '(ghp_|lin_api_|AGE-SECRET-KEY-|BEGIN (RSA|OPENSSH) PRIVATE KEY)' \
  "${ROOT}/contracts" "${ROOT}/scripts/ores-sops-telemetry"; then
  echo "secret-like material found in runtime contract/test surfaces" >&2
  exit 1
fi

echo "runtime admission tests: ok"
