#!/usr/bin/env bash
set -euo pipefail

ORESC_BIN="${ORESC_BIN:-oresc}"

if ! command -v "$ORESC_BIN" >/dev/null 2>&1; then
  echo "oresc is required; install the canonical ORESoftware/ores-cli package before running this audit" >&2
  exit 70
fi

echo "[oresc] repository / source / config standards"
"$ORESC_BIN" --no-json audit repo --path . --profile standards

# ores-sops is a shell/Nix policy repository rather than a Cargo package root.
# Package metadata and encrypted-environment semantics stay under the existing
# ores-sops/Nix contract gates; this entrypoint adds fleet-standard repository
# and .cli-flags/source-policy linting without duplicating secret-aware logic.
