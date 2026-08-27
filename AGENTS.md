# ores-sops

Canonical SOPS dotenv contract for ORESoftware and consuming orgs.

- Secrets at rest: this repository (`env/enc` ciphertext, `env/dec` runtime plaintext).
- Telemetry: github.com/ores-otel — a different layer; it *consumes* this contract.
- Auth: github.com/shared-auth.
- Sync: github.com/opto-sync.
- Packages: github.com/zed-pkg.
- Flags: github.com/ORESoftware/flags-2-env.
- Deploy: github.com/oresoftware/k8s-cluster (Kubernetes Secret YAML is out of this dotenv namespace).
- Internal runtimes: Rust, TypeScript, Dart. Never React/JSX or webviews.
- Resolve git conflicts semantically; never rebase, stash, or reset.
- Never print, commit, or fixture private keys, decrypted dotenv, or ciphertext values.

See [`docs/scope.md`](docs/scope.md), [`docs/consumer-boundary.md`](docs/consumer-boundary.md), and [`docs/fleet-audit.md`](docs/fleet-audit.md).
