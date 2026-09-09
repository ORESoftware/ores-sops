#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v flags2env >/dev/null 2>&1 || {
  echo "flags2env integration test requires the canonical CLI on PATH" >&2
  exit 2
}
command -v node >/dev/null 2>&1 || {
  echo "flags2env integration test requires node on PATH" >&2
  exit 2
}

case_label() {
  printf 'flags2env-case: %s\n' "$1"
}

case_label config-audit
(cd "${ROOT}" && flags2env audit ./.cli-flags.toml >/dev/null)

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/scripts"
cp "${ROOT}/ores-sops" "${TMP}/ores-sops"
cp "${ROOT}/scripts/ores-sops-telemetry" "${TMP}/scripts/ores-sops-telemetry"
cp "${ROOT}/.cli-flags.toml" "${TMP}/.cli-flags.toml"
chmod +x "${TMP}/ores-sops" "${TMP}/scripts/ores-sops-telemetry"

cat >"${TMP}/scripts/ores-sops-core" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${CORE_ARGS_CAPTURE:?}"
exit "${CORE_EXIT_CODE:-0}"
EOF
chmod +x "${TMP}/scripts/ores-sops-core"

cat >"${TMP}/.env" <<'EOF'
ORES_SOPS_ENVIRONMENT=prod
EOF

export CORE_ARGS_CAPTURE="${TMP}/core-args"
unset ORES_SOPS_ENVIRONMENT || true

case_label environment-flag
"${TMP}/ores-sops" use --environment=stage --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force stage$' "${CORE_ARGS_CAPTURE}"
grep -q '"event":"command_completed"' "${TMP}/err"

case_label positional-environment
"${TMP}/ores-sops" use dev --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force dev$' "${CORE_ARGS_CAPTURE}"

case_label unknown-option
rm -f "${CORE_ARGS_CAPTURE}"
if "${TMP}/ores-sops" use dev --synthetic-unknown-option >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected real flags2env to reject an unknown option" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]
if grep -q 'synthetic-unknown-option' "${TMP}/err"; then
  echo "unknown option leaked to wrapper stderr" >&2
  exit 1
fi

case_label invalid-bool
if "${TMP}/ores-sops" use dev --force=definitely-not-a-bool >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected real flags2env to reject an invalid bool" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"

case_label extra-positional
rm -f "${CORE_ARGS_CAPTURE}"
if "${TMP}/ores-sops" status synthetic-extra-operand >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected extra positional operand to fail" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]
if grep -q 'synthetic-extra-operand' "${TMP}/err"; then
  echo "extra operand leaked to wrapper stderr" >&2
  exit 1
fi

case_label dashdash-bypass
if "${TMP}/ores-sops" status -- --synthetic-after-dashdash >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected operand after bare -- to fail" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"
if grep -q 'synthetic-after-dashdash' "${TMP}/err"; then
  echo "post-dashdash operand leaked to wrapper stderr" >&2
  exit 1
fi

case_label help-alias
"${TMP}/ores-sops" --help >"${TMP}/out" 2>"${TMP}/err"
grep -q '^--help$' "${CORE_ARGS_CAPTURE}"

case_label version-alias
"${TMP}/ores-sops" --version >"${TMP}/out" 2>"${TMP}/err"
grep -q '^--version$' "${CORE_ARGS_CAPTURE}"

case_label empty-argv
"${TMP}/ores-sops" >"${TMP}/out" 2>"${TMP}/err"
[[ ! -s "${CORE_ARGS_CAPTURE}" ]]

case_label dotenv-disabled
unset ORES_SOPS_ENVIRONMENT || true
rm -f "${CORE_ARGS_CAPTURE}"
if "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected missing process environment despite local .env sentinel" >&2
  exit 1
fi
grep -q '"event":"required_env_missing"' "${TMP}/err"
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]

case_label process-env-fallback
ORES_SOPS_ENVIRONMENT=prod "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force prod$' "${CORE_ARGS_CAPTURE}"

echo "flags2env integration tests: ok"
