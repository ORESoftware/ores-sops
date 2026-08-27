# Scope: ores-sops vs ores-otel vs adjacent systems

`ores-sops` is live fleet infrastructure. It was not outmoded by
[ores-otel](https://github.com/ores-otel).

## What this repository owns

- The exact `dev` / `prod` SOPS dotenv path contract
  (`env/enc/dev.env.enc`, `env/enc/prod.env.enc`).
- Local plaintext layout (`env/dec/*`, managed `.env` symlink).
- Ignore policy, Git hooks, Nix packaging, and keyless fleet audit.
- Consumer boundaries for Just/Nix/Docker wrappers.

It does **not** emit logs, traces, or metrics. It does not replace OpenTelemetry
SDKs, collectors, or the ores-otel API/web servers.

## Adjacent systems

| System | Role relative to ores-sops |
| --- | --- |
| [ores-otel](https://github.com/ores-otel) | Observability. Consumes ores-sops for encrypted env files; does not encrypt them. |
| [shared-auth](https://github.com/shared-auth) | Authentication. Dual auth with Supabase. |
| [opto-sync](https://github.com/opto-sync) | Cross-device/boundary data sync. |
| [zed-pkg](https://github.com/zed-pkg) | Package/dependency management. |
| [flags-2-env](https://github.com/ORESoftware/flags-2-env) | Flag/env wiring. Interoperates; does not store secrets. |
| [oresoftware/k8s-cluster](https://github.com/oresoftware/k8s-cluster) | Deployments. Kubernetes Secret YAML / KSOPS is a distinct GitOps class and is excluded from this dotenv namespace. |

## Why both exist

Application secrets (Twilio, SendGrid, database URLs, age recipients) must sit
in Git as ciphertext with a fail-closed ignore/hook policy. Application logs
and traces must leave the process over a separate pipeline with their own
schemas and transports.

ores-otel already documents that it follows this contract:

> Secrets for `ores-otel/ores.otel.log` are committed, encrypted, with sops +
> age, following the fleet-wide convention … (the `ORESoftware/ores-sops`
> contract).

Keep both. Do not fold SOPS dotenv policy into the logging org, and do not
teach ores-sops to ship telemetry.
