# GitHub Actions fallback reconciliation

`env/enc/<environment>.env.enc` remains the version-controlled source of truth for application secrets. GitHub Actions secrets and variables are a bootstrap/fallback delivery plane; they are not an equal authority.

## Precedence

The resolver applies this fixed order, regardless of caller order:

1. `env/enc/<environment>.env.enc` (authoritative; always wins when the key exists)
2. GitHub environment secret
3. GitHub repository secret
4. GitHub organization secret
5. GitHub environment variable
6. GitHub repository variable
7. GitHub organization variable

Only values explicitly delivered to the workflow can become fallback values. The GitHub REST API can enumerate Actions secret **names and metadata**, but GitHub never returns secret values. API inventory therefore contributes observations, not secret values. GitHub Actions variables are readable through the API, but the inventory helper deliberately discards their values too so receipts and telemetry use one value-blind evidence model.

A GitHub key absent from `env/enc` produces a value-blind `next-loggers/v1` warning record for the `github.com/ores-otel` pipeline. The record includes the repository, environment, key name, GitHub source class, and reason `missing_from_env_enc`. It must never include the value, ciphertext, value length, prefix, hash, or any other value-derived metadata.

## Runtime flow

1. Decrypt the selected canonical SOPS file through the normal `ores-sops` lifecycle into a private temporary file or `env/dec/<environment>.env`.
2. Materialize only explicitly declared GitHub fallback values into private temporary dotenv files. Do not attempt to download secret values through the REST API; that API does not provide them.
3. Run `scripts/inventory-github-actions-config.mjs` to query GitHub Actions configuration names with `gh api` and write a private `0600` inventory containing only `{key, source}` entries.
4. Run `scripts/run-github-actions-reconciliation.mjs` (or the composite action in `actions/github-actions-reconcile`).
5. Consume the generated resolved dotenv file. Its mode is `0600`; `env/enc` values have overwritten same-name GitHub fallbacks.
6. Send the generated JSONL records into the existing `github.com/ores-otel` log/OTLP path. The records use the canonical `next-loggers/v1` envelope.

The runners accept no command-line options. Their bootstrap inputs are environment variables pointing at manifests/output files. This avoids a parallel argv parser and keeps secret values out of command arguments.

### Read-only GitHub API inventory

Repository secrets and variables are always inventoried. Set `ORES_SOPS_GHA_ENVIRONMENT=dev|stage|prod` to additionally inventory that GitHub environment. Organization-level inventory is opt-in because it requires organization permissions; set `ORES_SOPS_GHA_INCLUDE_ORGANIZATION=1` only for an organization-owned repository when the authenticated identity is authorized.

```text
ORES_SOPS_GHA_REPOSITORY=owner/repo
ORES_SOPS_GHA_ENVIRONMENT=prod
ORES_SOPS_GHA_INVENTORY_FILE=/runner/private/github-inventory.json
node scripts/inventory-github-actions-config.mjs
```

The helper calls the GitHub Actions secrets/variables REST endpoints through `gh api --paginate --slurp`. Secret values are unavailable by API design. Variable endpoint responses do contain values, but the helper immediately reduces every item to its name and source class. It suppresses `gh` stderr on API failure so provider responses are not copied into CI logs.

Example manifest (paths only):

```json
{
  "repository": "ORESoftware/example",
  "environment": "prod",
  "authoritativePath": "env/enc/prod.env.enc",
  "authoritativeFile": "/runner/private/authoritative.env",
  "fallbacks": [
    {"source": "github_repository_secret", "path": "/runner/private/repo-secrets.env"},
    {"source": "github_repository_variable", "path": "/runner/private/repo-vars.env"}
  ],
  "inventoryFile": "/runner/private/github-inventory.json",
  "resolvedFile": "/runner/private/resolved.env",
  "receiptFile": "/runner/private/reconciliation.json",
  "telemetryFile": "/runner/private/ores-otel.jsonl"
}
```

Inventory entries contain key names only:

```json
[
  {"key": "SHARED_AUTH_READ_TOKEN", "source": "github_repository_secret"},
  {"key": "REGION", "source": "github_repository_variable"}
]
```

## Publishing fallback secrets through GitHub

`scripts/push-github-actions-fallbacks.mjs` writes a reviewed dotenv source to GitHub Actions through `gh secret set`, which uses GitHub's Actions-secrets API and encryption flow. It is intentionally dry-run by default.

Required environment:

```text
ORES_SOPS_GHA_REPOSITORY=owner/repo
ORES_SOPS_GHA_PUSH_FILE=/private/path/resolved-or-reviewed.env
```

Set `ORES_SOPS_GHA_APPLY=1` only after reviewing the target and key names. Repository scope is the default. For an environment secret, additionally set:

```text
ORES_SOPS_GHA_SCOPE=environment
ORES_SOPS_GHA_ENVIRONMENT=prod
```

Secret values are supplied to `gh` only on stdin. They are never placed in argv or printed. The helper does not rotate, revoke, or delete secrets.

## Cross-runtime contract

The public, value-blind reconciliation receipt is governed by two independently authored authorities:

- `contracts/github-actions-reconciliation/main.tsp`
- `contracts/github-actions-reconciliation/authored.schema.json` (Draft 2020-12)

CI pins `github.com/ORESoftware/typespec-json-schema-validator` to an immutable commit and runs `tjsv check` over both authorities and the recorded instance corpus. An intentional drift mutation must return TJSV exit code `2`; accepting the mutation is a CI failure.

This contract is intentionally limited to names, source classes, resolution decisions, and observations. Secret values are not a contract field in any language/runtime.
