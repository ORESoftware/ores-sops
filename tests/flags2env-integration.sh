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

safe_parser_summary() {
  # Diagnostic helper for CI: it reports only command identity and channel
  # cardinalities, never flag values, argv strings, dotenv values, or errors.
  # The JavaScript body must remain a literal shell string: its template-literal
  # ${...} expressions belong to Node, not Bash.
  # shellcheck disable=SC2016
  flags2env "$@" 2>/dev/null | node -e '
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", c => { text += c; if (text.length > 262144) process.exit(2); });
    process.stdin.on("end", () => {
      try {
        const p = JSON.parse(text);
        const count = (key) => {
          if (p[key] === undefined) return 0;
          if (typeof p[key] !== "string") return -1;
          try { const v = JSON.parse(p[key]); return Array.isArray(v) ? v.length : -1; }
          catch { return -1; }
        };
        const cmd = typeof p.ORES_SOPS_COMMAND === "string" ? p.ORES_SOPS_COMMAND : "<missing>";
        console.log(`flags2env-summary: command=${cmd} positionals=${count("ORES_SOPS_POSITIONALS")} unknown=${count("ORES_SOPS_UNKNOWN_OPTIONS")} errors=${count("ORES_SOPS_PARSE_ERRORS")}`);
      } catch { console.log("flags2env-summary: invalid-json"); process.exit(2); }
    });
  '
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
(cd "${TMP}" && safe_parser_summary "${TMP}/ores-sops" use --environment=stage --force)
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
# The test core always writes one trailing newline. Command substitution strips
# it, so this checks the captured argv payload rather than file byte length.
[[ "$(cat "${CORE_ARGS_CAPTURE}")" == "" ]]

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
