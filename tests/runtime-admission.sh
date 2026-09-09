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
if [[ "${FLAGS2ENV_TEST_FAIL:-0}" == "1" ]]; then
  printf 'unsafe parser echo: %s\n' "${SYNTHETIC_SECRET_ARG:-not-set}" >&2
  exit 2
fi
exit 0
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

if ORES_SOPS_ENVIRONMENT= "${TMP}/ores-sops" use >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected missing environment to fail" >&2
  exit 1
fi
grep -q '"event":"required_env_missing"' "${TMP}/err"
grep -q '"key":"ORES_SOPS_ENVIRONMENT"' "${TMP}/err"

SYNTHETIC_SECRET_ARG='synthetic-do-not-log-value' FLAGS2ENV_TEST_FAIL=1 \
  "${TMP}/ores-sops" use dev >"${TMP}/out" 2>"${TMP}/err" || true
if grep -q 'synthetic-do-not-log-value' "${TMP}/err"; then
  echo "parser-controlled value leaked to stderr" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"

ORES_SOPS_ENVIRONMENT=stage "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force stage$' "${CORE_ARGS_CAPTURE}"
grep -q '"profile":"stage"' "${TMP}/err"

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
