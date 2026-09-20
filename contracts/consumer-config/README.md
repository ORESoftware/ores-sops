# `.ores-sops.toml` contract

This project-level file selects one deployment environment and one orthogonal execution profile for `ores-sops`. It contains paths and policy metadata only; it must never contain decrypted values, age private keys, cloud credentials, or other secrets.

Allowed environments are exactly `dev`, `stage`, and `prod`. Allowed profiles are exactly `local`, `gha`, `gha-indie-worker`, and `test`, matching the portable-config authority. Key-by-key profile override policy remains in the portable config manifest and is not duplicated here.

Example:

```toml
schema_version = 1
protocol = "ores.sops.consumer-config/v1"
environment = "dev"
profile = "local"
portable_config_path = "config/portable-config.json"
ciphertext_path = "env/dev.enc.yaml"

[execution]
fail_closed = true
persist_plaintext = false
diagnostics = "key-name-only"
```

Consumers must reject absolute or repository-escaping config/ciphertext paths at runtime and must execute secrets without persisting plaintext between workflow steps.
