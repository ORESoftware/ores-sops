# Portable configuration metadata — v0.5 design slice

Tracking: [ORESoftware/ores-sops#40](https://github.com/ORESoftware/ores-sops/issues/40)
Canonical architecture: [ORESoftware/ores-docs#3](https://github.com/ORESoftware/ores-docs/issues/3)

This document defines the typed metadata boundary needed before `ores-sops` admits execution-profile overlays or implements `render` / `exec` composition.

It does **not** change the current v0.4 ciphertext-path validator by itself. Until the runtime implementation lands, the only admitted deployment ciphertext paths remain the existing exact `dev`, optional exact `stage`, and `prod` paths.

## Two independent dimensions

Deployment environment remains exactly:

```text
dev | stage | prod
```

Execution profile is orthogonal and remains exactly:

```text
local | gha | gha-indie-worker | test
```

`qa`, `staging`, `ci`, `gha-dev`, `release`, and similar names are not aliases for either dimension.

## Typed key metadata

`contracts/portable-config/main.tsp` and `contracts/portable-config/authored.schema.json` are independently authored peer authorities. TJSV compares them and executes the instance corpus.

Each key policy describes:

- canonical environment key name;
- value type;
- secret vs non-secret classification;
- required vs optional status;
- allowed deployment environments;
- allowed execution profiles;
- whether a profile may override the environment value;
- diagnostic visibility;
- optional owner/provider metadata;
- optional deprecation/replacement metadata.

The contract describes **key metadata, never values**.

## Runtime composition rule

The target runtime operation is:

```text
one deployment environment
  + one execution profile
  + typed key policy
  = one effective runtime environment
```

A profile collision is admitted only when the key policy explicitly sets `profileOverride=true`. Unknown keys, unknown collisions, disallowed environment/profile pairs, and missing required keys fail closed.

## Secret diagnostics

Runtime tooling may report safe structural facts such as a missing key name. It must never report the corresponding secret value.

The contract exposes `diagnosticVisibility` so later runtime validation can distinguish key-name-only diagnostics from metadata that is safe to expose for non-secret configuration. Runtime admission must add the semantic rule that secret-classified keys are never value-visible regardless of metadata.

## Praxonne pilot

The positive fixture models the first pilot:

- `APP_ID` and `APP_KEY` are required secret keys in `dev` for `gha` and `gha-indie-worker`;
- neither key permits profile override;
- diagnostics are key-name-only;
- a non-secret CI formatting key demonstrates an explicitly overridable profile value.

This fixture contains no credentials or realistic secret values.

## Follow-up implementation

After this metadata contract is green and reviewed:

1. extend exact SOPS recipient policy to explicitly admitted profile ciphertexts without weakening current `dev|stage|prod` rules;
2. add `ores-sops render --env <env> --profile <profile>` with atomic mode-0600 output or stdout-safe execution semantics;
3. add `ores-sops exec --env <env> --profile <profile> -- <command>` so plaintext need not persist between workflow steps;
4. reject untrusted fork-originated decryption in the shared GitHub Actions adapter;
5. bind `gha-indie-worker` jobs to repository + exact SHA + environment + profile + config-contract digest;
6. add `ores-cli` fleet audit using key names/metadata only.
