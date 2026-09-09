# Runtime admission, telemetry, and contract boundary

`ores-sops` keeps secret material and observability as separate trust boundaries.

## CLI admission

The repository-root `.cli-flags.toml` is the public argv contract. `flags2env`
must admit public arguments before the internal Bash core is invoked. Its
`[env] files = []` setting is security-sensitive: argv parsing must never read
the managed `.env` symlink or any `env/dec/*.env` plaintext.

Commands that operate on one encrypted environment accept a positional
`dev|stage|prod`, `--environment <profile>`, or `ORES_SOPS_ENVIRONMENT`.
If all are absent, admission fails closed and emits a redacted diagnostic
containing the missing key name (`ORES_SOPS_ENVIRONMENT`) but no value.

## ores-otel telemetry

Diagnostics are NDJSON on stderr using `ores.sops/diagnostic/v1`. They are
designed for ingestion by the ores-otel logging/sidecar layer. The envelope
contains only allow-listed command/profile names, key names, exit codes, and
fixed messages. It never accepts dotenv values, recipient strings, private age
identities, ciphertext, or arbitrary argv as telemetry fields.

Set `ORES_SOPS_TELEMETRY=0` only when a caller explicitly needs silent stderr
telemetry; command errors remain fail-closed.

## Cross-runtime contract

`contracts/main.tsp` and `contracts/authored.schema.json` are independent
author-maintained authorities. CI runs
`@oresoftware/typespec-json-schema-validator` (`tjsv`) against both plus
positive/negative fixtures. Neither generated schema nor telemetry runtime
output becomes a third authority.
