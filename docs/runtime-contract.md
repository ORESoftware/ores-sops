# Runtime admission, telemetry, and contract boundary

`ores-sops` keeps secret material, CLI admission, and observability as separate
trust boundaries.

## CLI admission

The repository-root `.cli-flags.toml` is the public argv contract. The canonical
`flags-2-env/flags-2-env` implementation must admit public arguments before the
internal Bash core is invoked. Its `[env] files = []` setting is
security-sensitive: argv parsing must never read the managed `.env` symlink or
any `env/dec/*.env` plaintext.

Startup first runs the real `flags2env audit` against `.cli-flags.toml`. The real
argv is then parsed by `flags2env`; the wrapper consumes only the configured
command, unknown-option, parse-error, and positional channels. Those channels
must all exist and be structurally valid. Unknown options, invalid typed values,
extra operands, command mismatches, and operands hidden behind a bare `--` fail
closed before the SOPS core is invoked.

Parser stdout flows only through a bounded JSON checker on stdin. It is never
`eval`'d, exported, logged, persisted, or passed on another process' argv.
Parser/audit stderr is suppressed because it can reflect attacker-controlled
argv or configuration details; `ores-sops` emits only a fixed diagnostic class
instead.

Commands that operate on one encrypted environment accept a positional
`dev|stage|prod`, `--environment <profile>`, or `ORES_SOPS_ENVIRONMENT`.
If all are absent, admission fails closed and emits a redacted diagnostic
containing the missing key name (`ORES_SOPS_ENVIRONMENT`) but no value.
Conflicting profile sources fail before decryption or encryption begins.

## ores-otel telemetry boundary

`ores-sops` emits one secret-safe domain record per lifecycle/failure event as
NDJSON on stderr using `ores.sops/diagnostic/v1`. The event set is closed in
both TypeSpec and independently authored JSON Schema; the Bash emitter maps each
event to a fixed severity and fixed message and does not accept arbitrary log
messages. Command/profile/key metadata is allow-listed and exit codes are
bounded.

This stderr boundary follows the `ores-otel` deployment model rather than
inventing a sidecar ingestion protocol. `ores-otel/ores-otel-sidecar.rs`
explicitly does not read stdin or use stdout as a protocol; its documented
platform collector routes structured stderr to CloudWatch, Google Cloud
Logging, Azure Monitor, or Loki. Likewise,
`ores-otel/ores.otel.log` reserves `ores.otel.log/internal-diagnostic/v1` for
failures *inside the observability path* and restricts that control plane to its
own closed component/operation enums. `ores-sops` application lifecycle events
therefore must not masquerade as that internal diagnostic schema.

The `ores.sops/diagnostic/v1` record never accepts dotenv values, recipient
strings, private age identities, ciphertext, arbitrary argv, parser output,
provider errors, or credentials as telemetry fields. Platform-side collection
may feed these records into the broader ores-otel pipeline without giving the
secret-management process logging credentials.

Set `ORES_SOPS_TELEMETRY=0` only when a caller explicitly needs silent stderr
telemetry; command admission and command failures remain fail-closed.

## Cross-runtime contract

`contracts/main.tsp` and `contracts/authored.schema.json` are independent,
human-maintained peer authorities. Diagnostic events are closed enums, not
free-form runtime strings. Positive and negative instance fixtures include
unknown-event rejection.

CI invokes `ORESoftware/typespec-json-schema-validator` (TJSV) directly as a
GitHub Action pinned to an exact repository commit. TJSV generates comparison
evidence from TypeSpec and fails closed unless it converges with the independently
authored JSON Schema Draft 2020-12 authority and the fixture corpus. Neither a
generated schema nor telemetry runtime output becomes a third authority.

CI separately installs `flags-2-env/flags-2-env` from an exact GitHub commit and
exercises the real parser against this repository's `.cli-flags.toml`, including
unknown flags, typed-value failures, positional/dashdash bypass attempts, help
and version aliases, and the disabled-dotenv boundary.
