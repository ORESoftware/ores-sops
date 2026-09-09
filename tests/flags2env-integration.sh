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

# Exercise the real config auditor before building the isolated wrapper fixture.
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

# If dotenv loading ever regresses, the canonical parser can see this file.
# ores-sops deliberately disables that lane in .cli-flags.toml.
cat >"${TMP}/.env" <<'EOF'
ORES_SOPS_ENVIRONMENT=prod
EOF

export CORE_ARGS_CAPTURE="${TMP}/core-args"
unset ORES_SOPS_ENVIRONMENT || true

# Valid scoped flags must pass and normalize into the legacy core shape.
"${TMP}/ores-sops" use --environment=stage --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force stage$' "${CORE_ARGS_CAPTURE}"
grep -q '"event":"command_completed"' "${TMP}/err"

# Unknown flags must be rejected by the real flags2env unknown-options channel.
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

# Invalid typed values must be rejected through the errors channel.
if "${TMP}/ores-sops" use dev --force=definitely-not-a-bool >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected real flags2env to reject an invalid bool" >&2
  exit 1
fi
grep -q '"event":"argv_admission_rejected"' "${TMP}/err"

# Top-level aliases are normalized only for admission; the core still receives
# the original public argv so legacy behavior remains intact.
"${TMP}/ores-sops" --help >"${TMP}/out" 2>"${TMP}/err"
grep -q '^--help$' "${CORE_ARGS_CAPTURE}"

# Process-env fallback remains explicit; the local .env sentinel must not become
# the wrapper's environment source when ORES_SOPS_ENVIRONMENT is unset.
unset ORES_SOPS_ENVIRONMENT || true
rm -f "${CORE_ARGS_CAPTURE}"
if "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"; then
  echo "expected missing process environment despite local .env sentinel" >&2
  exit 1
fi
grep -q '"event":"required_env_missing"' "${TMP}/err"
[[ ! -e "${CORE_ARGS_CAPTURE}" ]]

ORES_SOPS_ENVIRONMENT=prod "${TMP}/ores-sops" use --force >"${TMP}/out" 2>"${TMP}/err"
grep -q '^use --force prod$' "${CORE_ARGS_CAPTURE}"

echo "flags2env integration tests: ok"
