# Scope: ores-sops vs ores-otel vs adjacent systems

`ores-sops` is live fleet infrastructure. It was not outmoded by
[ores-otel](https://github.com/ores-otel).

## What this repository owns

- The exact required `dev` / `prod` SOPS dotenv paths and one optional exact
  `stage` path:

  ```text
  env/enc/dev.env.enc
  env/enc/stage.env.enc
  env/enc/prod.env.enc
  ```

- Per-file public-recipient policy and desired-versus-actual recipient auditing.
- Local plaintext layout under `env/dec/{dev,stage,prod}.env` and the managed
  relative root `.env` symlink.
- Ignore policy, Git hooks, Nix packaging, keyless fleet audit, and guarded key
  synchronization.
- Consumer boundaries for Just, Nix, Docker, and direct SOPS wrappers.
- Backward compatibility for valid two-environment dev/prod repositories.

It does not emit logs, traces, or metrics. It does not replace OpenTelemetry
SDKs, collectors, or the ores-otel API/web servers. It also does not make GitHub
repository membership a decryption permission: SOPS age/KMS recipients remain
the cryptographic access boundary for each file.

## Adjacent systems

| System | Role relative to ores-sops |
| --- | --- |
| [ores-otel](https://github.com/ores-otel) | Observability. Consumes ores-sops for encrypted env files; does not encrypt them. |
| [shared-auth](https://github.com/shared-auth) | Authentication and organization identity. It does not replace per-ciphertext secret authorization. |
| [opto-sync](https://github.com/opto-sync) | Cross-device and boundary data synchronization. It must not synchronize private age identities. |
| [zed-pkg](https://github.com/zed-pkg) | Package/dependency management and pinned helper distribution. |
| [flags-2-env](https://github.com/ORESoftware/flags-2-env) | Flag/env wiring. Interoperates; does not store secrets. |
| [oresoftware/k8s-cluster](https://github.com/oresoftware/k8s-cluster) | Deployments. Kubernetes Secret YAML/KSOPS is a distinct GitOps class outside this dotenv namespace. |

## Why the layers remain separate

Application secrets such as Twilio credentials, SendGrid credentials, database
URLs, and signing material may sit in Git only as ciphertext under a fail-closed
path, recipient, ignore, and hook policy. Development, staging, and production
may have different human and workload recipient sets.

Application logs and traces leave the process through a separate telemetry
pipeline with their own schemas, transports, redaction rules, and retention.

ores-otel already documents that it follows the ORESoftware SOPS dotenv
contract. Keep both layers. Do not fold SOPS policy into the logging org, do not
teach ores-sops to ship telemetry, and do not put private age identities into a
sync, auth, observability, or package-management system.
